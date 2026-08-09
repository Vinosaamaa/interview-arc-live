#!/bin/zsh

set -euo pipefail

bundle_identifier="app.interviewarc.live"
app_name="Interview Arc Live.app"
helper_name="InterviewArcLiveCodexSmoke"
opt_in="${INTERVIEW_ARC_LIVE_RUN_CODEX_SMOKE:-0}"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 ['/installed/path/Interview Arc Live.app'] '/path/to/InterviewArcLive.package-manifest.txt'" >&2
  exit 64
fi
if [[ "$opt_in" != "1" ]]; then
  echo "Installed Codex smoke is opt-in." >&2
  echo "Set INTERVIEW_ARC_LIVE_RUN_CODEX_SMOKE=1 to run one authenticated interviewer request." >&2
  exit 64
fi

if [[ $# -eq 2 ]]; then
  installed_app="${1:A}"
  package_manifest="${2:A}"
elif [[ -d "/Applications/$app_name" ]]; then
  installed_app="/Applications/$app_name"
  package_manifest="${1:A}"
elif [[ -d "${HOME:?Current user home directory is unavailable.}/Applications/$app_name" ]]; then
  installed_app="${HOME}/Applications/$app_name"
  package_manifest="${1:A}"
else
  echo "Interview Arc Live is not installed in a standard Applications directory." >&2
  exit 66
fi

info_plist="$installed_app/Contents/Info.plist"
helper="$installed_app/Contents/Helpers/$helper_name"
if [[ ! -d "$installed_app" || ! -f "$info_plist" || ! -x "$helper" ]]; then
  echo "The installed Interview Arc Live bundle does not include the Codex smoke helper." >&2
  exit 66
fi

actual_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
if [[ "$actual_identifier" != "$bundle_identifier" ]]; then
  echo "Refusing to smoke an application that is not Interview Arc Live." >&2
  exit 65
fi
/usr/bin/codesign --verify --deep --strict --verbose=2 "$installed_app"
"${0:A:h}/verify-package-manifest.sh" "$installed_app" "$package_manifest"

smoke_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/interview-arc-live-codex-smoke.XXXXXX")"
cleanup() {
  rm -rf "$smoke_root"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

repo_root="${0:A:h:h}"
if [[ "${smoke_root:A}" == "${repo_root:A}"/* ]]; then
  echo "Refusing to run the installed smoke inside the source repository." >&2
  exit 65
fi

cd "$smoke_root"
INTERVIEW_ARC_LIVE_RUN_CODEX_SMOKE=1 "$helper"
