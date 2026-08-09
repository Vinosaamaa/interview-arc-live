#!/bin/zsh

set -euo pipefail

opt_in="${INTERVIEW_ARC_LIVE_RUN_ENDPOINT_SMOKE:-0}"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 ['/installed/path/Interview Arc Live.app'] '/path/to/InterviewArcLive.package-manifest.txt'" >&2
  exit 64
fi
if [[ "$opt_in" != "1" ]]; then
  echo "Installed endpoint smoke is opt-in." >&2
  echo "Set INTERVIEW_ARC_LIVE_RUN_ENDPOINT_SMOKE=1 to run one Groq classification request." >&2
  exit 64
fi

source "${0:A:h}/installed-smoke-common.zsh"
interview_arc_live_run_installed_smoke \
  "InterviewArcLiveEndpointSmoke" \
  "interview-arc-live-endpoint-smoke" \
  "$@"
