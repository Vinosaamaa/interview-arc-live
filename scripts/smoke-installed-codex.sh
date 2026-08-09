#!/bin/zsh

set -euo pipefail

opt_in="${INTERVIEW_ARC_LIVE_RUN_CODEX_SMOKE:-0}"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 ['/installed/path/Interview Arc Live.app'] '/path/to/InterviewArcLive.package-manifest.txt'" >&2
  exit 64
fi
if [[ "$opt_in" != "1" ]]; then
  echo "Installed Codex smoke is opt-in." >&2
  echo "Set INTERVIEW_ARC_LIVE_RUN_CODEX_SMOKE=1 to run one authenticated interviewer request." >&2
  exit 64
fi

source "${0:A:h}/installed-smoke-common.zsh"
interview_arc_live_run_installed_smoke \
  "InterviewArcLiveCodexSmoke" \
  "interview-arc-live-codex-smoke" \
  "$@"
