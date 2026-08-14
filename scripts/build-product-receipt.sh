#!/bin/zsh

set -euo pipefail

if [[ $# -ne 8 ]]; then
  echo "Usage: $0 <source-commit> <scheme> <configuration> <testability> <deployment-target> <code-signing> <sdk-name> <target-architecture>" >&2
  exit 64
fi

for tool in xcodebuild xcrun; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Build-product receipts require $tool." >&2
    exit 69
  fi
done

sdk_name="$7"
target_architecture="$8"
if [[ ! "$sdk_name" =~ '^[A-Za-z0-9._-]+$' ]]; then
  echo "Build-product receipts require a simple SDK name." >&2
  exit 64
fi
case "$target_architecture" in
  arm64|x86_64) ;;
  *)
    echo "Build-product receipts require an explicit macOS architecture." >&2
    exit 64
    ;;
esac

developer_dir="${DEVELOPER_DIR:-$(/usr/bin/xcode-select -p)}"
developer_dir="${developer_dir:A}"
if [[ ! -d "$developer_dir" ]]; then
  echo "Build-product receipts require the selected developer directory." >&2
  exit 69
fi
sdk_path="$(xcrun --sdk "$sdk_name" --show-sdk-path)"
sdk_path="${sdk_path:A}"
if [[ ! -d "$sdk_path" ]]; then
  echo "Build-product receipts require the selected SDK." >&2
  exit 69
fi
sdk_version="$(xcrun --sdk "$sdk_name" --show-sdk-version)"
sdk_build_version="$(xcrun --sdk "$sdk_name" --show-sdk-build-version)"
metal_tool="$(xcrun --sdk "$sdk_name" --find metal)"
if [[ ! -f "$metal_tool" ]]; then
  echo "Build-product receipts require the installed Metal compiler." >&2
  exit 69
fi
xcode_version_sha256="$(xcodebuild -version | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
metal_tool_sha256="$(/usr/bin/shasum -a 256 "$metal_tool" | /usr/bin/awk '{print $1}')"
developer_dir_sha256="$(printf '%s' "$developer_dir" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"
sdk_path_sha256="$(printf '%s' "$sdk_path" | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')"

printf 'source_commit=%s\nscheme=%s\nconfiguration=%s\nenable_testability=%s\nmacosx_deployment_target=%s\ncode_signing_allowed=%s\nxcode_version_sha256=%s\nmetal_tool_sha256=%s\ndeveloper_dir_sha256=%s\nsdk_name=%s\nsdk_path_sha256=%s\nsdk_version=%s\nsdk_build_version=%s\ntarget_architecture=%s\nonly_active_arch=YES\n' \
  "$1" "$2" "$3" "$4" "$5" "$6" \
  "$xcode_version_sha256" "$metal_tool_sha256" \
  "$developer_dir_sha256" "$sdk_name" "$sdk_path_sha256" \
  "$sdk_version" "$sdk_build_version" "$target_architecture"
