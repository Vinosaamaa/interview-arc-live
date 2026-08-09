# interview-arc-live
Experimental native macOS technical mock-interview client for Interview Arc

Current product design: [specialty room concepts](docs/design/specialty-rooms.md).

## Current implementation

The first vertical slice establishes a standalone Swift package and a locally
durable system-design session tracer bullet. Product decisions live in
[issue #1](https://github.com/Vinosaamaa/interview-arc-live/issues/1); the
foundation is tracked by
[issue #3](https://github.com/Vinosaamaa/interview-arc-live/issues/3).

Requirements: macOS 14 or newer and Swift 6.1 or newer.

```bash
swift test
swift run InterviewArcLive
```

The preview keeps its Session Manifest and source recordings under Live's local
Application Support root. Manual Hand off joins selected Groq transcripts and
uses the exactly preflighted, locally authenticated Codex App Server for one
canonical interviewer response. TTS, automatic endpointing, the functional
system-design board, and hosted Interview Arc state remain later slices.

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
