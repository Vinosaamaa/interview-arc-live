#!/bin/zsh

set -euo pipefail

bundle_identifier="app.interviewarc.live"
app_name="Interview Arc Live.app"
system_applications_directory="/Applications"
allow_adhoc_install="${INTERVIEW_ARC_LIVE_ALLOW_ADHOC_INSTALL:-0}"

select_install_destination() {
  local system_directory="$1"
  local user_directory="$2"
  local explicit_destination="${3:-}"

  if [[ -n "$explicit_destination" ]]; then
    local resolved_destination="${explicit_destination:A}"
    if [[ "${resolved_destination:t}" != "$app_name" ]]; then
      echo "An explicit destination must end with '$app_name'." >&2
      return 65
    fi
    print -r -- "$resolved_destination"
    return
  fi

  if [[ -d "$system_directory" && -w "$system_directory" ]]; then
    print -r -- "$system_directory/$app_name"
  else
    print -r -- "$user_directory/$app_name"
  fi
}

restore_previous_install() {
  local failed_destination="$1"
  local previous_backup="$2"

  if [[ "${failed_destination:t}" != "$app_name" ]]; then
    echo "Refusing rollback for an unexpected destination." >&2
    return 65
  fi
  if [[ "${previous_backup:h}" != "${failed_destination:h}"
      || "${previous_backup:t}" != .Interview\ Arc\ Live.backup-*.app ]]; then
    echo "Refusing rollback from an unexpected backup." >&2
    return 65
  fi
  if [[ ! -d "$previous_backup" ]]; then
    echo "The previous application backup is unavailable." >&2
    return 66
  fi
  if [[ -e "$failed_destination" ]]; then
    rm -rf "$failed_destination"
  fi
  mv "$previous_backup" "$failed_destination"
}

remove_unverified_install() {
  local failed_destination="$1"
  if [[ "${failed_destination:t}" != "$app_name" ]]; then
    echo "Refusing cleanup for an unexpected destination." >&2
    return 65
  fi
  if [[ -e "$failed_destination" ]]; then
    rm -rf "$failed_destination"
  fi
}

# Focused shell tests source these two path/rollback functions without running
# installation side effects. This switch cannot weaken a real installation.
if [[ "${INTERVIEW_ARC_LIVE_INSTALLER_SOURCE_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 '/path/to/Interview Arc Live.app' ['/install/path/Interview Arc Live.app']" >&2
  exit 64
fi

source_app="${1:A}"
source_info="$source_app/Contents/Info.plist"
current_user_applications_directory="${HOME:?Current user home directory is unavailable.}/Applications"
destination="$(select_install_destination \
  "$system_applications_directory" \
  "$current_user_applications_directory" \
  "${2:-}")"
destination_directory="${destination:h}"

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

# Validate the package before creating a missing per-user Applications
# directory. An invalid source must not mutate the destination filesystem.
if [[ ! -e "$destination_directory" ]]; then
  if [[ "$destination_directory" != "$current_user_applications_directory" ]]; then
    echo "The explicit installation directory does not exist: $destination_directory" >&2
    exit 73
  fi
  mkdir -p "$destination_directory"
fi
if [[ ! -d "$destination_directory" || ! -w "$destination_directory" ]]; then
  echo "The installation directory is not writable: $destination_directory" >&2
  exit 73
fi

staging="$destination_directory/.Interview Arc Live.install-$$.app"
backup="$destination_directory/.Interview Arc Live.backup-$$.app"
install_transaction_active=0
had_previous_install=0
installation_verified=0

cleanup() {
  local prior_status="${1:-$?}"
  trap - EXIT HUP INT TERM

  # Restore user data before best-effort staging cleanup. Errexit must never
  # skip rollback merely because removal of a temporary copy failed.
  if (( install_transaction_active && ! installation_verified )); then
    if (( had_previous_install )); then
      if [[ -d "$backup" ]]; then
        if ! restore_previous_install "$destination" "$backup"; then
          echo "Installation interrupted and automatic rollback failed; backup remains at $backup." >&2
        fi
      elif [[ ! -e "$destination" ]]; then
        echo "Installation interrupted after the previous application moved, but its backup is unavailable." >&2
      fi
    elif ! remove_unverified_install "$destination"; then
      echo "Installation interrupted and unverified bytes could not be removed." >&2
    fi
  fi

  if [[ -d "$staging" ]] && ! rm -rf "$staging"; then
    echo "Installation rollback completed, but staging cleanup failed at $staging." >&2
  fi

  return "$prior_status"
}
trap 'cleanup $?' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

# Refuse to displace an unrelated bundle even if it occupies the expected
# application path.
if [[ -e "$destination" ]]; then
  installed_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$installed_identifier" != "$bundle_identifier" ]]; then
    echo "Refusing to replace an unexpected application at $destination." >&2
    exit 65
  fi
fi

if [[ $# -ne 2
    && ( -n "${INTERVIEW_ARC_LIVE_TEST_AFTER_BACKUP_ACTION:-}"
      || "${INTERVIEW_ARC_LIVE_TEST_FAIL_AFTER_INSTALL_MOVE:-0}" != "0" ) ]]; then
  echo "Installer failure injection requires an explicit test destination." >&2
  exit 64
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

install_transaction_active=1
if [[ -e "$destination" ]]; then
  had_previous_install=1
  mv "$destination" "$backup"
fi

case "${INTERVIEW_ARC_LIVE_TEST_AFTER_BACKUP_ACTION:-}" in
  "") ;;
  fail) false ;;
  terminate) kill -TERM $$ ;;
  *)
    echo "Unknown installer test action." >&2
    exit 64
    ;;
esac

if ! mv "$staging" "$destination"; then
  if (( had_previous_install )); then
    restore_previous_install "$destination" "$backup"
  else
    remove_unverified_install "$destination"
  fi
  install_transaction_active=0
  echo "Installation failed; the previous application was restored." >&2
  exit 1
fi

if [[ "${INTERVIEW_ARC_LIVE_TEST_FAIL_AFTER_INSTALL_MOVE:-0}" == "1" ]]; then
  false
fi

installed_details=""
if ! /usr/bin/codesign --verify --deep --strict --verbose=2 "$destination"; then
  installed_cdhash=""
else
  installed_details="$(/usr/bin/codesign -dvvv "$destination" 2>&1)"
  installed_cdhash="$(print -r -- "$installed_details" | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
fi

if [[ -z "$installed_cdhash" || "$installed_cdhash" != "$source_cdhash" ]]; then
  if (( had_previous_install )); then
    restore_previous_install "$destination" "$backup"
  else
    remove_unverified_install "$destination"
  fi
  install_transaction_active=0
  echo "Installed bytes did not match the packaged application; the previous application was restored." >&2
  exit 1
fi

installation_verified=1
if [[ -d "$backup" ]]; then
  rm -rf "$backup"
fi
install_transaction_active=0

if [[ "${INTERVIEW_ARC_LIVE_SKIP_LAUNCH:-0}" != "1" ]]; then
  /usr/bin/open "$destination"
  echo "Installed and launched exact package: $destination"
else
  echo "Installed exact package: $destination"
fi
echo "Code-directory hash: $installed_cdhash"
