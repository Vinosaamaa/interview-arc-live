#!/usr/bin/env python3
"""Summarize and gate Interview Arc's environment-gated Board chrome trace."""

from __future__ import annotations

import json
import pathlib
import sys
from collections import Counter


def span(rows: list[dict], key: str, field: str) -> tuple[float, float] | None:
    values = [
        float(row[key][field])
        for row in rows
        if isinstance(row.get(key), dict) and field in row[key]
    ]
    return (min(values), max(values)) if values else None


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: report-board-chrome-diagnostics.py TRACE.ndjson", file=sys.stderr)
        return 64

    path = pathlib.Path(sys.argv[1])
    try:
        rows = [
            json.loads(line)
            for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        ]
    except (OSError, json.JSONDecodeError) as error:
        print(f"trace error: {error}", file=sys.stderr)
        return 65

    frames = [
        row for row in rows
        if row.get("diagnosticKind") == "interaction-frame"
    ]
    if not frames:
        print("HOLD: trace contains no interaction frames")
        return 1

    checks = {
        "top menu x": span(frames, "topMenu", "x"),
        "top menu width": span(frames, "topMenu", "width"),
        "top toolbar x": span(frames, "topToolbar", "x"),
        "top toolbar width": span(frames, "topToolbar", "width"),
        "bottom controls x": span(frames, "bottomLeft", "x"),
        "bottom controls y": span(frames, "bottomLeft", "y"),
        "bottom controls width": span(frames, "bottomLeft", "width"),
        "viewport width": span(frames, "viewport", "width"),
        "viewport height": span(frames, "viewport", "height"),
    }
    failures: list[str] = []
    for label, bounds in checks.items():
        if bounds is None:
            failures.append(f"{label}: missing")
            continue
        minimum, maximum = bounds
        delta = maximum - minimum
        print(f"{label}: {minimum:.2f}…{maximum:.2f} (Δ {delta:.2f})")
        if delta > 0.5:
            failures.append(f"{label}: Δ {delta:.2f}")

    controls = Counter(
        (
            row.get("previous", {}).get("revisionStatus"),
            row.get("next", {}).get("revisionStatus"),
        )
        for row in rows
        if row.get("diagnosticKind") == "control-transition"
    )
    failures.extend(
        f"editor failure: {row.get('message', 'unknown')}"
        for row in rows
        if row.get("kind") == "editor-failure-callback"
    )
    print(f"interaction frames: {len(frames)}")
    print(f"control transitions: {sum(controls.values())}")
    for (previous, next_value), count in controls.most_common(6):
        print(f"  {previous!r} → {next_value!r}: {count}")
    print(
        "representable lifecycle: "
        f"created={sum(row.get('kind') == 'representable-created-webview' for row in rows)} "
        f"reused={sum(row.get('kind') == 'representable-reused-webview' for row in rows)} "
        f"dismantled={sum(row.get('kind') == 'representable-dismantle' for row in rows)}"
    )

    if failures:
        print("HOLD: " + "; ".join(failures))
        return 1
    print("GO: Board chrome geometry stayed stable for the recorded interaction")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
