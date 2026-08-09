#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h:h}"
installer="$repo_root/scripts/install-app.sh"
test_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/interview-arc-live-installer.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

assert_equal() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "$actual" == "$expected" ]] || fail "$label: expected '$expected', got '$actual'"
}

make_signed_bundle() {
  local bundle="$1"
  local identifier="$2"
  local marker="$3"
  local executable="InterviewArcLive"

  mkdir -p "$bundle/Contents/MacOS"
  /usr/bin/plutil -create xml1 "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $identifier" "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $executable" "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$bundle/Contents/Info.plist"
  print -r -- "#!/bin/zsh\nprint -r -- '$marker'" > "$bundle/Contents/MacOS/$executable"
  chmod 0755 "$bundle/Contents/MacOS/$executable"
  /usr/bin/codesign --force --sign - --timestamp=none "$bundle" >/dev/null
}

cd "$repo_root"
export INTERVIEW_ARC_LIVE_INSTALLER_SOURCE_ONLY=1
source "$installer"
unset INTERVIEW_ARC_LIVE_INSTALLER_SOURCE_ONLY

system_directory="$test_root/system-applications"
user_directory="$test_root/current-user-home/Applications"
mkdir -p "$system_directory" "$user_directory"

selected="$(select_install_destination "$system_directory" "$user_directory")"
assert_equal "$system_directory/Interview Arc Live.app" "$selected" \
  "writable system Applications selection"

selected="$(select_install_destination "$test_root/missing-system-applications" "$user_directory")"
assert_equal "$user_directory/Interview Arc Live.app" "$selected" \
  "current-user Applications fallback"

explicit="$test_root/explicit/Interview Arc Live.app"
mkdir -p "${explicit:h}"
selected="$(select_install_destination "$system_directory" "$user_directory" "$explicit")"
assert_equal "${explicit:A}" "$selected" "explicit test destination"

if select_install_destination \
  "$system_directory" \
  "$user_directory" \
  "$test_root/explicit/Another App.app" >/dev/null 2>&1; then
  fail "unexpected explicit bundle name was accepted"
fi

rollback_directory="$test_root/rollback"
rollback_destination="$rollback_directory/Interview Arc Live.app"
rollback_backup="$rollback_directory/.Interview Arc Live.backup-test.app"
mkdir -p "$rollback_destination" "$rollback_backup"
print -r -- "new" > "$rollback_destination/new-marker"
print -r -- "previous" > "$rollback_backup/previous-marker"
restore_previous_install "$rollback_destination" "$rollback_backup"
[[ -f "$rollback_destination/previous-marker" ]] || fail "rollback did not restore the previous app"
[[ ! -e "$rollback_destination/new-marker" ]] || fail "rollback retained failed installed bytes"
[[ ! -e "$rollback_backup" ]] || fail "rollback left the backup behind"

source_bundle="$test_root/source/Interview Arc Live.app"
install_directory="$test_root/install"
installed_bundle="$install_directory/Interview Arc Live.app"
mkdir -p "$install_directory"
make_signed_bundle "$source_bundle" "app.interviewarc.live" "first-build"

INTERVIEW_ARC_LIVE_ALLOW_ADHOC_INSTALL=1 \
INTERVIEW_ARC_LIVE_SKIP_LAUNCH=1 \
  "$installer" "$source_bundle" "$installed_bundle" >/dev/null

source_cdhash="$(/usr/bin/codesign -dvvv "$source_bundle" 2>&1 | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
installed_cdhash="$(/usr/bin/codesign -dvvv "$installed_bundle" 2>&1 | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
assert_equal "$source_cdhash" "$installed_cdhash" "installed code-directory hash"
[[ -x "$installed_bundle/Contents/MacOS/InterviewArcLive" ]] || fail "installed executable is missing"

replacement_bundle="$test_root/replacement/Interview Arc Live.app"
make_signed_bundle "$replacement_bundle" "app.interviewarc.live" "replacement-build"
INTERVIEW_ARC_LIVE_ALLOW_ADHOC_INSTALL=1 \
INTERVIEW_ARC_LIVE_SKIP_LAUNCH=1 \
  "$installer" "$replacement_bundle" "$installed_bundle" >/dev/null
replacement_cdhash="$(/usr/bin/codesign -dvvv "$replacement_bundle" 2>&1 | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
installed_cdhash="$(/usr/bin/codesign -dvvv "$installed_bundle" 2>&1 | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
assert_equal "$replacement_cdhash" "$installed_cdhash" "replacement code-directory hash"
if find "$install_directory" -maxdepth 1 -name '.Interview Arc Live.backup-*.app' | grep -q .; then
  fail "successful replacement left a rollback bundle behind"
fi

unrelated_directory="$test_root/unrelated"
unrelated_destination="$unrelated_directory/Interview Arc Live.app"
mkdir -p "$unrelated_destination/Contents"
/usr/bin/plutil -create xml1 "$unrelated_destination/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string example.unrelated' \
  "$unrelated_destination/Contents/Info.plist"
if INTERVIEW_ARC_LIVE_ALLOW_ADHOC_INSTALL=1 \
  INTERVIEW_ARC_LIVE_SKIP_LAUNCH=1 \
  "$installer" "$source_bundle" "$unrelated_destination" >/dev/null 2>&1; then
  fail "installer replaced an unrelated bundle"
fi
actual_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' \
  "$unrelated_destination/Contents/Info.plist")"
assert_equal "example.unrelated" "$actual_identifier" "unrelated bundle preservation"

echo "Installer destination, exact-bundle, CDHash, replacement, and rollback tests passed."
