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
endpoint_smoke_executable="$app_dir/Contents/Helpers/InterviewArcLiveEndpointSmoke"
speech_smoke_executable="$app_dir/Contents/Helpers/InterviewArcLiveSpeechSmoke"
info_plist="$app_dir/Contents/Info.plist"
app_icon="$app_dir/Contents/Resources/InterviewArcLive.icns"
mlx_resource_bundle="$app_dir/Contents/Resources/mlx-swift_Cmlx.bundle"
mlx_metallib_candidates=("$mlx_resource_bundle"/**/default.metallib(N))

if [[ ! -x "$executable" || ! -x "$smoke_executable" \
    || ! -x "$endpoint_smoke_executable" \
    || ! -x "$speech_smoke_executable" \
    || ! -f "$info_plist" || ! -f "$app_icon" || -L "$app_icon" \
    || ! -f "$manifest_path" \
    || ! -d "$mlx_resource_bundle" || -L "$mlx_resource_bundle" \
    || ${#mlx_metallib_candidates} -ne 1 \
    || ! -f "${mlx_metallib_candidates[1]}" \
    || -L "${mlx_metallib_candidates[1]}" ]]; then
  echo "Package manifest verification requires a complete application bundle and manifest." >&2
  exit 66
fi

if ! /usr/bin/codesign --verify --deep --strict "$app_dir" >/dev/null 2>&1; then
  echo "Package manifest application signature verification failed." >&2
  exit 65
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
actual_icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$info_plist")"
actual_cdhash="$(/usr/bin/codesign -dvvv "$app_dir" 2>&1 | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
actual_executable_sha="$(/usr/bin/shasum -a 256 "$executable" | /usr/bin/awk '{print $1}')"
actual_smoke_sha="$(/usr/bin/shasum -a 256 "$smoke_executable" | /usr/bin/awk '{print $1}')"
actual_endpoint_smoke_sha="$(/usr/bin/shasum -a 256 "$endpoint_smoke_executable" | /usr/bin/awk '{print $1}')"
actual_speech_smoke_sha="$(/usr/bin/shasum -a 256 "$speech_smoke_executable" | /usr/bin/awk '{print $1}')"
actual_info_sha="$(/usr/bin/shasum -a 256 "$info_plist" | /usr/bin/awk '{print $1}')"
actual_bundle_count="$(/usr/bin/find "$app_dir/Contents/Resources" -mindepth 1 -maxdepth 1 -type d -name '*.bundle' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
actual_mlx_metallib="${mlx_metallib_candidates[1]}"
actual_mlx_metallib_relative_path="${actual_mlx_metallib#$app_dir/}"
actual_mlx_metallib_sha="$(/usr/bin/shasum -a 256 "$actual_mlx_metallib" | /usr/bin/awk '{print $1}')"
actual_mlx_metallib_byte_count="$(/usr/bin/stat -f '%z' "$actual_mlx_metallib")"

[[ "$(manifest_value bundle_identifier)" == "$actual_identifier" ]] \
  || { echo "Package manifest bundle identifier mismatch." >&2; exit 65; }
[[ "$actual_icon_name" == "InterviewArcLive.icns" ]] \
  || { echo "Packaged application icon metadata mismatch." >&2; exit 65; }
[[ "$(manifest_value code_directory_hash)" == "$actual_cdhash" ]] \
  || { echo "Package manifest code-directory hash mismatch." >&2; exit 65; }
[[ "$(manifest_value executable_sha256)" == "$actual_executable_sha" ]] \
  || { echo "Package manifest application executable mismatch." >&2; exit 65; }
[[ "$(manifest_value codex_smoke_executable_sha256)" == "$actual_smoke_sha" ]] \
  || { echo "Package manifest Codex smoke helper mismatch." >&2; exit 65; }
[[ "$(manifest_value endpoint_smoke_executable_sha256)" == "$actual_endpoint_smoke_sha" ]] \
  || { echo "Package manifest endpoint smoke helper mismatch." >&2; exit 65; }
[[ "$(manifest_value speech_smoke_executable_sha256)" == "$actual_speech_smoke_sha" ]] \
  || { echo "Package manifest local-speech smoke helper mismatch." >&2; exit 65; }
[[ "$(manifest_value info_plist_sha256)" == "$actual_info_sha" ]] \
  || { echo "Package manifest Info.plist mismatch." >&2; exit 65; }
[[ "$(manifest_value resource_bundle_count)" == "$actual_bundle_count" ]] \
  || { echo "Package manifest resource-bundle count mismatch." >&2; exit 65; }
[[ "$(manifest_value mlx_metallib_relative_path)" == "$actual_mlx_metallib_relative_path" ]] \
  || { echo "Package manifest MLX Metal resource path mismatch." >&2; exit 65; }
[[ "$(manifest_value mlx_metallib_sha256)" == "$actual_mlx_metallib_sha" ]] \
  || { echo "Package manifest MLX Metal resource hash mismatch." >&2; exit 65; }
[[ "$(manifest_value mlx_metallib_byte_count)" == "$actual_mlx_metallib_byte_count" ]] \
  || { echo "Package manifest MLX Metal resource size mismatch." >&2; exit 65; }

echo "Package manifest application, helpers, and MLX Metal resource verified."
