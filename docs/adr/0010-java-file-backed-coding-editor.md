# ADR 0010: Java file-backed coding editor

- Status: Accepted
- Date: 2026-08-17
- Issue: [#69](https://github.com/Vinosaamaa/interview-arc-live/issues/69)

## Context

The LeetCode specialist already treats one evolving Java file as the attempt,
starts the timer only after that file is ready, runs `scripts/leetcode-java-harness.mjs`
for local verification, and submits only through the checked-in Playwright
controller. Live's coding room must preserve those boundaries instead of
inventing a second IDE or a fake in-app judge.

## Decision

- The coding work surface is a native macOS editor over that one Java file
  (NSTextView with highlighting for this slice). It is not Monaco, not a
  LeetCode clone, and not a terminal nvim pane hosted as the room.
- Java 21 is the only enabled language. Python stays visible and disabled
  until source, harness, and preflight contracts exist.
- If Application Support `WorkspaceLink.json` names an Interview Arc checkout,
  Live edits `practice/leetcode/solutions/<number>-<slug>.java`. Otherwise it
  keeps a Live-owned copy under `CodingSources/<activityId>/`.
- `Quick run` / `Full run` invoke the repository harness when published and
  may report only **Locally verified**. `Accepted` requires a real LeetCode
  verdict. Submit is absent from the room.
- `Open LeetCode` uses the checked-in controller and the dedicated
  `leetcode-submitter` profile. Live never copies that profile.
- The hosted timer starts only after the Java file is loaded. Missing coding
  activity is a truthful gate: Hand off stays available, Start/Set result do
  not. Hand off records `.noBoard`.

## Consequences

Coding is a parallel specialty projection of the same interview session. The
System Design Board, its open PRs, and default hosted `open()` stay unchanged.
Hosted LeetCode bind also requires Interview Arc `/live/v1` to serve LeetCode
activities ([interview-arc#388](https://github.com/Vinosaamaa/interview-arc/issues/388)).
