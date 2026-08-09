#!/bin/zsh

set -euo pipefail

opt_in="${INTERVIEW_ARC_LIVE_RUN_SPEECH_SMOKE:-0}"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 ['/installed/path/Interview Arc Live.app'] '/path/to/InterviewArcLive.package-manifest.txt'" >&2
  exit 64
fi
if [[ "$opt_in" != "1" ]]; then
  echo "Installed local-speech smoke is opt-in." >&2
  echo "Set INTERVIEW_ARC_LIVE_RUN_SPEECH_SMOKE=1 to synthesize and play one public test phrase." >&2
  echo "If the model is absent, separately set INTERVIEW_ARC_LIVE_ALLOW_MODEL_DOWNLOAD=1 to authorize the pinned 1.838 GiB transfer." >&2
  exit 64
fi

source "${0:A:h}/installed-smoke-common.zsh"
interview_arc_live_run_installed_smoke \
  "InterviewArcLiveSpeechSmoke" \
  "interview-arc-live-speech-smoke" \
  "$@"
