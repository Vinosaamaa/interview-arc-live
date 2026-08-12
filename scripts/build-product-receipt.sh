#!/bin/zsh

set -euo pipefail

if [[ $# -ne 6 ]]; then
  echo "Usage: $0 <source-commit> <scheme> <configuration> <testability> <deployment-target> <code-signing>" >&2
  exit 64
fi

for tool in xcodebuild xcrun; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Build-product receipts require $tool." >&2
    exit 69
  fi
done

developer_dir="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
developer_dir="${developer_dir:A}"
macos_sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
macos_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
macos_sdk_build_version="$(xcrun --sdk macosx --show-sdk-build-version)"
target_architecture="$(uname -m)"
metal_tool="$(xcrun --find metal)"
if [[ ! -f "$metal_tool" ]]; then
  echo "Build-product receipts require the installed Metal compiler." >&2
  exit 69
fi
xcode_version_sha256="$(xcodebuild -version | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
metal_tool_sha256="$(/usr/bin/shasum -a 256 "$metal_tool" | /usr/bin/awk '{print $1}')"
developer_dir_sha256="$(printf '%s' "$developer_dir" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
macos_sdk_path_sha256="$(printf '%s' "$macos_sdk_path" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"

printf 'source_commit=%s\nscheme=%s\nconfiguration=%s\nenable_testability=%s\nmacosx_deployment_target=%s\ncode_signing_allowed=%s\nxcode_version_sha256=%s\nmetal_tool_sha256=%s\ndeveloper_dir_sha256=%s\nmacos_sdk_path_sha256=%s\nmacos_sdk_version=%s\nmacos_sdk_build_version=%s\ntarget_architecture=%s\n' \
  "$1" "$2" "$3" "$4" "$5" "$6" \
  "$xcode_version_sha256" "$metal_tool_sha256" \
  "$developer_dir_sha256" "$macos_sdk_path_sha256" \
  "$macos_sdk_version" "$macos_sdk_build_version" "$target_architecture"
