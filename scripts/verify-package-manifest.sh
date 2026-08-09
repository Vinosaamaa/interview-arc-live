#!/bin/zsh

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 '/path/to/Interview Arc Live.app' '/path/to/package-manifest.txt'" >&2
  exit 64
fi

app_dir="${1:A}"
manifest_path="${2:A}"
executable="$app_dir/Contents/MacOS/InterviewArcLive"
smoke_executable="$app_dir/Contents/Helpers/InterviewArcLiveCodexSmoke"
info_plist="$app_dir/Contents/Info.plist"

if [[ ! -x "$executable" || ! -x "$smoke_executable" \
    || ! -f "$info_plist" || ! -f "$manifest_path" ]]; then
  echo "Package manifest verification requires a complete application bundle and manifest." >&2
  exit 66
fi

manifest_value() {
  local key="$1"
  /usr/bin/awk -F= -v requested="$key" '
    $1 == requested {
      count += 1
      value = substr($0, length($1) + 2)
    }
    END {
      if (count != 1 || value == "") exit 65
      print value
    }
  ' "$manifest_path"
}

actual_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
actual_cdhash="$(/usr/bin/codesign -dvvv "$app_dir" 2>&1 | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
actual_executable_sha="$(/usr/bin/shasum -a 256 "$executable" | /usr/bin/awk '{print $1}')"
actual_smoke_sha="$(/usr/bin/shasum -a 256 "$smoke_executable" | /usr/bin/awk '{print $1}')"
actual_info_sha="$(/usr/bin/shasum -a 256 "$info_plist" | /usr/bin/awk '{print $1}')"
actual_bundle_count="$(/usr/bin/find "$app_dir/Contents/Resources" -mindepth 1 -maxdepth 1 -type d -name '*.bundle' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"

[[ "$(manifest_value bundle_identifier)" == "$actual_identifier" ]] \
  || { echo "Package manifest bundle identifier mismatch." >&2; exit 65; }
[[ "$(manifest_value code_directory_hash)" == "$actual_cdhash" ]] \
  || { echo "Package manifest code-directory hash mismatch." >&2; exit 65; }
[[ "$(manifest_value executable_sha256)" == "$actual_executable_sha" ]] \
  || { echo "Package manifest application executable mismatch." >&2; exit 65; }
[[ "$(manifest_value codex_smoke_executable_sha256)" == "$actual_smoke_sha" ]] \
  || { echo "Package manifest Codex smoke helper mismatch." >&2; exit 65; }
[[ "$(manifest_value info_plist_sha256)" == "$actual_info_sha" ]] \
  || { echo "Package manifest Info.plist mismatch." >&2; exit 65; }
[[ "$(manifest_value resource_bundle_count)" == "$actual_bundle_count" ]] \
  || { echo "Package manifest resource-bundle count mismatch." >&2; exit 65; }

echo "Package manifest application and Codex smoke hashes verified."
