# ADR 0005: Isolate the private Codex App Server interviewer Adapter

Status: Accepted

## Context

The private prototype should use the user's locally authenticated Codex
subscription without opening a terminal. Codex App Server exposes the needed
documented thread and turn protocol, but the interface remains experimental
and its generated schemas are specific to each Codex version. A model process
also emits working, reasoning, tool, approval, and lifecycle events that are
not practice transcript content.

## Decision

`CodexAppServerInterviewerRuntime` is a provider Adapter behind the existing
`InterviewerRuntime` Interface. It uses the installed Codex CLI without a
version allowlist. Readiness checks the App Server initialization and ChatGPT
authentication responses; each turn validates the actual protocol and canonical
output. It creates a Live-owned ephemeral thread and runs with
read-only/no-approval permissions. The process disables configured MCP
servers, apps, plugins, hooks, shell execution, and other tool surfaces; any
unexpected server request or tool item fails the turn closed. It never
attaches an arbitrary terminal thread.

The Adapter receives one durable `InterviewerRequest` containing the Activity
Prompt, optional Candidate Turn, and bounded visible history. A nil Candidate
Turn is the session Opening Turn: prompt plus empty history, encoded as
`kind: opening`. Reply turns still send the exact Candidate Turn as
`kind: reply`. It constrains the final assistant output to one strict object
containing nonempty `displayMarkdown` and `spokenText`. Only that canonical
pair crosses the Interface. All working, reasoning, tool, approval, and
process events remain transient diagnostics.

The private runtime uses the user's authenticated Codex home. Current Codex
can still contribute home-level user instructions even when project discovery
is disabled, so Live supplies explicit base and developer instructions and
does not treat `instructionSources` metadata as transcript content. Strict
output validation and tool isolation are the correctness boundary; a future
hosted runtime removes this personal-configuration dependency.

The Interview Room Session persists `interviewerProcessing` before invoking
the Adapter and persists the canonical Interviewer Turn before publishing it.
Failure never replays automatically. A user retry has a fresh Command identity
while retaining the intended Interviewer identity. Reply retries also retain
the Candidate Turn; Opening retries have no Candidate Turn.

## Provider boundary

The Core-owned `InterviewerProvider` extends `InterviewerRuntime` with a provider
name and readiness check. Provider-neutral failures, requests, and canonical
responses are the room's only runtime contract. The app selects its initial
Codex adapter in `LiveInterviewerProviders`; room models never construct or
import a Codex adapter. Speech generation remains independently replaceable.

Pi, Cursor subscription access, and other providers are planned adapters, not
implemented integrations. Each must establish its supported authentication and
invocation path and satisfy the same turn, cancellation, and recovery contract.
Adding one must not require rewriting the Board, Session Manifest, or speech
coordinator, and must not silently change the account or billing mode.

## Consequences

Experimental protocol churn is local to one Adapter and fixture suite. A
missing or unauthenticated Codex installation, failed protocol exchange, or
invalid response preserves the Candidate Turn and exposes an explicit retry.
A CLI version change alone never disables the interviewer. This private
transport is not the commercial product contract; a hosted runtime may replace it without changing
the Interview Room Session Interface.

## References

- [Codex App Server guide](https://learn.chatgpt.com/docs/app-server)
- [Codex configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
