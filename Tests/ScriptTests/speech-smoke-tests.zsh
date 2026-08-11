#!/bin/zsh

set -euo pipefail

repo_root="${0:A:h:h:h}"
smoke_script="$repo_root/scripts/smoke-installed-speech.sh"
manifest_verifier="$repo_root/scripts/verify-package-manifest.sh"
test_root="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/interview-arc-live-speech-smoke-tests.XXXXXX")"

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
app_icon="$installed_app/Contents/Resources/InterviewArcLive.icns"
sealed_unmanifested_resource="$installed_app/Contents/Resources/mlx-swift_Cmlx.bundle/Qwen3TTSModelNOTICE.txt"
observed="$test_root/observed"

mkdir -p "$installed_app/Contents/MacOS" "$installed_app/Contents/Helpers" \
  "${mlx_metallib:h}"
/usr/bin/plutil -create xml1 "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIdentifier string app.interviewarc.live' "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleExecutable string InterviewArcLive' "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundlePackageType string APPL' "$info_plist"
/usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string InterviewArcLive.icns' "$info_plist"
print -r -- $'#!/bin/zsh\nexit 0' > "$app_executable"
print -r -- $'#!/bin/zsh\nexit 0' > "$codex_helper"
print -r -- $'#!/bin/zsh\nexit 0' > "$endpoint_helper"
print -r -- $'#!/bin/zsh\n[[ "${INTERVIEW_ARC_LIVE_RUN_SPEECH_SMOKE:-0}" == "1" ]] || exit 64\n[[ -f "$PWD/default.metallib" && ! -L "$PWD/default.metallib" ]] || exit 65\n[[ "$(/usr/bin/shasum -a 256 "$PWD/default.metallib" | /usr/bin/awk \'{print $1}\')" == "${INTERVIEW_ARC_LIVE_TEST_EXPECTED_MLX_SHA:?}" ]] || exit 65\n[[ "$(/usr/bin/stat -f \'%z\' "$PWD/default.metallib")" == "${INTERVIEW_ARC_LIVE_TEST_EXPECTED_MLX_BYTES:?}" ]] || exit 65\nprint -r -- "$PWD|${INTERVIEW_ARC_LIVE_ALLOW_MODEL_DOWNLOAD:-0}" > "${INTERVIEW_ARC_LIVE_TEST_OBSERVED:?}"\nprint -r -- "public upstream status that must be filtered"\nprint -r -- "model_revision=049ef77fe8816b536193c0c25f9a214d17921282"\nprint -r -- "chunk_count=2"\nprint -r -- "time_to_first_audio_ms=120"\nprint -r -- "generation_total_ms=920"\nprint -r -- "audio_duration_ms=1400"\nprint -r -- "audio_bytes=134444"' > "$speech_helper"
print -rn -- 'fixture-metallib' > "$mlx_metallib"
print -rn -- 'fixture-icon' > "$app_icon"
print -rn -- 'fixture-notice' > "$sealed_unmanifested_resource"
chmod 0755 "$app_executable" "$codex_helper" "$endpoint_helper" "$speech_helper"
/usr/bin/codesign --force --sign - --timestamp=none "$codex_helper" >/dev/null
/usr/bin/codesign --force --sign - --timestamp=none "$endpoint_helper" >/dev/null
/usr/bin/codesign --force --sign - --timestamp=none "$speech_helper" >/dev/null
/usr/bin/codesign --force --sign - --timestamp=none "$installed_app" >/dev/null

if INTERVIEW_ARC_LIVE_TEST_OBSERVED="$observed" \
  "$smoke_script" "$installed_app" >/dev/null 2>&1; then
  fail "speech smoke ran without explicit opt-in"
fi
[[ ! -e "$observed" ]] || fail "non-opt-in speech smoke invoked the helper"

if INTERVIEW_ARC_LIVE_RUN_SPEECH_SMOKE=1 \
  INTERVIEW_ARC_LIVE_TEST_OBSERVED="$observed" \
  "$smoke_script" "$installed_app" >/dev/null 2>&1; then
  fail "speech smoke ran without an exact package manifest"
fi
[[ ! -e "$observed" ]] || fail "manifest-less speech smoke invoked the helper"

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

report="$test_root/speech-report.txt"
INTERVIEW_ARC_LIVE_RUN_SPEECH_SMOKE=1 \
INTERVIEW_ARC_LIVE_ALLOW_MODEL_DOWNLOAD=1 \
INTERVIEW_ARC_LIVE_TEST_OBSERVED="$observed" \
INTERVIEW_ARC_LIVE_TEST_EXPECTED_MLX_SHA="$mlx_sha" \
INTERVIEW_ARC_LIVE_TEST_EXPECTED_MLX_BYTES="$mlx_bytes" \
  "$smoke_script" "$installed_app" "$manifest" > "$report"
[[ -f "$observed" ]] || fail "opt-in speech smoke did not invoke the helper"
observed_value="$(<"$observed")"
helper_cwd="${observed_value%%|*}"
observed_download_opt_in="${observed_value##*|}"
[[ "$helper_cwd" != "${repo_root:A}"/* ]] || fail "speech helper ran inside the repository"
[[ "${helper_cwd:t}" == interview-arc-live-speech-smoke.* ]] \
  || fail "speech helper did not run in an isolated smoke directory"
[[ ! -e "$helper_cwd" ]] || fail "speech smoke directory was not removed"
[[ "$observed_download_opt_in" == "1" ]] \
  || fail "separate model-download authorization was not forwarded"
expected_report=$'model_revision=049ef77fe8816b536193c0c25f9a214d17921282\nchunk_count=2\ntime_to_first_audio_ms=120\ngeneration_total_ms=920\naudio_duration_ms=1400\naudio_bytes=134444'
[[ "$(<"$report")" == "$expected_report" ]] \
  || fail "speech smoke did not expose only the approved report fields"

tampered_manifest="$test_root/InterviewArcLive.tampered-package-manifest.txt"
/usr/bin/sed \
  's/^speech_smoke_executable_sha256=.*/speech_smoke_executable_sha256=0000000000000000000000000000000000000000000000000000000000000000/' \
  "$manifest" > "$tampered_manifest"
rm -f "$observed"
if INTERVIEW_ARC_LIVE_RUN_SPEECH_SMOKE=1 \
  INTERVIEW_ARC_LIVE_TEST_OBSERVED="$observed" \
  "$smoke_script" "$installed_app" "$tampered_manifest" >/dev/null 2>&1; then
  fail "speech smoke accepted a changed helper hash"
fi
[[ ! -e "$observed" ]] || fail "unverified speech helper was executed"

tampered_mlx_manifest="$test_root/InterviewArcLive.tampered-mlx-manifest.txt"
/usr/bin/sed \
  's/^mlx_metallib_sha256=.*/mlx_metallib_sha256=0000000000000000000000000000000000000000000000000000000000000000/' \
  "$manifest" > "$tampered_mlx_manifest"
if "$manifest_verifier" "$installed_app" "$tampered_mlx_manifest" >/dev/null 2>&1; then
  fail "package verification accepted a changed MLX Metal resource hash"
fi

print -rn -- 'changed-sealed-notice' > "$sealed_unmanifested_resource"
if "$manifest_verifier" "$installed_app" "$manifest" >/dev/null 2>&1; then
  fail "standalone package verification accepted a changed sealed resource"
fi

echo "Installed speech smoke opt-in, download authorization, isolated cwd, helper hash, and staged MLX resource tests passed."
