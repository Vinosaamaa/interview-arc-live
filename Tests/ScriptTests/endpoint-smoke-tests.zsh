#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h:h}"
smoke_script="$repo_root/scripts/smoke-installed-endpoint.sh"
manifest_verifier="$repo_root/scripts/verify-package-manifest.sh"
test_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/interview-arc-live-endpoint-smoke-tests.XXXXXX")"

cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

installed_app="$test_root/Applications/Interview Arc Live.app"
app_executable="$installed_app/Contents/MacOS/InterviewArcLive"
codex_helper="$installed_app/Contents/Helpers/InterviewArcLiveCodexSmoke"
endpoint_helper="$installed_app/Contents/Helpers/InterviewArcLiveEndpointSmoke"
speech_helper="$installed_app/Contents/Helpers/InterviewArcLiveSpeechSmoke"
info_plist="$installed_app/Contents/Info.plist"
mlx_metallib="$installed_app/Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib"
observed_cwd="$test_root/observed-cwd"

mkdir -p "$installed_app/Contents/MacOS" "$installed_app/Contents/Helpers" \
  "${mlx_metallib:h}"
/usr/bin/plutil -create xml1 "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string app.interviewarc.live' "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string InterviewArcLive' "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$info_plist"
print -r -- $'#!/bin/zsh\nexit 0' > "$app_executable"
print -r -- $'#!/bin/zsh\nexit 0' > "$codex_helper"
print -r -- $'#!/bin/zsh\n[[ "${INTERVIEW_ARC_LIVE_RUN_ENDPOINT_SMOKE:-0}" == "1" ]] || exit 64\nprint -r -- "$PWD" > "${INTERVIEW_ARC_LIVE_TEST_OBSERVED_CWD:?}"' > "$endpoint_helper"
print -r -- $'#!/bin/zsh\nexit 0' > "$speech_helper"
print -rn -- 'fixture-metallib' > "$mlx_metallib"
chmod 0755 "$app_executable" "$codex_helper" "$endpoint_helper" "$speech_helper"
/usr/bin/codesign --force --sign - --timestamp=none "$codex_helper" >/dev/null
/usr/bin/codesign --force --sign - --timestamp=none "$endpoint_helper" >/dev/null
/usr/bin/codesign --force --sign - --timestamp=none "$speech_helper" >/dev/null
/usr/bin/codesign --force --sign - --timestamp=none "$installed_app" >/dev/null

if INTERVIEW_ARC_LIVE_TEST_OBSERVED_CWD="$observed_cwd" \
  "$smoke_script" "$installed_app" >/dev/null 2>&1; then
  fail "smoke ran without explicit opt-in"
fi
[[ ! -e "$observed_cwd" ]] || fail "non-opt-in smoke invoked the helper"

if INTERVIEW_ARC_LIVE_RUN_ENDPOINT_SMOKE=1 \
  INTERVIEW_ARC_LIVE_TEST_OBSERVED_CWD="$observed_cwd" \
  "$smoke_script" "$installed_app" >/dev/null 2>&1; then
  fail "ad-hoc smoke ran without an exact package manifest"
fi
[[ ! -e "$observed_cwd" ]] || fail "manifest-less smoke invoked the helper"

manifest="$test_root/InterviewArcLive.package-manifest.txt"
cdhash="$(/usr/bin/codesign -dvvv "$installed_app" 2>&1 | /usr/bin/awk -F= '/^CDHash=/{print $2; exit}')"
app_sha="$(/usr/bin/shasum -a 256 "$app_executable" | /usr/bin/awk '{print $1}')"
codex_sha="$(/usr/bin/shasum -a 256 "$codex_helper" | /usr/bin/awk '{print $1}')"
endpoint_sha="$(/usr/bin/shasum -a 256 "$endpoint_helper" | /usr/bin/awk '{print $1}')"
speech_sha="$(/usr/bin/shasum -a 256 "$speech_helper" | /usr/bin/awk '{print $1}')"
info_sha="$(/usr/bin/shasum -a 256 "$info_plist" | /usr/bin/awk '{print $1}')"
mlx_sha="$(/usr/bin/shasum -a 256 "$mlx_metallib" | /usr/bin/awk '{print $1}')"
mlx_bytes="$(/usr/bin/stat -f '%z' "$mlx_metallib")"
{
  print -r -- "bundle_identifier=app.interviewarc.live"
  print -r -- "code_directory_hash=$cdhash"
  print -r -- "executable_sha256=$app_sha"
  print -r -- "codex_smoke_executable_sha256=$codex_sha"
  print -r -- "endpoint_smoke_executable_sha256=$endpoint_sha"
  print -r -- "speech_smoke_executable_sha256=$speech_sha"
  print -r -- "info_plist_sha256=$info_sha"
  print -r -- "resource_bundle_count=1"
  print -r -- "mlx_metallib_relative_path=Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib"
  print -r -- "mlx_metallib_sha256=$mlx_sha"
  print -r -- "mlx_metallib_byte_count=$mlx_bytes"
} > "$manifest"
"$manifest_verifier" "$installed_app" "$manifest" >/dev/null

INTERVIEW_ARC_LIVE_RUN_ENDPOINT_SMOKE=1 \
INTERVIEW_ARC_LIVE_TEST_OBSERVED_CWD="$observed_cwd" \
  "$smoke_script" "$installed_app" "$manifest" >/dev/null
[[ -f "$observed_cwd" ]] || fail "opt-in smoke did not invoke the installed helper"
helper_cwd="$(<"$observed_cwd")"
[[ "$helper_cwd" != "${repo_root:A}"/* ]] || fail "helper ran inside the repository"
[[ "${helper_cwd:t}" == interview-arc-live-endpoint-smoke.* ]] \
  || fail "helper did not run in an isolated smoke directory"
[[ ! -e "$helper_cwd" ]] || fail "smoke directory was not removed"

tampered_manifest="$test_root/InterviewArcLive.tampered-package-manifest.txt"
{
  print -r -- "bundle_identifier=app.interviewarc.live"
  print -r -- "code_directory_hash=$cdhash"
  print -r -- "executable_sha256=$app_sha"
  print -r -- "codex_smoke_executable_sha256=$codex_sha"
  print -r -- "endpoint_smoke_executable_sha256=0000000000000000000000000000000000000000000000000000000000000000"
  print -r -- "speech_smoke_executable_sha256=$speech_sha"
  print -r -- "info_plist_sha256=$info_sha"
  print -r -- "resource_bundle_count=1"
  print -r -- "mlx_metallib_relative_path=Contents/Resources/mlx-swift_Cmlx.bundle/default.metallib"
  print -r -- "mlx_metallib_sha256=$mlx_sha"
  print -r -- "mlx_metallib_byte_count=$mlx_bytes"
} > "$tampered_manifest"
rm -f "$observed_cwd"
if INTERVIEW_ARC_LIVE_RUN_ENDPOINT_SMOKE=1 \
  INTERVIEW_ARC_LIVE_TEST_OBSERVED_CWD="$observed_cwd" \
  "$smoke_script" "$installed_app" "$tampered_manifest" >/dev/null 2>&1; then
  fail "smoke accepted a tampered package manifest"
fi
[[ ! -e "$observed_cwd" ]] || fail "manifest mismatch invoked the helper"

print -r -- $'#!/bin/zsh\nexit 1' > "$endpoint_helper"
chmod 0755 "$endpoint_helper"
rm -f "$observed_cwd"
if INTERVIEW_ARC_LIVE_RUN_ENDPOINT_SMOKE=1 \
  INTERVIEW_ARC_LIVE_TEST_OBSERVED_CWD="$observed_cwd" \
  "$smoke_script" "$installed_app" "$manifest" >/dev/null 2>&1; then
  fail "smoke accepted an endpoint helper that did not match the package manifest"
fi
[[ ! -e "$observed_cwd" ]] || fail "unverified endpoint helper was executed"

echo "Installed endpoint smoke opt-in, isolated cwd, and manifest-tamper tests passed."
