#!/usr/bin/env python3
import json
import re
import subprocess
import sys
from io import BytesIO
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

CLASSIFICATION_PATTERN = re.compile(
    rf"^\s*-\s*\[[xX]\]\s*({'|'.join(re.escape(label) for label in CLASSIFICATIONS)})(?:\s*[—-]\s*reason:\s*(.*))?\s*$",
    re.IGNORECASE,
)


def selected_classifications(body: str):
    return [
        (CLASSIFICATIONS[match.group(1).lower()], (match.group(2) or "").strip())
        for line in body.splitlines()
        if (match := CLASSIFICATION_PATTERN.match(line))
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


def git_blobs(revision: str, paths: list[str]):
    if not paths:
        return {}
    result = subprocess.run(
        ["git", "cat-file", "--batch"],
        input="".join(f"{revision}:{path}\n" for path in paths).encode(),
        capture_output=True,
        check=True,
    )
    stream = BytesIO(result.stdout)
    blobs: dict[str, str | None] = {}
    for path in paths:
        header = stream.readline().decode("utf-8", errors="strict").rstrip("\n")
        if header.endswith(" missing"):
            blobs[path] = None
            continue
        parts = header.split()
        if len(parts) != 3 or parts[1] != "blob":
            raise ValueError("Unable to read a canonical Engineering record Git object.")
        content = stream.read(int(parts[2]))
        if stream.read(1) != b"\n":
            raise ValueError("Unable to read a canonical Engineering record Git object.")
        blobs[path] = content.decode("utf-8", errors="strict")
    return blobs


def record_type_from_markdown(markdown: str, path: str):
    frontmatter = re.match(r"\A---\r?\n(.*?)\r?\n---(?:\r?\n|\Z)", markdown, re.DOTALL)
    matches = re.findall(r"^type:\s*([a-z][a-z-]*)\s*$", frontmatter.group(1), re.MULTILINE) if frontmatter else []
    if len(matches) != 1:
        raise ValueError(f"Changed canonical Engineering record has no single valid type in leading front matter: {path}.")
    return matches[0]


def record_types(paths: list[str], head: str, base: str):
    head_blobs = git_blobs(head, paths)
    deleted = [path for path in paths if head_blobs[path] is None]
    base_blobs = git_blobs(base, deleted)
    types = []
    for path in paths:
        markdown = head_blobs[path] if head_blobs[path] is not None else base_blobs.get(path)
        if markdown is None:
            raise ValueError(f"Changed canonical Engineering record is missing from both revisions: {path}.")
        types.append(record_type_from_markdown(markdown, path))
    return types


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
