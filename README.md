# interview-arc-live
Experimental native macOS technical mock-interview client for Interview Arc.

Current product design: [specialty room concepts](docs/design/specialty-rooms.md).

The System Design room can connect to Interview Arc's authoritative `/live/v1`
practice state using a separate personal integration token. Today, question,
timer, result, canonical turn pairs, writer leases, finish, and finish-next are
hosted projections; recordings, provider credentials, local speech, and Board
artifacts remain private to this Mac. See
[ADR 0009](docs/adr/0009-authoritative-hosted-practice-session.md).

## Current implementation

Interview Arc Live is a standalone Swift package with a locally durable
system-design room. One process-owned room model is retained across its full
window and nonactivating compact controls. New sessions default to Continuous
Conversation: local VAD starts and finalizes Segments, semantic endpointing and
Endpoint Grace can complete the canonical Hand off, and Hold floor / Send answer
keeps a long answer from being interrupted. Patient Auto, Manual, and Cue Only
remain compatibility modes. It records and recovers candidate segments,
transcribes through Groq, obtains canonical written interviewer turns through the
locally authenticated Codex App Server, and can explicitly generate or replay a
private local interviewer voice. Its full System Design room follows the checked-in issue #1
hierarchy and includes a functional Board with editable boxes, connectors,
labels, freehand annotations, undo/redo, zoom, immutable revisions, exact Turn
attachments, and private deterministic Draw.io/SVG/PNG exports. Its enhanced
canvas is a locally bundled, network-blocked Excalidraw Adapter; the bounded
native Board Document remains the only canonical source, and the native canvas
remains the recovery fallback. Product
decisions live in
[issue #1](https://github.com/Vinosaamaa/interview-arc-live/issues/1); the
foundation is tracked by
[issue #3](https://github.com/Vinosaamaa/interview-arc-live/issues/3), and the
local speech slice by
[issue #13](https://github.com/Vinosaamaa/interview-arc-live/issues/13).

Requirements: macOS 14 or newer, Swift 6.2, full Xcode with its Metal
toolchain, and the committed `Package.resolved` dependency graph. The verified
lane currently selects Xcode 26.3. MLX compiles and loads a bundled Metal
library, so plain `swift test` is not release evidence for this package.

```bash
xcodebuild -downloadComponent MetalToolchain
swift package resolve

export INTERVIEW_ARC_LIVE_DERIVED_DATA_PATH="$PWD/.build/xcode-derived-data"
xcodebuild build-for-testing \
  -scheme InterviewArcLive-Package \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$INTERVIEW_ARC_LIVE_DERIVED_DATA_PATH" \
  MACOSX_DEPLOYMENT_TARGET=14.0 \
  CODE_SIGNING_ALLOWED=NO
xcodebuild test-without-building \
  -scheme InterviewArcLive-Package \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$INTERVIEW_ARC_LIVE_DERIVED_DATA_PATH" \
  -parallel-testing-enabled NO \
  MACOSX_DEPLOYMENT_TARGET=14.0 \
  CODE_SIGNING_ALLOWED=NO
```

Board persistence and export use the Reliability lane: run the focused Board,
Session Manifest, recovery, deterministic-rendering, and presentation tests in
that Xcode lane. After an authorized merge, package and sign exact `main`, then
verify the staged and installed artifacts with the public-safe headed Board
save/attach/export/relaunch recovery smoke from issue #17.

When changing the enhanced Board editor, rebuild the checked-in local assets
from the exact lockfile. The bundle command replaces only the generated Board
editor resource directory; it does not change the canonical Board model or
contact a hosted canvas at runtime.

```bash
cd Web/BoardEditor
npm ci --ignore-scripts
npm audit
npm run bundle
```

The preview keeps its Session Manifest and source recordings under Live's local
Application Support root. Manual Hand off joins selected Groq transcripts and
uses the locally authenticated Codex App Server for one canonical interviewer
response. Compatibility is checked through the actual protocol, without a CLI
version gate. Continuous Conversation and Patient Auto classify
the accumulated answer after a newly completed Segment and, for a durable
`likely_end`, start one durable four-second Endpoint Grace before the same
canonical Hand off unless a Floor Hold is active. Keep my floor, Hold floor,
resumed recording, Board or Notes activity, and a Turn Mode change cancel that
grace. Local acoustic segmentation starts and finalizes Segments without Record /
Stop on the Continuous Conversation happy path.

Interviewer speech is optional and never runs for historical turns
automatically. The app discloses and downloads only the pinned
`mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit` revision shown in the UI
(1.838 GiB, Apache-2.0) after explicit authorization and a 4 GiB free-space
check. The model lives under Live's Application Support model directory; after
installation, synthesis and WAV playback stay on the Mac. Written transcript
use does not depend on speech availability.

## Opt-in installed Codex smoke

After packaging and installing an issue-#9 build, one explicit smoke can verify
the exact installed helper against the locally authenticated Codex App Server:

```bash
INTERVIEW_ARC_LIVE_RUN_CODEX_SMOKE=1 \
  scripts/smoke-installed-codex.sh \
  dist/InterviewArcLive.package-manifest.txt
```

The smoke sends one public-safe synthetic interviewer exchange. It runs from a
temporary non-repository working directory, prints no response body or account
details, and is never part of the default test or application startup path. It
requires the retained manifest from the exact installed package and verifies
the outer code-directory hash plus application, helper, and metadata hashes
before using local Codex authentication.

## Opt-in installed local-speech smoke

After packaging and installing the exact build, a separate explicit smoke can
verify model readiness, synthesize one fixed public test phrase, stream and
play its private temporary WAV, exercise Stop, and remove only its isolated
temporary audio:

```bash
INTERVIEW_ARC_LIVE_RUN_SPEECH_SMOKE=1 \
  scripts/smoke-installed-speech.sh \
  dist/InterviewArcLive.package-manifest.txt
```

If the pinned model is not already installed, the smoke still will not
download it unless the same invocation also sets
`INTERVIEW_ARC_LIVE_ALLOW_MODEL_DOWNLOAD=1`. This smoke is excluded from the
default tests and app startup. It requires the retained manifest from the
exact installed package and verifies the installed signature plus application,
helper, metadata, and MLX Metal-resource hashes before execution.

### Select a local voice

In the System Design room, open the **Mara** menu and choose **Voice engine → Qwen** or **Kokoro**. Download the selected model once when prompted. Qwen uses the existing 1.838 GiB model; Kokoro downloads 321.2 MiB including its English voice and pronunciation files. Both run locally without per-use speech fees. Switching stops current speech and keeps saved audio available; the choice survives relaunch. Removing one model leaves the other model and interview recordings intact.

The AI interviewer provider is separate from the voice engine. Codex is currently implemented, without a CLI version gate; Pi, Cursor subscription, and other provider adapters are roadmap work.

Debug builds support isolated room verification: set `INTERVIEW_ARC_LIVE_DIAGNOSTIC_STATE_ROOT` to a fresh directory beginning with `/private/tmp/interview-arc-live-ui-smoke-` and set `INTERVIEW_ARC_LIVE_DIAGNOSTIC_LOCAL_ROOM=1`. This uses separate local session state and preferences without opening a real hosted activity. Release builds omit both overrides.
