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

The preview uses fixture interviewer output and local Application Support
storage. It does not claim microphone, Groq, Codex, TTS, or Interview Arc
hosted-state integration until those slices are implemented and verified.
