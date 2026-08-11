#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h:h}"
smoke_script="$repo_root/scripts/smoke-installed-codex.sh"
manifest_verifier="$repo_root/scripts/verify-package-manifest.sh"
test_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/interview-arc-live-smoke-tests.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

make_bundle() {
  local bundle="$1"
  local identifier="$2"
  local helper="$bundle/Contents/Helpers/InterviewArcLiveCodexSmoke"
  local endpoint_helper="$bundle/Contents/Helpers/InterviewArcLiveEndpointSmoke"
  local speech_helper="$bundle/Contents/Helpers/InterviewArcLiveSpeechSmoke"
  local mlx_metallib="$bundle/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib"
  local app_icon="$bundle/Contents/Resources/InterviewArcLive.icns"

  mkdir -p "$bundle/Contents/Helpers" "${mlx_metallib:h}"
  /usr/bin/plutil -create xml1 "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $identifier" \
    "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string InterviewArcLive' \
    "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' \
    "$bundle/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string InterviewArcLive.icns' \
    "$bundle/Contents/Info.plist"
  mkdir -p "$bundle/Contents/MacOS"
  print -r -- $'#!/bin/zsh\nexit 0' > "$bundle/Contents/MacOS/InterviewArcLive"
  print -r -- $'#!/bin/zsh\n[[ "${INTERVIEW_ARC_LIVE_RUN_CODEX_SMOKE:-0}" == "1" ]] || exit 64\nprint -r -- "$PWD" > "${INTERVIEW_ARC_LIVE_TEST_OBSERVED_CWD:?}"' > "$helper"
  print -r -- $'#!/bin/zsh\nexit 0' > "$endpoint_helper"
  print -r -- $'#!/bin/zsh\nexit 0' > "$speech_helper"
  print -rn -- 'fixture-metallib' > "$mlx_metallib"
  print -rn -- 'fixture-icon' > "$app_icon"
  chmod 0755 "$bundle/Contents/MacOS/InterviewArcLive" "$helper" \
    "$endpoint_helper" "$speech_helper"
  /usr/bin/codesign --force --sign - --timestamp=none "$helper" >/dev/null
  /usr/bin/codesign --force --sign - --timestamp=none "$endpoint_helper" >/dev/null
  /usr/bin/codesign --force --sign - --timestamp=none "$speech_helper" >/dev/null
  /usr/bin/codesign --force --sign - --timestamp=none "$bundle" >/dev/null
}

installed_app="$test_root/Applications/Interview Arc Live.app"
observed_cwd="$test_root/observed-cwd"
make_bundle "$installed_app" "app.interviewarc.live"

if INTERVIEW_ARC_LIVE_TEST_OBSERVED_CWD="$observed_cwd" \
  "$smoke_script" "$installed_app" >/dev/null 2>&1; then
  fail "smoke ran without explicit opt-in"
fi
[[ ! -e "$observed_cwd" ]] || fail "non-opt-in smoke invoked the helper"

manifest="$test_root/InterviewArcLive.package-manifest.txt"
app_executable="$installed_app/Contents/MacOS/InterviewArcLive"
smoke_executable="$installed_app/Contents/Helpers/InterviewArcLiveCodexSmoke"
endpoint_smoke_executable="$installed_app/Contents/Helpers/InterviewArcLiveEndpointSmoke"
speech_smoke_executable="$installed_app/Contents/Helpers/InterviewArcLiveSpeechSmoke"
info_plist="$installed_app/Contents/Info.plist"
mlx_metallib="$installed_app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib"
cdhash="$(/usr/bin/codesign -dvvv "$installed_app" 2>&1 | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
app_sha="$(/usr/bin/shasum -a 256 "$app_executable" | /usr/bin/awk '{print $1}')"
smoke_sha="$(/usr/bin/shasum -a 256 "$smoke_executable" | /usr/bin/awk '{print $1}')"
endpoint_smoke_sha="$(/usr/bin/shasum -a 256 "$endpoint_smoke_executable" | /usr/bin/awk '{print $1}')"
speech_smoke_sha="$(/usr/bin/shasum -a 256 "$speech_smoke_executable" | /usr/bin/awk '{print $1}')"
info_sha="$(/usr/bin/shasum -a 256 "$info_plist" | /usr/bin/awk '{print $1}')"
mlx_sha="$(/usr/bin/shasum -a 256 "$mlx_metallib" | /usr/bin/awk '{print $1}')"
mlx_bytes="$(/usr/bin/stat -f '%z' "$mlx_metallib")"
{
  print -r -- "bundle_identifier=app.interviewarc.live"
  print -r -- "code_directory_hash=$cdhash"
  print -r -- "executable_sha256=$app_sha"
  print -r -- "codex_smoke_executable_sha256=$smoke_sha"
  print -r -- "endpoint_smoke_executable_sha256=$endpoint_smoke_sha"
  print -r -- "speech_smoke_executable_sha256=$speech_smoke_sha"
  print -r -- "info_plist_sha256=$info_sha"
  print -r -- "resource_bundle_count=1"
  print -r -- "mlx_metallib_relative_path=Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib"
  print -r -- "mlx_metallib_sha256=$mlx_sha"
  print -r -- "mlx_metallib_byte_count=$mlx_bytes"
} > "$manifest"
"$manifest_verifier" "$installed_app" "$manifest" >/dev/null

if INTERVIEW_ARC_LIVE_RUN_CODEX_SMOKE=1 \
  INTERVIEW_ARC_LIVE_TEST_OBSERVED_CWD="$observed_cwd" \
  "$smoke_script" "$installed_app" >/dev/null 2>&1; then
  fail "ad-hoc smoke ran without an exact package manifest"
fi
[[ ! -e "$observed_cwd" ]] || fail "manifest-less smoke invoked the helper"

INTERVIEW_ARC_LIVE_RUN_CODEX_SMOKE=1 \
INTERVIEW_ARC_LIVE_TEST_OBSERVED_CWD="$observed_cwd" \
  "$smoke_script" "$installed_app" "$manifest" >/dev/null

[[ -f "$observed_cwd" ]] || fail "opt-in smoke did not invoke the installed helper"
helper_cwd="$(<"$observed_cwd")"
[[ "$helper_cwd" != "${repo_root:A}"/* ]] || fail "helper ran inside the repository"
[[ "${helper_cwd:t}" == interview-arc-live-codex-smoke.* ]] \
  || fail "helper did not run in an isolated smoke directory"
[[ ! -e "$helper_cwd" ]] || fail "smoke directory was not removed"

print -r -- $'#!/bin/zsh\nexit 1' > "$smoke_executable"
chmod 0755 "$smoke_executable"
if "$manifest_verifier" "$installed_app" "$manifest" >/dev/null 2>&1; then
  fail "manifest verification accepted a changed smoke helper"
fi
rm -f "$observed_cwd"
if INTERVIEW_ARC_LIVE_RUN_CODEX_SMOKE=1 \
  INTERVIEW_ARC_LIVE_TEST_OBSERVED_CWD="$observed_cwd" \
  "$smoke_script" "$installed_app" "$manifest" >/dev/null 2>&1; then
  fail "smoke accepted a helper that did not match the exact package manifest"
fi
[[ ! -e "$observed_cwd" ]] || fail "unverified helper was executed"

unrelated_app="$test_root/Applications/Unrelated/Interview Arc Live.app"
make_bundle "$unrelated_app" "example.unrelated"
if INTERVIEW_ARC_LIVE_RUN_CODEX_SMOKE=1 \
  INTERVIEW_ARC_LIVE_TEST_OBSERVED_CWD="$observed_cwd" \
  "$smoke_script" "$unrelated_app" "$manifest" >/dev/null 2>&1; then
  fail "smoke accepted an unrelated bundle"
fi

echo "Installed Codex smoke opt-in, bundle identity, isolated cwd, and manifest tests passed."
