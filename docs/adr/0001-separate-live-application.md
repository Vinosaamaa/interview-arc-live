# ADR 0001: Keep Live a separate application

Status: Accepted

## Context

Live is an experimental spoken-interviewer product. Interview Arc Voice is an
established system-wide dictation and terminal companion with sensitive capture
and delivery state.

## Decision

Live is a separate public repository, process, Dock application, bundle
identity, Keychain service, Application Support root, preferences domain,
hotkey namespace, and microphone owner. It integrates directly with versioned
Interview Arc hosted state. It may consume explicitly exported VoiceCore
functionality at an exact revision, but it never reads Voice queues or depends
on Voice running.

## Consequences

Live can evolve without destabilizing Voice. Shared code requires an explicit
package seam and compatibility tests. Handoff between clients requires durable
turn completion and exclusive writer/microphone ownership.
