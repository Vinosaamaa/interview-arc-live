#!/bin/zsh

set -euo pipefail
setopt NULL_GLOB

repo_root="${0:A:h:h}"
configuration="${1:-release}"
case "$configuration" in
  debug)
    xcode_configuration="Debug"
    package_testability="YES"
    ;;
  release)
    xcode_configuration="Release"
    package_testability="NO"
    ;;
  *)
    echo "Usage: $0 [debug|release]" >&2
    exit 64
    ;;
esac
app_name="Interview Arc Live.app"
app_dir="$repo_root/dist/$app_name"
contents_dir="$app_dir/Contents"
executable_name="InterviewArcLive"
smoke_executable_name="InterviewArcLiveCodexSmoke"
endpoint_smoke_executable_name="InterviewArcLiveEndpointSmoke"
speech_smoke_executable_name="InterviewArcLiveSpeechSmoke"
info_plist="$repo_root/Resources/Info.plist"
app_icon="$repo_root/Resources/InterviewArcLive.icns"
signing_identity="${INTERVIEW_ARC_LIVE_SIGNING_IDENTITY:--}"
manifest_path="$repo_root/dist/InterviewArcLive.package-manifest.txt"
allow_dirty="${INTERVIEW_ARC_LIVE_ALLOW_DIRTY:-0}"
derived_data="${INTERVIEW_ARC_LIVE_DERIVED_DATA_PATH:-$repo_root/.build/xcode-derived-data}"
build_receipt="$derived_data/InterviewArcLive.source-commit"
package_scheme="InterviewArcLive-Package"
deployment_target="14.0"
code_signing_allowed="NO"

if [[ ! -f "$info_plist" ]]; then
  echo "Missing application metadata: Resources/Info.plist" >&2
  exit 66
fi
if [[ ! -f "$app_icon" || -L "$app_icon" ]]; then
  echo "Missing application icon: Resources/InterviewArcLive.icns" >&2
  exit 66
fi
if [[ ! -f "$repo_root/Package.resolved" ]]; then
  echo "Packaging requires the committed exact dependency graph in Package.resolved." >&2
  exit 66
fi

cd "$repo_root"
source_commit="$(git rev-parse HEAD)"
source_tree_clean="true"
if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  source_tree_clean="false"
  if [[ "$allow_dirty" != "1" ]]; then
    echo "Refusing to package a dirty source tree." >&2
    echo "Set INTERVIEW_ARC_LIVE_ALLOW_DIRTY=1 only for an explicit development build." >&2
    exit 65
  fi
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "Packaging the MLX runtime requires Xcode and xcodebuild." >&2
  exit 69
fi

expected_build_receipt="source_commit=$source_commit
scheme=$package_scheme
configuration=$xcode_configuration
enable_testability=$package_testability
macosx_deployment_target=$deployment_target
code_signing_allowed=$code_signing_allowed"
if [[ -f "$build_receipt" && "$(<"$build_receipt")" == "$expected_build_receipt" ]]; then
  echo "Reusing verified $xcode_configuration build products from $derived_data."
else
  # MLX compiles Metal shaders through Xcode. A plain `swift build` can produce
  # source objects while omitting the runtime metallib, so it is not accepted as
  # release evidence for the TTS-enabled application.
  xcodebuild build \
    -scheme "$package_scheme" \
    -configuration "$xcode_configuration" \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived_data" \
    -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile \
    MACOSX_DEPLOYMENT_TARGET="$deployment_target" \
    ENABLE_TESTABILITY="$package_testability" \
    CODE_SIGNING_ALLOWED="$code_signing_allowed"
  printf 'source_commit=%s\nscheme=%s\nconfiguration=%s\nenable_testability=%s\nmacosx_deployment_target=%s\ncode_signing_allowed=%s\n' \
    "$source_commit" "$package_scheme" "$xcode_configuration" \
    "$package_testability" "$deployment_target" "$code_signing_allowed" \
    > "$build_receipt"
fi

bin_dir="$derived_data/Build/Products/$xcode_configuration"
executable="$bin_dir/$executable_name"
smoke_executable="$bin_dir/$smoke_executable_name"
endpoint_smoke_executable="$bin_dir/$endpoint_smoke_executable_name"
speech_smoke_executable="$bin_dir/$speech_smoke_executable_name"

if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  source_tree_clean="false"
  if [[ "$allow_dirty" != "1" ]]; then
    echo "The build changed tracked or untracked source state; packaging stopped." >&2
    exit 65
  fi
fi

if [[ ! -x "$executable" || ! -x "$smoke_executable" \
    || ! -x "$endpoint_smoke_executable" || ! -x "$speech_smoke_executable" ]]; then
  echo "A built application executable or installed-smoke helper is missing." >&2
  exit 66
fi

mlx_resource_bundle="$bin_dir/mlx-swift_Cmlx.bundle"
mlx_metallib_candidates=("$mlx_resource_bundle"/**/default.metallib(N))
if [[ ! -d "$mlx_resource_bundle" || ${#mlx_metallib_candidates} -ne 1 \
    || ! -f "${mlx_metallib_candidates[1]}" ]]; then
  echo "The Xcode build did not produce exactly one MLX default.metallib resource." >&2
  exit 66
fi

# The target is deliberately fixed beneath this repository. Packaging never
# discovers or replaces an installed application.
if [[ "$app_dir" != "$repo_root/dist/$app_name" ]]; then
  echo "Refusing an unexpected package destination." >&2
  exit 65
fi

rm -rf "$app_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Helpers" "$contents_dir/Resources"
cp "$info_plist" "$contents_dir/Info.plist"
cp "$app_icon" "$contents_dir/Resources/InterviewArcLive.icns"
cp "$executable" "$contents_dir/MacOS/$executable_name"
cp "$smoke_executable" "$contents_dir/Helpers/$smoke_executable_name"
cp "$endpoint_smoke_executable" "$contents_dir/Helpers/$endpoint_smoke_executable_name"
cp "$speech_smoke_executable" "$contents_dir/Helpers/$speech_smoke_executable_name"
chmod 0755 "$contents_dir/MacOS/$executable_name"
chmod 0755 "$contents_dir/Helpers/$smoke_executable_name"
chmod 0755 "$contents_dir/Helpers/$endpoint_smoke_executable_name"
chmod 0755 "$contents_dir/Helpers/$speech_smoke_executable_name"

for resource_bundle in "$bin_dir"/*.bundle; do
  if [[ -d "$resource_bundle" ]]; then
    /usr/bin/ditto "$resource_bundle" \
      "$contents_dir/Resources/${resource_bundle:t}"
  fi
done

packaged_mlx_bundle="$contents_dir/Resources/mlx-swift_Cmlx.bundle"
packaged_metallib_candidates=("$packaged_mlx_bundle"/**/default.metallib(N))
if [[ ! -d "$packaged_mlx_bundle" || ${#packaged_metallib_candidates} -ne 1 \
    || ! -f "${packaged_metallib_candidates[1]}" ]]; then
  echo "The packaged application is missing the exact MLX Metal resource." >&2
  exit 66
fi
packaged_metallib="${packaged_metallib_candidates[1]}"

/usr/bin/codesign \
  --force \
  --sign "$signing_identity" \
  --timestamp=none \
  "$contents_dir/Helpers/$smoke_executable_name"

/usr/bin/codesign \
  --force \
  --sign "$signing_identity" \
  --timestamp=none \
  "$contents_dir/Helpers/$endpoint_smoke_executable_name"

/usr/bin/codesign \
  --force \
  --sign "$signing_identity" \
  --timestamp=none \
  "$contents_dir/Helpers/$speech_smoke_executable_name"

/usr/bin/codesign \
  --force \
  --sign "$signing_identity" \
  --timestamp=none \
  "$app_dir"

/usr/bin/codesign --verify --deep --strict --verbose=2 "$app_dir"
/usr/bin/plutil -lint "$contents_dir/Info.plist"

actual_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$contents_dir/Info.plist")"
actual_executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$contents_dir/Info.plist")"
if [[ "$actual_identifier" != "app.interviewarc.live" || "$actual_executable" != "$executable_name" ]]; then
  echo "Packaged application metadata does not match Interview Arc Live." >&2
  exit 65
fi

executable_sha256="$(/usr/bin/shasum -a 256 "$contents_dir/MacOS/$executable_name" | /usr/bin/awk '{print $1}')"
smoke_executable_sha256="$(/usr/bin/shasum -a 256 "$contents_dir/Helpers/$smoke_executable_name" | /usr/bin/awk '{print $1}')"
endpoint_smoke_executable_sha256="$(/usr/bin/shasum -a 256 "$contents_dir/Helpers/$endpoint_smoke_executable_name" | /usr/bin/awk '{print $1}')"
speech_smoke_executable_sha256="$(/usr/bin/shasum -a 256 "$contents_dir/Helpers/$speech_smoke_executable_name" | /usr/bin/awk '{print $1}')"
info_plist_sha256="$(/usr/bin/shasum -a 256 "$contents_dir/Info.plist" | /usr/bin/awk '{print $1}')"
code_directory_hash="$(/usr/bin/codesign -dvvv "$app_dir" 2>&1 | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
resource_bundle_count="$(/usr/bin/find "$contents_dir/Resources" -mindepth 1 -maxdepth 1 -type d -name '*.bundle' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
mlx_metallib_relative_path="${packaged_metallib#$app_dir/}"
mlx_metallib_sha256="$(/usr/bin/shasum -a 256 "$packaged_metallib" | /usr/bin/awk '{print $1}')"
mlx_metallib_byte_count="$(/usr/bin/stat -f '%z' "$packaged_metallib")"
signature_mode="certificate"
if [[ "$signing_identity" == "-" ]]; then
  signature_mode="ad-hoc"
fi

{
  print -r -- "bundle_identifier=$actual_identifier"
  print -r -- "configuration=$configuration"
  print -r -- "source_commit=$source_commit"
  print -r -- "source_tree_clean=$source_tree_clean"
  print -r -- "signature_mode=$signature_mode"
  print -r -- "code_directory_hash=$code_directory_hash"
  print -r -- "executable_sha256=$executable_sha256"
  print -r -- "codex_smoke_executable_sha256=$smoke_executable_sha256"
  print -r -- "endpoint_smoke_executable_sha256=$endpoint_smoke_executable_sha256"
  print -r -- "speech_smoke_executable_sha256=$speech_smoke_executable_sha256"
  print -r -- "info_plist_sha256=$info_plist_sha256"
  print -r -- "resource_bundle_count=$resource_bundle_count"
  print -r -- "mlx_metallib_relative_path=$mlx_metallib_relative_path"
  print -r -- "mlx_metallib_sha256=$mlx_metallib_sha256"
  print -r -- "mlx_metallib_byte_count=$mlx_metallib_byte_count"
} > "$manifest_path"
chmod 0600 "$manifest_path"

"$repo_root/scripts/verify-package-manifest.sh" "$app_dir" "$manifest_path"

echo "$app_dir"
echo "$manifest_path"
