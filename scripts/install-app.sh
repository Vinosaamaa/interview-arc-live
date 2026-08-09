#!/bin/zsh

set -euo pipefail

bundle_identifier="app.interviewarc.live"
destination="/Applications/Interview Arc Live.app"
allow_adhoc_install="${INTERVIEW_ARC_LIVE_ALLOW_ADHOC_INSTALL:-0}"

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 '/path/to/Interview Arc Live.app'" >&2
  exit 64
fi

source_app="${1:A}"
source_info="$source_app/Contents/Info.plist"

if [[ ! -d "$source_app" || ! -f "$source_info" ]]; then
  echo "Expected a packaged Interview Arc Live application bundle." >&2
  exit 66
fi

actual_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_info")"
executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$source_info")"
source_executable="$source_app/Contents/MacOS/$executable_name"

if [[ "$actual_identifier" != "$bundle_identifier" || ! -x "$source_executable" ]]; then
  echo "Refusing an application that is not Interview Arc Live." >&2
  exit 65
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$source_app"
signature_details="$(/usr/bin/codesign -dvvv "$source_app" 2>&1)"
if [[ "$signature_details" == *"Signature=adhoc"* && "$allow_adhoc_install" != "1" ]]; then
  echo "Refusing an ad-hoc signature for installation." >&2
  echo "Repackage with INTERVIEW_ARC_LIVE_SIGNING_IDENTITY set to a stable code-signing identity." >&2
  echo "For an explicit development smoke only, set INTERVIEW_ARC_LIVE_ALLOW_ADHOC_INSTALL=1." >&2
  exit 65
fi
if [[ "$signature_details" == *"Signature=adhoc"* ]]; then
  echo "WARNING: installing an ad-hoc development build." >&2
  echo "macOS may treat a future rebuild as a new identity and ask for microphone permission again." >&2
fi

source_cdhash="$(print -r -- "$signature_details" | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
if [[ -z "$source_cdhash" ]]; then
  echo "The packaged application has no verifiable code-directory hash." >&2
  exit 65
fi

staging="/Applications/.Interview Arc Live.install-$$.app"
backup="/Applications/.Interview Arc Live.backup-$$.app"

cleanup() {
  if [[ -d "$staging" ]]; then
    rm -rf "$staging"
  fi
}
trap cleanup EXIT

# Refuse to displace an unrelated bundle even if it occupies the expected
# application path.
if [[ -e "$destination" ]]; then
  installed_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$installed_identifier" != "$bundle_identifier" ]]; then
    echo "Refusing to replace an unexpected application at $destination." >&2
    exit 65
  fi
fi

# Stop only this executable if it is already running. Refuse a forced quit so
# an in-flight local session cannot be discarded by packaging automation.
if /usr/bin/pgrep -x "$executable_name" >/dev/null; then
  /usr/bin/osascript -e 'tell application id "app.interviewarc.live" to quit' >/dev/null 2>&1 || true
  for _ in {1..50}; do
    if ! /usr/bin/pgrep -x "$executable_name" >/dev/null; then
      break
    fi
    sleep 0.1
  done
  if /usr/bin/pgrep -x "$executable_name" >/dev/null; then
    echo "Interview Arc Live is still running; installation did not start." >&2
    exit 75
  fi
fi

/usr/bin/ditto "$source_app" "$staging"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$staging"

if [[ -e "$destination" ]]; then
  mv "$destination" "$backup"
fi

if ! mv "$staging" "$destination"; then
  if [[ -d "$backup" ]]; then
    mv "$backup" "$destination"
  fi
  echo "Installation failed; the previous application was restored." >&2
  exit 1
fi

installed_details=""
if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$destination"; then
  installed_cdhash=""
else
  installed_details="$(/usr/bin/codesign -dvvv "$destination" 2>&1)"
  installed_cdhash="$(print -r -- "$installed_details" | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
fi

if [[ -z "$installed_cdhash" || "$installed_cdhash" != "$source_cdhash" ]]; then
  rm -rf "$destination"
  if [[ -d "$backup" ]]; then
    mv "$backup" "$destination"
  fi
  echo "Installed bytes did not match the packaged application; the previous application was restored." >&2
  exit 1
fi

if [[ -d "$backup" ]]; then
  rm -rf "$backup"
fi

/usr/bin/open "$destination"
echo "Installed and launched exact package: $destination"
echo "Code-directory hash: $installed_cdhash"
