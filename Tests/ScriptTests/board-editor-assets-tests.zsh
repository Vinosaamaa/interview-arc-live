#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h:h}"
editor_root="$repo_root/Web/BoardEditor"
resource_root="$repo_root/Sources/InterviewArcLive/Resources/BoardEditor"
info_plist="$repo_root/Resources/Info.plist"
board_view="$repo_root/Sources/InterviewArcLive/SystemDesignBoardView.swift"
board_bridge="$repo_root/Sources/InterviewArcLive/ExcalidrawBoardEditorView.swift"
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
npm test
npm run build

expected_resources="$test_root/BoardEditor"
mkdir -p "$expected_resources"
cp -R "$editor_root/dist/." "$expected_resources"
cp "$repo_root/THIRD_PARTY_NOTICES.md" \
  "$expected_resources/THIRD_PARTY_NOTICES.md"
diff -qr "$expected_resources" "$resource_root" >/dev/null \
  || fail "checked-in Board editor resources do not match the exact web build"

runtime_probe="$test_root/BoardEditorRuntimeProbe"
runtime_swiftc=(xcrun swiftc)
if [[ -n "${INTERVIEW_ARC_LIVE_WEBKIT_SDK:-}" ]]; then
  runtime_swiftc+=(
    -sdk "$INTERVIEW_ARC_LIVE_WEBKIT_SDK"
    -target "$(uname -m)-apple-macosx14.0"
    -module-cache-path "$test_root/module-cache"
  )
fi
"${runtime_swiftc[@]}" \
  "$repo_root/Tests/ScriptTests/BoardEditorRuntimeProbe.swift" \
  -framework AppKit \
  -framework WebKit \
  -o "$runtime_probe"
"$runtime_probe" "$resource_root"

grep -Fq "connect-src 'none'" "$resource_root/index.html" \
  || fail "Board editor content security policy permits network connections"
grep -Fq 'window.EXCALIDRAW_ASSET_PATH = "./assets/"' \
  "$resource_root/asset-path.js" \
  || fail "Board editor asset path is not local"
grep -Fq 'const semanticBoxPresentation' "$editor_root/src/main.jsx" \
  || fail "Board editor does not retain semantic node presentations"
grep -Fq 'window.interviewArcFlush' "$editor_root/src/main.jsx" \
  || fail "Board editor does not expose the durable-command flush seam"
grep -Fq 'event: "flushedCommand"' "$editor_root/src/main.jsx" \
  || fail "Board editor commands are not gated by native scene acceptance"
grep -Fq 'if (!pointerDownRef.current) publish();' "$editor_root/src/main.jsx" \
  || fail "Board editor text changes are not posted immediately"
if grep -Fq 'setTimeout(publish, 300)' "$editor_root/src/main.jsx"; then
  fail "Board editor can lose a visible edit inside a debounce window"
fi
grep -Fq 'hexagon.fanout' "$editor_root/src/main.jsx" \
  || fail "Board editor lost the canonical service visual vocabulary"
grep -Fq 'SemanticNodeOverlay' "$editor_root/src/main.jsx" \
  || fail "Board editor does not render the canonical semantic pictograms"
grep -Fq 'iaElementType: "label"' \
  "$editor_root/src/main.jsx" \
  || fail "Board editor labels do not retain stable canonical identity"
grep -Fq 'text: element.text' "$editor_root/src/main.jsx" \
  || fail "Board editor labels are not loaded as editable Excalidraw text"
grep -Fq 'text: String(element.text ?? customData.iaText ?? "")' \
  "$editor_root/src/main.jsx" \
  || fail "Board editor label edits are not normalized into canonical text"
if grep -Fq 'detachedContainerLabel' "$editor_root/src/main.jsx"; then
  fail "Board editor still loads the multi-label WebKit text path that freezes the canvas"
fi
if grep -Fq 'setTimeout(() =>' "$editor_root/src/main.jsx"; then
  fail "Board editor load sequencing still depends on an arbitrary timer"
fi
grep -Fq 'radial-gradient(circle' "$editor_root/src/style.css" \
  || fail "Board editor does not retain the approved subtle dot field"
grep -Fq 'fitToContent: false' "$editor_root/src/main.jsx" \
  || fail "Board editor can overwrite the native zoom during reload"
if grep -Fq 'api.history.clear()' "$editor_root/src/main.jsx"; then
  fail "Board editor can freeze while clearing Excalidraw text history"
fi
grep -Fq 'scheduleLoad(snapshot)' "$board_bridge" \
  || fail "Board bridge still reloads WebKit re-entrantly from its ready callback"
grep -Fq 'pendingReloadTask?.cancel()' "$board_bridge" \
  || fail "Board bridge does not coalesce stale pending reloads"
grep -Fq 'Excalidraw · Local' "$board_view" \
  || fail "Board does not identify when the real local Excalidraw editor is active"
grep -Fq 'Retry Excalidraw' "$board_view" \
  || fail "Board fallback does not expose an Excalidraw retry action"
grep -Fq 'gridModeEnabled={false}' "$editor_root/src/main.jsx" \
  || fail "Board editor re-enabled the mismatched major-line grid"
if find "$resource_root" -type f -size +8388608c | grep -q .; then
  fail "a Board editor asset exceeds the bounded local resource size"
fi
[[ -f "$resource_root/assets/excalidraw-assets/vendor-677e88ca78c86bddf13d.js" ]] \
  || fail "Board editor is missing Excalidraw's local runtime chunk"
upstream_notice_count="$(/usr/bin/find "$resource_root/licenses" \
  -maxdepth 1 -type f -name '*.LICENSE.txt' | /usr/bin/wc -l \
  | /usr/bin/tr -d ' ')"
[[ "$upstream_notice_count" == "3" ]] \
  || fail "Board editor does not retain all upstream distribution notices"

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
