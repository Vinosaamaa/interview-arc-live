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

RECEIPT_DIRECTORY = "docs/engineering/changes/"
RECEIPT_SCHEMA_PATH = Path(__file__).parents[1] / "docs" / "contracts" / "engineering-pull-request-receipt.schema.json"
RECEIPT_SCHEMA = json.loads(RECEIPT_SCHEMA_PATH.read_text(encoding="utf-8"))
RECEIPT_FIELDS = frozenset(RECEIPT_SCHEMA["required"])
RECEIPT_PROPERTIES = RECEIPT_SCHEMA["properties"]
RECEIPT_DEFINITIONS = RECEIPT_SCHEMA["$defs"]
RECEIPT_CLASSIFICATIONS = frozenset(RECEIPT_PROPERTIES["classification"]["enum"])
SOURCE_KINDS = {"issue", "pull-request", "commit", "release", "run", "documentation"}
CONFIDENCE_VALUES = {"verified", "high", "medium", "low", "unknown"}
RECORD_REF_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*@[1-9]\d*$")
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
MERGED_AT_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
REPOSITORY_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+$")
MAX_SOURCES = RECEIPT_PROPERTIES["sources"]["maxItems"]
MAX_SOURCE_LABEL_LENGTH = RECEIPT_PROPERTIES["sources"]["items"]["properties"]["label"]["maxLength"]
MAX_SOURCE_URL_LENGTH = RECEIPT_PROPERTIES["sources"]["items"]["properties"]["url"]["maxLength"]
MAX_STRING_LIST_ITEMS = RECEIPT_DEFINITIONS["stringList"]["maxItems"]
MAX_STRING_LENGTH = RECEIPT_DEFINITIONS["stringList"]["items"]["maxLength"]
MAX_RECORD_REFS = RECEIPT_DEFINITIONS["recordRefs"]["maxItems"]
MAX_RECORD_REF_LENGTH = RECEIPT_DEFINITIONS["recordRefs"]["items"]["maxLength"]
MAX_FRONTMATTER_BYTES = 65_536
MAX_BATCH_RECORDS = 64
FRONTMATTER_BYTES_PATTERN = re.compile(rb"\A---\r?\n.*?\r?\n---(?:\r?\n|\Z)", re.DOTALL)


def markdown_lines_outside_fences(body: str):
    fence = None
    for line in body.splitlines():
        marker = re.match(r"^\s*(`{3,}|~{3,})", line)
        if fence:
            if marker and marker.group(1)[0] == fence[0] and len(marker.group(1)) >= fence[1]:
                fence = None
            continue
        if marker:
            fence = (marker.group(1)[0], len(marker.group(1)))
            continue
        yield line


def selected_classifications(body: str):
    return [
        (CLASSIFICATIONS[match.group(1).lower()], (match.group(2) or "").strip())
        for line in markdown_lines_outside_fences(body)
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
    if unique_types and unique_types != [classification]:
        raise ValueError(f"Engineering impact `{classification}` does not match record type(s): {', '.join(unique_types)}.")
    return classification


def frontmatter_document(markdown: str, path: str):
    match = re.match(r"\A---\r?\n(.*?)\r?\n---(?:\r?\n|\Z)(.*)\Z", markdown, re.DOTALL)
    if not match:
        raise ValueError(f"Engineering document has no leading front matter: {path}.")
    values = {}
    for line in match.group(1).splitlines():
        if not line.strip():
            continue
        if ":" not in line:
            raise ValueError(f"Engineering document has invalid front matter: {path}.")
        key, raw_value = line.split(":", 1)
        key = key.strip()
        raw_value = raw_value.strip()
        if not key or key in values or not raw_value:
            raise ValueError(f"Engineering document has invalid front matter: {path}.")
        if raw_value.startswith(("'", "|", ">", "&", "*", "!")):
            raise ValueError(
                f"Engineering document front matter uses unsupported YAML-only syntax; "
                f"use one key per line with JSON-compatible structured values: {path}."
            )
        if raw_value[0] in '[{"' or raw_value in {"true", "false", "null"} or re.fullmatch(r"-?\d+", raw_value):
            try:
                values[key] = json.loads(raw_value)
            except json.JSONDecodeError as error:
                raise ValueError(f"Engineering document has invalid JSON-compatible front matter: {path}.") from error
        else:
            values[key] = raw_value
    return values, match.group(2).strip()


def string_list(
    value,
    field: str,
    path: str,
    *,
    max_items: int = MAX_STRING_LIST_ITEMS,
    max_length: int = MAX_STRING_LENGTH,
):
    if not isinstance(value, list) or any(not isinstance(item, str) or not item for item in value):
        raise ValueError(f"Receipt `{field}` must be a list of nonempty strings: {path}.")
    if len(value) > max_items or any(len(item) > max_length for item in value):
        raise ValueError(
            f"Receipt `{field}` must contain at most {max_items} items of at most {max_length} characters: {path}."
        )
    if len(value) != len(set(value)):
        raise ValueError(f"Receipt `{field}` must not contain duplicates: {path}.")
    return value


def required_receipt_path(changed_files: list[str], pr_number: int):
    expected = f"{RECEIPT_DIRECTORY}pr-{pr_number}.md"
    receipt_paths = [
        path for path in changed_files
        if path.startswith(RECEIPT_DIRECTORY) and path.endswith(".md")
    ]
    if receipt_paths != [expected]:
        raise ValueError(f"Every pull request must change exactly one receipt at `{expected}`.")
    return expected


def validate_receipt_fields(receipt, path, *, repository, pr_number, pr_title, classification):
    missing = sorted(RECEIPT_FIELDS - receipt.keys())
    extra = sorted(receipt.keys() - RECEIPT_FIELDS)
    if missing or extra:
        detail = []
        if missing:
            detail.append(f"missing {', '.join(missing)}")
        if extra:
            detail.append(f"unknown {', '.join(extra)}")
        raise ValueError(f"Receipt v1 fields are invalid ({'; '.join(detail)}): {path}.")

    if type(receipt["schemaVersion"]) is not int or receipt["schemaVersion"] != 1:
        raise ValueError(f"Receipt `schemaVersion` must be 1: {path}.")
    if not isinstance(receipt["repository"], str) or not REPOSITORY_PATTERN.fullmatch(receipt["repository"]):
        raise ValueError(f"Receipt `repository` is invalid: {path}.")
    if receipt["repository"] != repository:
        raise ValueError(f"Receipt `repository` must be `{repository}`: {path}.")
    if type(receipt["pr"]) is not int or receipt["pr"] != pr_number:
        raise ValueError(f"Receipt `pr` must be {pr_number}: {path}.")
    if not isinstance(receipt["title"], str) or not 1 <= len(receipt["title"]) <= 160:
        raise ValueError(f"Receipt `title` must contain 1–160 characters: {path}.")
    if receipt["title"] != pr_title:
        raise ValueError(f"Receipt `title` must match the pull request title: {path}.")
    if receipt["classification"] not in RECEIPT_CLASSIFICATIONS:
        raise ValueError(f"Receipt `classification` is invalid: {path}.")
    if receipt["classification"] != classification:
        raise ValueError(f"Receipt `classification` must match Engineering impact `{classification}`: {path}.")
    if receipt["reconstructed"] is not False:
        raise ValueError(f"A forward pull-request receipt must set `reconstructed` to false: {path}.")
    if receipt["confidence"] not in CONFIDENCE_VALUES:
        raise ValueError(f"Receipt `confidence` is invalid: {path}.")
    string_list(receipt["unknowns"], "unknowns", path)


def validate_receipt_record_refs(receipt, path, *, classification, record_index):

    rich_record_refs = string_list(
        receipt["richRecordRefs"],
        "richRecordRefs",
        path,
        max_items=MAX_RECORD_REFS,
        max_length=MAX_RECORD_REF_LENGTH,
    )
    if any(not RECORD_REF_PATTERN.fullmatch(reference) for reference in rich_record_refs):
        raise ValueError(f"Receipt `richRecordRefs` contains an invalid exact record reference: {path}.")
    if classification == "none" and rich_record_refs:
        raise ValueError(f"A `none` receipt cannot link a rich record: {path}.")
    if classification != "none" and not rich_record_refs:
        raise ValueError(f"A material receipt requires at least one exact rich record reference: {path}.")
    for reference in rich_record_refs:
        if reference not in record_index:
            raise ValueError(f"Receipt rich record reference `{reference}` does not resolve at the pull-request head: {path}.")
        if record_index[reference] != classification:
            raise ValueError(f"Receipt rich record reference `{reference}` does not have the matching type `{classification}`: {path}.")

    for field in ("headCommit", "mergeCommit"):
        value = receipt[field]
        if value is not None and (not isinstance(value, str) or not COMMIT_PATTERN.fullmatch(value)):
            raise ValueError(f"Receipt `{field}` must be null or a 40-character lowercase commit: {path}.")
    merged_at = receipt["mergedAt"]
    if merged_at is not None and (not isinstance(merged_at, str) or not MERGED_AT_PATTERN.fullmatch(merged_at)):
        raise ValueError(f"Receipt `mergedAt` must be null or a UTC timestamp without fractional seconds: {path}.")


def validate_receipt_sources(receipt, path, *, repository, pr_number, pr_url):
    sources = receipt["sources"]
    if not isinstance(sources, list) or not sources:
        raise ValueError(f"Receipt `sources` must contain at least one source: {path}.")
    if len(sources) > MAX_SOURCES:
        raise ValueError(f"Receipt `sources` must contain at most {MAX_SOURCES} sources: {path}.")
    for source in sources:
        if not isinstance(source, dict) or set(source) != {"label", "url", "kind"}:
            raise ValueError(f"Receipt source fields are invalid: {path}.")
        if not isinstance(source["label"], str) or not 1 <= len(source["label"]) <= MAX_SOURCE_LABEL_LENGTH:
            raise ValueError(f"Receipt source label is invalid: {path}.")
        if (
            not isinstance(source["url"], str)
            or not source["url"].startswith("https://")
            or len(source["url"]) > MAX_SOURCE_URL_LENGTH
        ):
            raise ValueError(
                f"Receipt source URL must use HTTPS and contain at most {MAX_SOURCE_URL_LENGTH} characters: {path}."
            )
        if source["kind"] not in SOURCE_KINDS:
            raise ValueError(f"Receipt source kind is invalid: {path}.")
    expected_pr_url = pr_url or f"https://github.com/Vinosaamaa/{repository}/pull/{pr_number}"
    if not any(source["kind"] == "pull-request" and source["url"] == expected_pr_url for source in sources):
        raise ValueError(f"Receipt must cite its exact pull request URL `{expected_pr_url}`: {path}.")


def validate_receipt_verification(receipt, path):
    verification = receipt["verification"]
    if not isinstance(verification, dict) or set(verification) != {"state", "evidenceRefs"}:
        raise ValueError(f"Receipt `verification` fields are invalid: {path}.")
    if verification["state"] not in {"verified", "not-recorded"}:
        raise ValueError(f"Receipt verification state is invalid: {path}.")
    evidence_refs = string_list(verification["evidenceRefs"], "verification.evidenceRefs", path)
    known_merge_facts = any(receipt[field] is not None for field in ("headCommit", "mergeCommit", "mergedAt"))
    if known_merge_facts and (verification["state"] != "verified" or not evidence_refs):
        raise ValueError(f"Receipt commit and merge facts require verified evidence: {path}.")
    if receipt["visibility"] != "public-safe":
        raise ValueError(f"Receipt `visibility` must be `public-safe`: {path}.")
    if receipt["publicationEligibility"] != "eligible":
        raise ValueError(f"Receipt `publicationEligibility` must be `eligible`: {path}.")


def validate_receipt_body(receipt, body, path):
    paragraphs = [paragraph.strip() for paragraph in re.split(r"\r?\n\s*\r?\n", body) if paragraph.strip()]
    if len(paragraphs) != 2 or paragraphs[0] != f"# {receipt['title']}":
        raise ValueError(f"Receipt body must contain its title heading and one factual summary paragraph: {path}.")
    summary = " ".join(paragraphs[1].split())
    if not summary or len(summary) > 280:
        raise ValueError(f"Receipt summary must contain at most 280 characters: {path}.")


def validate_receipt(
    markdown: str,
    path: str,
    *,
    repository: str,
    pr_number: int,
    pr_title: str,
    classification: str,
    record_index: dict[str, str],
    pr_url: str | None = None,
):
    receipt, body = frontmatter_document(markdown, path)
    validate_receipt_fields(
        receipt,
        path,
        repository=repository,
        pr_number=pr_number,
        pr_title=pr_title,
        classification=classification,
    )
    validate_receipt_record_refs(receipt, path, classification=classification, record_index=record_index)
    validate_receipt_sources(
        receipt,
        path,
        repository=repository,
        pr_number=pr_number,
        pr_url=pr_url,
    )
    validate_receipt_verification(receipt, path)
    validate_receipt_body(receipt, body, path)

    return receipt


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
    try:
        metadata, _ = frontmatter_document(markdown, path)
    except ValueError:
        raise ValueError(
            f"Changed canonical Engineering record has no single valid type in leading front matter: {path}."
        ) from None
    record_type = metadata.get("type")
    if not isinstance(record_type, str) or not re.fullmatch(r"[a-z][a-z-]*", record_type):
        raise ValueError(f"Changed canonical Engineering record has no single valid type in leading front matter: {path}.")
    return record_type


def iter_frontmatters_at(revision: str, paths: list[str]):
    if not paths:
        return
    process = subprocess.Popen(
        ["git", "cat-file", "--batch"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    assert process.stdin is not None
    assert process.stdout is not None
    assert process.stderr is not None
    try:
        for chunk_start in range(0, len(paths), MAX_BATCH_RECORDS):
            chunk = paths[chunk_start : chunk_start + MAX_BATCH_RECORDS]
            process.stdin.write("".join(f"{revision}:{path}\n" for path in chunk).encode())
            process.stdin.flush()
            for path in chunk:
                header = process.stdout.readline().decode("utf-8", errors="strict").rstrip("\n")
                if header.endswith(" missing"):
                    raise ValueError(f"Canonical Engineering record is missing at the pull-request head: {path}.")
                parts = header.split()
                if len(parts) != 3 or parts[1] != "blob":
                    raise ValueError("Unable to read a canonical Engineering record Git object.")
                object_size = int(parts[2])
                prefix = process.stdout.read(min(object_size, MAX_FRONTMATTER_BYTES))
                remaining = object_size - len(prefix)
                while remaining:
                    discarded = process.stdout.read(min(remaining, 65_536))
                    if not discarded:
                        raise ValueError("Unable to read a canonical Engineering record Git object.")
                    remaining -= len(discarded)
                if process.stdout.read(1) != b"\n":
                    raise ValueError("Unable to read a canonical Engineering record Git object.")
                frontmatter_match = FRONTMATTER_BYTES_PATTERN.match(prefix)
                if not frontmatter_match:
                    raise ValueError(f"Canonical Engineering record has invalid or oversized front matter: {path}.")
                metadata, _ = frontmatter_document(
                    frontmatter_match.group().decode("utf-8", errors="strict"),
                    path,
                )
                yield path, metadata
    finally:
        process.stdin.close()
        process.stdout.close()
        stderr = process.stderr.read()
        process.stderr.close()
        return_code = process.wait()
    if return_code != 0:
        raise subprocess.CalledProcessError(return_code, process.args, stderr=stderr)


def record_index_and_changed_types_at(revision: str, changed_paths: list[str]):
    paths = [
        path
        for path in git(
            "ls-tree",
            "-r",
            "--name-only",
            revision,
            "--",
            "docs/engineering/records",
        ).splitlines()
        if path.endswith(".md")
    ]
    missing_changed_paths = set(changed_paths) - set(paths)
    if missing_changed_paths:
        path = sorted(missing_changed_paths)[0]
        raise ValueError(
            f"Canonical Engineering records cannot be deleted; publish a superseding record instead: {path}."
        )

    changed_path_set = set(changed_paths)
    index = {}
    changed_types = []
    for path, metadata in iter_frontmatters_at(revision, paths):
        record_id = metadata.get("id")
        record_revision = metadata.get("revision")
        record_type = metadata.get("type")
        if not isinstance(record_id, str) or not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", record_id):
            raise ValueError(f"Canonical Engineering record has an invalid id: {path}.")
        if type(record_revision) is not int or record_revision < 1:
            raise ValueError(f"Canonical Engineering record has an invalid revision: {path}.")
        if record_type not in set(CLASSIFICATIONS.values()) - {"none"}:
            raise ValueError(f"Canonical Engineering record has an invalid type: {path}.")
        reference = f"{record_id}@{record_revision}"
        if reference in index:
            raise ValueError(f"Duplicate canonical Engineering record reference: {reference}.")
        index[reference] = record_type
        if path in changed_path_set:
            changed_types.append(record_type)
    return index, changed_types


def main():
    event_path = Path(sys.argv[1] if len(sys.argv) > 1 else "")
    if not event_path.is_file():
        raise ValueError("A pull-request event path is required.")
    event = json.loads(event_path.read_text(encoding="utf-8"))
    pull_request = event.get("pull_request", {})
    base = pull_request.get("base", {}).get("sha")
    head = pull_request.get("head", {}).get("sha")
    pr_number = pull_request.get("number") or event.get("number")
    pr_title = pull_request.get("title")
    repository = event.get("repository", {}).get("name") or pull_request.get("base", {}).get("repo", {}).get("name")
    pr_url = pull_request.get("html_url")
    if not base or not head or type(pr_number) is not int or not pr_title or not repository or not pr_url:
        raise ValueError("Pull request base, head, number, title, repository, and URL are required.")
    changed = git("diff", "--name-only", base, head).splitlines()
    record_paths = [path for path in changed if path.startswith("docs/engineering/records/") and path.endswith(".md")]
    record_index, changed_record_types = record_index_and_changed_types_at(head, record_paths)
    classification = validate(pull_request.get("body") or "", changed_record_types)
    receipt_path = required_receipt_path(changed, pr_number)
    receipt_markdown = git_blobs(head, [receipt_path])[receipt_path]
    if receipt_markdown is None:
        raise ValueError(f"Pull-request receipt is missing at the pull-request head: {receipt_path}.")
    receipt = validate_receipt(
        receipt_markdown,
        receipt_path,
        repository=repository,
        pr_number=pr_number,
        pr_title=pr_title,
        classification=classification,
        record_index=record_index,
        pr_url=pr_url,
    )
    print(
        f"Engineering impact: {classification}; receipt PR #{receipt['pr']}; "
        f"{len(changed)} changed file(s)."
    )


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        print(error, file=sys.stderr)
        raise SystemExit(1)
