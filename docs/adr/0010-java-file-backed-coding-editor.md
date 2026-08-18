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
- Live does **not** call the LeetCode specialist for Quick, Full, or Submit.
  Those actions invoke `scripts/leetcode-java-harness.mjs` and
  `scripts/leetcode-playwright-controller.mjs` directly.
- After the Java file loads, Warm Controller Preflight runs in the background:
  `ensure` then `navigate` on the dedicated `browser-profiles/leetcode-submitter`
  profile. Live never copies that profile and never runs `pnpm install` on the
  click path.
- Click path: flush the one Java file → already-warm tool → result. Hand off,
  mic, and editor stay live. Do not set interview `isWorking` for run or submit.
- `Quick run` / `Full run` invoke the repository harness when published and may
  report only **Locally verified**. The latest Quick/Full click cancels the
  previous local run and streams harness stdout into the drawer. Immediate UI:
  `Quick run · running`.
- **Submit** is an explicit in-room control. It calls the checked-in controller
  `submit` / `retry` / `receipt` with a caller-chosen unique Controller
  Invocation ID. If output is lost or ambiguous, `receipt` once with that same
  ID. After a terminal verdict, the next explicit click is `retry` with a new
  ID. Never auto-retry. Never reuse an ID. Immediate UI:
  `Submitting · waiting for LeetCode`.
- **Accepted** requires a real LeetCode controller verdict. Local success is
  **Locally verified** only.
- `Open LeetCode` uses the same checked-in controller and dedicated
  `leetcode-submitter` profile.
- The hosted timer starts only after the Java file is loaded. Missing coding
  activity is a truthful gate: Hand off stays available, Start/Set result do
  not. Hand off records `.noBoard`.

## Consequences

Coding is a parallel specialty projection of the same interview session. The
System Design Board, its open PRs, and default hosted `open()` stay unchanged.
Hosted LeetCode bind also requires Interview Arc `/live/v1` to serve LeetCode
activities ([interview-arc#388](https://github.com/Vinosaamaa/interview-arc/issues/388)).

- Amendment 2026-08-17: the same-day product decision moved **Submit** into
  the coding room as In-Room Submit. Warm Controller Preflight, streaming
  local runs, unique Controller Invocation IDs, and no specialist round-trip
  are part of that amendment. Hand off stays available during run and submit.
