#!/usr/bin/env python3
import json
import re
import subprocess
import sys
from pathlib import Path

CLASSIFICATIONS = {
    "none": "none",
    "change note": "change-note",
    "adr": "adr",
    "architecture review": "architecture-review",
    "feature retrospective": "feature-retrospective",
    "postmortem": "postmortem",
    "capability dossier": "capability-dossier",
}

PLACEHOLDER_REASONS = {
    "todo",
    "n/a",
    "na",
    "none",
    "replace with a concrete reason",
}


def selected_classifications(body: str):
    pattern = re.compile(
        r"^\s*-\s*\[[xX]\]\s*(None|Change Note|ADR|Architecture Review|Feature Retrospective|Postmortem|Capability Dossier)(?:\s*[—-]\s*reason:\s*(.*))?\s*$",
        re.IGNORECASE,
    )
    return [
        (CLASSIFICATIONS[match.group(1).lower()], (match.group(2) or "").strip())
        for line in body.splitlines()
        if (match := pattern.match(line))
    ]


def validate(body: str, record_types: list[str]):
    selected = selected_classifications(body)
    if len(selected) != 1:
        raise ValueError("Select exactly one Engineering impact classification in the pull request body.")
    classification, reason = selected[0]
    if classification == "none":
        normalized_reason = re.sub(r"[.!]+$", "", reason.strip()).lower()
        if len(reason) < 12 or normalized_reason in PLACEHOLDER_REASONS:
            raise ValueError("Engineering impact `None` requires a concrete reason.")
        if record_types:
            raise ValueError("A canonical Engineering record changed, so Engineering impact cannot be `None`.")
        return classification
    unique_types = sorted(set(record_types))
    if not unique_types:
        raise ValueError(f"Engineering impact `{classification}` requires a matching canonical record.")
    if unique_types != [classification]:
        raise ValueError(f"Engineering impact `{classification}` does not match record type(s): {', '.join(unique_types)}.")
    return classification


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def record_types(paths: list[str], head: str, base: str):
    found: dict[str, str] = {}
    for revision in (head, base):
        pending = [path for path in paths if path not in found]
        if not pending:
            break
        result = subprocess.run(
            ["git", "grep", "-E", r"^type:[[:space:]]*[^[:space:]]+", revision, "--", *pending],
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode not in (0, 1):
            raise subprocess.CalledProcessError(result.returncode, result.args, result.stdout, result.stderr)
        prefix = f"{revision}:"
        for line in result.stdout.splitlines():
            if not line.startswith(prefix) or ":type:" not in line:
                continue
            path, value = line[len(prefix):].rsplit(":type:", 1)
            if path in pending and path not in found:
                found[path] = value.strip()
    missing = [path for path in paths if path not in found]
    if missing:
        raise ValueError(f"Changed canonical Engineering record has no type: {missing[0]}.")
    return [found[path] for path in paths]


def main():
    event_path = Path(sys.argv[1] if len(sys.argv) > 1 else "")
    if not event_path.is_file():
        raise ValueError("A pull-request event path is required.")
    event = json.loads(event_path.read_text(encoding="utf-8"))
    pull_request = event.get("pull_request", {})
    base = pull_request.get("base", {}).get("sha")
    head = pull_request.get("head", {}).get("sha")
    if not base or not head:
        raise ValueError("Pull request base and head revisions are required.")
    changed = git("diff", "--name-only", base, head).splitlines()
    record_paths = [path for path in changed if path.startswith("docs/engineering/records/") and path.endswith(".md")]
    classification = validate(pull_request.get("body") or "", record_types(record_paths, head, base))
    print(f"Engineering impact: {classification}; {len(changed)} changed file(s).")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)
