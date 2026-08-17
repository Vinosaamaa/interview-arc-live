---
schemaVersion: 1
id: change-note-groq-keychain-codex-pin
revision: 1
type: change-note
status: accepted
title: Persist Groq Keychain Saves And Pin Codex CLI
repository: interview-arc-live
capabilityIds: ["interview-room-session"]
createdAt: 2026-08-16
reconstructed: false
confidence: verified
unknowns: []
modules: ["live-groq-credential-store","codex-app-server-interviewer-runtime"]
interfaces: ["groq-credential-reading","interviewer-runtime"]
seams: ["session-to-transcription","session-to-interviewer-runtime"]
adapters: ["live-generic-password-keychain","codex-app-server"]
relatedRecords: ["capability-dossier-deep-interview-room-session@1"]
decisions: ["0005-codex-app-server-private-runtime"]
incidents: []
features: []
capabilities: ["durable-groq-keychain","exact-codex-cli-pin"]
amends: []
supersedes: []
learningRefs: []
sources: [{"label":"Issue #58","url":"https://github.com/Vinosaamaa/interview-arc-live/issues/58","kind":"issue"},{"label":"Pull request #59","url":"https://github.com/Vinosaamaa/interview-arc-live/pull/59","kind":"pull-request"}]
verification: {"state":"verified","evidenceRefs":["issue:58","pull-request:59","runtime:errSecParam-match-all"]}
visibility: public-safe
publicationEligibility: eligible
issue: 58
pr: 59
release: null
run: null
---
# Persist Groq Keychain Saves And Pin Codex CLI

Live could not persist a Groq key on an empty Keychain item, and Codex preflight rejected the currently authenticated CLI.

## Change

`LiveGroqCredentialStore` no longer reads through Voice `KeychainStore`. Voice's generic-password helper issues a `MatchLimitAll` plus `kSecReturnData` search after a `MatchLimitOne` miss. On current macOS that second query returns `errSecParam`, which Live mapped to `keychainUnavailable`, so the first Save to Keychain never ran. Groq now uses a Live-owned `MatchLimitOne` backend with `errSecItemNotFound` as missing, matching the hosted integration token store, while until-quit stays process-memory only.

The Codex App Server interviewer Adapter still pins one exact tested protocol. The pin is now `codex-cli 0.148.0-alpha.9`. A different version remains fail-closed and does not consume the Candidate Turn.
