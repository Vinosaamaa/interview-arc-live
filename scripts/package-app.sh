#!/bin/zsh

set -euo pipefail
setopt NULL_GLOB

repo_root="${0:A:h:h}"
configuration="${1:-release}"
app_name="Interview Arc Live.app"
app_dir="$repo_root/dist/$app_name"
contents_dir="$app_dir/Contents"
executable_name="InterviewArcLive"
smoke_executable_name="InterviewArcLiveCodexSmoke"
info_plist="$repo_root/Resources/Info.plist"
signing_identity="${INTERVIEW_ARC_LIVE_SIGNING_IDENTITY:--}"
manifest_path="$repo_root/dist/InterviewArcLive.package-manifest.txt"
allow_dirty="${INTERVIEW_ARC_LIVE_ALLOW_DIRTY:-0}"

if [[ "$configuration" != "debug" && "$configuration" != "release" ]]; then
  echo "Usage: $0 [debug|release]" >&2
  exit 64
fi

if [[ ! -f "$info_plist" ]]; then
  echo "Missing application metadata: Resources/Info.plist" >&2
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

swift build -c "$configuration" --product "$executable_name"
swift build -c "$configuration" --product "$smoke_executable_name"
bin_dir="$(swift build -c "$configuration" --show-bin-path)"
executable="$bin_dir/$executable_name"
smoke_executable="$bin_dir/$smoke_executable_name"

if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
  source_tree_clean="false"
  if [[ "$allow_dirty" != "1" ]]; then
    echo "The build changed tracked or untracked source state; packaging stopped." >&2
    exit 65
  fi
fi

if [[ ! -x "$executable" || ! -x "$smoke_executable" ]]; then
  echo "A built application executable or Codex smoke helper is missing." >&2
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
cp "$executable" "$contents_dir/MacOS/$executable_name"
cp "$smoke_executable" "$contents_dir/Helpers/$smoke_executable_name"
chmod 0755 "$contents_dir/MacOS/$executable_name"
chmod 0755 "$contents_dir/Helpers/$smoke_executable_name"

for resource_bundle in "$bin_dir"/*.bundle; do
  if [[ -d "$resource_bundle" ]]; then
    cp -R "$resource_bundle" "$contents_dir/Resources/"
  fi
done

/usr/bin/codesign \
  --force \
  --sign "$signing_identity" \
  --timestamp=none \
  "$contents_dir/Helpers/$smoke_executable_name"

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
info_plist_sha256="$(/usr/bin/shasum -a 256 "$contents_dir/Info.plist" | /usr/bin/awk '{print $1}')"
code_directory_hash="$(/usr/bin/codesign -dvvv "$app_dir" 2>&1 | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
resource_bundle_count="$(/usr/bin/find "$contents_dir/Resources" -mindepth 1 -maxdepth 1 -type d -name '*.bundle' | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
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
  print -r -- "info_plist_sha256=$info_plist_sha256"
  print -r -- "resource_bundle_count=$resource_bundle_count"
} > "$manifest_path"
chmod 0600 "$manifest_path"

"$repo_root/scripts/verify-package-manifest.sh" "$app_dir" "$manifest_path"

echo "$app_dir"
echo "$manifest_path"
