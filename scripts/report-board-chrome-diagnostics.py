#!/usr/bin/env python3
"""Summarize and gate Interview Arc's environment-gated Board chrome trace."""

from __future__ import annotations

import json
import pathlib
import sys
from collections import Counter

GEOMETRY_FIELDS = {
    "top menu x": ("topMenu", "x"),
    "top menu width": ("topMenu", "width"),
    "top toolbar x": ("topToolbar", "x"),
    "top toolbar width": ("topToolbar", "width"),
    "bottom controls x": ("bottomLeft", "x"),
    "bottom controls y": ("bottomLeft", "y"),
    "bottom controls width": ("bottomLeft", "width"),
    "viewport width": ("viewport", "width"),
    "viewport height": ("viewport", "height"),
}


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: report-board-chrome-diagnostics.py TRACE.ndjson", file=sys.stderr)
        return 64

    path = pathlib.Path(sys.argv[1])
    bounds = {
        label: [float("inf"), float("-inf"), 0]
        for label in GEOMETRY_FIELDS
    }
    controls: Counter[tuple[object, object]] = Counter()
    lifecycle = Counter()
    failures: list[str] = []
    interaction_frames = 0
    try:
        with path.open(encoding="utf-8") as trace:
            for line_number, line in enumerate(trace, start=1):
                if not line.strip():
                    continue
                row = json.loads(line)
                kind = row.get("kind")
                lifecycle[kind] += 1
                if kind == "editor-failure-callback":
                    failures.append(
                        f"editor failure: {row.get('message', 'unknown')}"
                    )
                diagnostic_kind = row.get("diagnosticKind")
                if diagnostic_kind == "control-transition":
                    controls[
                        (
                            row.get("previous", {}).get("revisionStatus"),
                            row.get("next", {}).get("revisionStatus"),
                        )
                    ] += 1
                if diagnostic_kind != "interaction-frame":
                    continue
                interaction_frames += 1
                for label, (key, field) in GEOMETRY_FIELDS.items():
                    container = row.get(key)
                    if not isinstance(container, dict) or field not in container:
                        failures.append(
                            f"{label}: missing from interaction frame at line {line_number}"
                        )
                        continue
                    value = float(container[field])
                    current = bounds[label]
                    current[0] = min(current[0], value)
                    current[1] = max(current[1], value)
                    current[2] += 1
    except (OSError, json.JSONDecodeError, TypeError, ValueError) as error:
        print(f"trace error: {error}", file=sys.stderr)
        return 65

    if interaction_frames == 0:
        print("HOLD: trace contains no interaction frames")
        return 1

    for label, (minimum, maximum, count) in bounds.items():
        if count != interaction_frames:
            continue
        delta = maximum - minimum
        print(f"{label}: {minimum:.2f}…{maximum:.2f} (Δ {delta:.2f})")
        if delta > 0.5:
            failures.append(f"{label}: Δ {delta:.2f}")

    print(f"interaction frames: {interaction_frames}")
    print(f"control transitions: {sum(controls.values())}")
    for (previous, next_value), count in controls.most_common(6):
        print(f"  {previous!r} → {next_value!r}: {count}")
    print(
        "representable lifecycle: "
        f"created={lifecycle['representable-created-webview']} "
        f"reused={lifecycle['representable-reused-webview']} "
        f"dismantled={lifecycle['representable-dismantle']}"
    )

    if failures:
        print("HOLD: " + "; ".join(failures))
        return 1
    print("GO: Board chrome geometry stayed stable for the recorded interaction")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
