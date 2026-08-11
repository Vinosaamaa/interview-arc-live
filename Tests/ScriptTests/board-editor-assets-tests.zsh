#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h:h}"
editor_root="$repo_root/Web/BoardEditor"
resource_root="$repo_root/Sources/InterviewArcLive/Resources/BoardEditor"
info_plist="$repo_root/Resources/Info.plist"
test_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/interview-arc-live-board-assets.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

cd "$editor_root"
npm ci --ignore-scripts --no-audit --no-fund
npm run build

expected_resources="$test_root/BoardEditor"
mkdir -p "$expected_resources"
cp -R "$editor_root/dist/." "$expected_resources"
cp "$repo_root/THIRD_PARTY_NOTICES.md" \
  "$expected_resources/THIRD_PARTY_NOTICES.md"
diff -qr "$expected_resources" "$resource_root" >/dev/null \
  || fail "checked-in Board editor resources do not match the exact web build"

grep -Fq "connect-src 'none'" "$resource_root/index.html" \
  || fail "Board editor content security policy permits network connections"
grep -Fq 'window.EXCALIDRAW_ASSET_PATH = "./assets/"' \
  "$resource_root/asset-path.js" \
  || fail "Board editor asset path is not local"
if find "$resource_root" -type f -size +8388608c | grep -q .; then
  fail "a Board editor asset exceeds the bounded local resource size"
fi

icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$info_plist")"
[[ "$icon_name" == "InterviewArcLive.icns" ]] \
  || fail "application metadata does not name the Interview Arc Live icon"
app_icon="$repo_root/Resources/$icon_name"
[[ -f "$app_icon" && ! -L "$app_icon" ]] \
  || fail "application icon is missing or is a symbolic link"

iconset="$test_root/InterviewArcLive.iconset"
/usr/bin/iconutil -c iconset "$app_icon" -o "$iconset"
[[ "$(/usr/bin/sips -g pixelWidth "$iconset/icon_16x16.png" \
  | /usr/bin/awk '/pixelWidth:/{print $2}')" == "16" ]] \
  || fail "application icon is missing its 16-point representation"
[[ "$(/usr/bin/sips -g pixelWidth "$iconset/icon_512x512@2x.png" \
  | /usr/bin/awk '/pixelWidth:/{print $2}')" == "1024" ]] \
  || fail "application icon is missing its 1024-pixel representation"

echo "Board editor exact build, offline policy, resource bounds, notices, and app icon passed."
