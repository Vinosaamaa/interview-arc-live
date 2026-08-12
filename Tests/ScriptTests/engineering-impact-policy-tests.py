#!/usr/bin/env python3
import hashlib
import importlib.util
import json
import unittest
from io import BytesIO
from pathlib import Path
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).parents[2] / "scripts" / "validate-engineering-impact.py"
WORKFLOW = Path(__file__).parents[2] / ".github" / "workflows" / "swift.yml"
PACKAGE_SCRIPT = Path(__file__).parents[2] / "scripts" / "package-app.sh"
BUILD_RECEIPT_SCRIPT = Path(__file__).parents[2] / "scripts" / "build-product-receipt.sh"
SCHEMA = Path(__file__).parents[2] / "docs" / "contracts" / "engineering-pull-request-receipt.schema.json"
CURRENT_RECEIPT = Path(__file__).parents[2] / "docs" / "engineering" / "changes" / "pr-42.md"
SPEC = importlib.util.spec_from_file_location("engineering_impact", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class EngineeringImpactPolicyTests(unittest.TestCase):
    DEFAULT_RECORD_INDEX = {
        "capability-dossier-deep-interview-room-session@1": "capability-dossier",
    }

    @staticmethod
    def workflow_mapping_block(workflow, key, indent):
        lines = workflow.splitlines()
        marker = f"{' ' * indent}{key}:"
        start = next(
            index for index, line in enumerate(lines)
            if line.rstrip() == marker
        )
        end = len(lines)
        for index in range(start + 1, len(lines)):
            line = lines[index]
            if line.strip() and len(line) - len(line.lstrip()) <= indent:
                end = index
                break
        return "\n".join(lines[start:end])

    @staticmethod
    def workflow_scalar(block, key, indent):
        prefix = f"{' ' * indent}{key}:"
        line = next(line for line in block.splitlines() if line.startswith(prefix))
        return line[len(prefix):].strip()

    @staticmethod
    def workflow_step(workflow, name):
        lines = workflow.splitlines()
        marker = f"      - name: {name}"
        start = lines.index(marker)
        end = len(lines)
        for index in range(start + 1, len(lines)):
            if lines[index].startswith("      - name:"):
                end = index
                break
        return "\n".join(lines[start:end])

    @staticmethod
    def receipt_markdown(
        *,
        classification="capability-dossier",
        rich_record_refs='["capability-dossier-deep-interview-room-session@1"]',
        repository="interview-arc-live",
        pr=42,
        title="Adopt the Engineering Journal contract",
    ):
        return f"""---
schemaVersion: 1
repository: {repository}
pr: {pr}
title: {title}
classification: {classification}
richRecordRefs: {rich_record_refs}
reconstructed: false
confidence: verified
unknowns: []
headCommit: null
mergeCommit: null
mergedAt: null
sources: [{{"label":"Pull request #{pr}","url":"https://github.com/Vinosaamaa/{repository}/pull/{pr}","kind":"pull-request"}}]
verification: {{"state":"verified","evidenceRefs":["pull-request:{pr}"]}}
visibility: public-safe
publicationEligibility: eligible
---
# {title}

Adopted complete pull-request receipts and a curated Engineering record for the Live session Module.
"""

    def validate_receipt(self, markdown=None, **overrides):
        arguments = {
            "repository": "interview-arc-live",
            "pr_number": 42,
            "pr_title": "Adopt the Engineering Journal contract",
            "classification": "capability-dossier",
            "record_index": self.DEFAULT_RECORD_INDEX,
        }
        arguments.update(overrides)
        return MODULE.validate_receipt(
            self.receipt_markdown() if markdown is None else markdown,
            "docs/engineering/changes/pr-42.md",
            **arguments,
        )

    def test_workflow_fetches_only_exact_pr_revisions_for_diff(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("fetch-depth: 0", workflow)
        self.assertIn("git fetch --no-tags --depth=1 origin \"$BASE_SHA\"", workflow)
        self.assertIn("git fetch --no-tags --depth=1 \"$HEAD_REPO_URL\" \"$HEAD_SHA\"", workflow)

    def test_workflow_revalidates_after_title_or_body_edits(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        pull_request = self.workflow_mapping_block(workflow, "pull_request", 2)
        concurrency = self.workflow_mapping_block(workflow, "concurrency", 0)
        policy_job = self.workflow_mapping_block(workflow, "engineering-policy", 2)
        native_job = self.workflow_mapping_block(workflow, "test", 2)
        self.assertEqual(
            self.workflow_scalar(pull_request, "types", 4),
            "[opened, synchronize, reopened, edited]",
        )
        self.assertEqual(self.workflow_scalar(native_job, "if", 4), "github.event.action != 'edited'")
        self.assertEqual(self.workflow_scalar(native_job, "needs", 4), "engineering-policy")
        self.assertEqual(workflow.count("github.event.action != 'edited'"), 1)
        concurrency_group = self.workflow_scalar(concurrency, "group", 2)
        self.assertIn("github.event.action == 'edited'", concurrency_group)
        self.assertIn("'metadata'", concurrency_group)
        self.assertIn("'source'", concurrency_group)
        self.assertEqual(self.workflow_scalar(concurrency, "cancel-in-progress", 2), "true")
        self.assertIn("Test Engineering impact policy", policy_job)
        self.assertIn("Validate Engineering impact classification", policy_job)

    def test_packaging_uses_a_clean_exact_tree_after_mutating_tests(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertIn('git worktree add --detach "$PACKAGE_SOURCE" "$GITHUB_SHA"', workflow)
        self.assertIn('"$PACKAGE_SOURCE/scripts/package-app.sh" release', workflow)
        self.assertNotIn("INTERVIEW_ARC_LIVE_ALLOW_DIRTY", workflow)
        self.assertNotIn("/usr/bin/ditto", workflow)
        self.assertNotIn("mkdir -p dist", workflow)
        self.assertIn(
            "${{ runner.temp }}/InterviewArcLivePackageSource/dist/Interview Arc Live.app",
            workflow,
        )

    def test_packaging_reuses_the_verified_release_build_products(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        package_script = PACKAGE_SCRIPT.read_text(encoding="utf-8")
        receipt_script = BUILD_RECEIPT_SCRIPT.read_text(encoding="utf-8")
        test_build = self.workflow_step(workflow, "Build package and tests with Metal")
        test_run = self.workflow_step(workflow, "Test package")
        release_build = self.workflow_step(workflow, "Prepare release-equivalent package products")
        package = self.workflow_step(workflow, "Package exact source from a clean worktree")
        self.assertNotIn("INTERVIEW_ARC_LIVE_REUSE_BUILD_PRODUCTS", workflow)
        self.assertIn("${{ runner.temp }}/InterviewArcLiveDerivedData", test_build)
        self.assertIn("${{ runner.temp }}/InterviewArcLiveDerivedData", test_run)
        self.assertIn("${{ runner.temp }}/InterviewArcLivePackageDerivedData", release_build)
        self.assertIn("${{ runner.temp }}/InterviewArcLivePackageDerivedData", package)
        self.assertNotIn("InterviewArcLivePackageDerivedData", test_build)
        self.assertNotIn("InterviewArcLivePackageDerivedData", test_run)
        self.assertNotIn("${{ runner.temp }}/InterviewArcLiveDerivedData", release_build)
        self.assertIn(
            'scripts/build-product-receipt.sh "$GITHUB_SHA" "InterviewArcLive-Package" "Release" "NO" "14.0" "NO" "$package_sdk" "$target_architecture"',
            workflow,
        )
        self.assertIn("InterviewArcLive.build-candidate", workflow)
        self.assertIn("ENABLE_TESTABILITY=YES", test_build)
        self.assertIn("ENABLE_TESTABILITY=YES", test_run)
        self.assertIn("ENABLE_TESTABILITY=NO", release_build)
        self.assertNotIn("ENABLE_TESTABILITY=YES", release_build)
        self.assertIn("package_sdk=macosx", release_build)
        self.assertIn('target_architecture="$(/usr/bin/uname -m)"', release_build)
        self.assertIn('-sdk "$package_sdk"', release_build)
        self.assertIn('-destination "platform=macOS,arch=$target_architecture"', release_build)
        self.assertIn('ARCHS="$target_architecture"', release_build)
        self.assertIn("ONLY_ACTIVE_ARCH=YES", release_build)
        self.assertIn('package_sdk="macosx"', package_script)
        self.assertIn('target_architecture="$(/usr/bin/uname -m)"', package_script)
        self.assertIn('-sdk "$package_sdk"', package_script)
        self.assertIn('-destination "platform=macOS,arch=$target_architecture"', package_script)
        self.assertIn('ARCHS="$target_architecture"', package_script)
        self.assertIn("ONLY_ACTIVE_ARCH=YES", package_script)
        self.assertIn('expected_build_receipt="$("$repo_root/scripts/build-product-receipt.sh"', package_script)
        self.assertIn('"$package_sdk" "$target_architecture")"', package_script)
        self.assertIn('ENABLE_TESTABILITY="$package_testability"', package_script)
        self.assertIn('xcode_version_sha256=', receipt_script)
        self.assertIn('metal_tool_sha256=', receipt_script)
        self.assertIn('xcrun --sdk "$sdk_name" --find metal', receipt_script)
        self.assertIn('developer_dir_sha256=', receipt_script)
        self.assertIn('sdk_name=', receipt_script)
        self.assertIn('sdk_path_sha256=', receipt_script)
        self.assertIn('sdk_version=', receipt_script)
        self.assertIn('sdk_build_version=', receipt_script)
        self.assertIn('target_architecture=', receipt_script)
        self.assertIn('only_active_arch=', receipt_script)

    def test_verified_build_receipt_is_invalidated_before_reuse_and_written_atomically_last(self):
        package_script = PACKAGE_SCRIPT.read_text(encoding="utf-8")
        manifest_verification = package_script.index(
            '"$repo_root/scripts/verify-package-manifest.sh" "$app_dir" "$manifest_path"'
        )
        receipt_write = package_script.index('mv -f "$receipt_temp" "$verified_build_receipt"')
        self.assertLess(manifest_verification, receipt_write)
        self.assertIn('rm -f "$verified_build_receipt" "$build_candidate_receipt"', package_script)
        self.assertNotIn('dirty_source=true', package_script)

    def test_classification_examples_inside_markdown_fences_are_ignored(self):
        body = "- [x] Capability Dossier\n\n```markdown\n- [x] ADR\n```"
        self.assertEqual(MODULE.validate(body, ["capability-dossier"]), "capability-dossier")

    def test_validator_fields_match_the_versioned_receipt_schema(self):
        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        self.assertEqual(
            hashlib.sha256(SCHEMA.read_bytes()).hexdigest(),
            "3fb0c0d2f080291f0d3ded75d0581c89c564c93ba94acea3fcde05d402fbf9a0",
        )
        self.assertEqual(
            schema["$id"],
            "urn:interview-arc:contracts:engineering-pull-request-receipt:1",
        )
        self.assertEqual(set(schema["required"]), MODULE.RECEIPT_FIELDS)
        self.assertEqual(
            set(schema["properties"]["classification"]["enum"]),
            set(MODULE.CLASSIFICATIONS.values()),
        )
        self.assertFalse(schema["additionalProperties"])

    def test_receipt_collection_and_source_bounds_match_the_schema(self):
        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        sources = schema["properties"]["sources"]
        self.assertEqual(sources["maxItems"], MODULE.MAX_SOURCES)
        self.assertEqual(sources["items"]["properties"]["label"]["maxLength"], MODULE.MAX_SOURCE_LABEL_LENGTH)
        self.assertEqual(sources["items"]["properties"]["url"]["maxLength"], MODULE.MAX_SOURCE_URL_LENGTH)
        self.assertEqual(schema["$defs"]["stringList"]["maxItems"], MODULE.MAX_STRING_LIST_ITEMS)
        self.assertEqual(schema["$defs"]["stringList"]["items"]["maxLength"], MODULE.MAX_STRING_LENGTH)
        self.assertEqual(schema["$defs"]["recordRefs"]["maxItems"], MODULE.MAX_RECORD_REFS)
        self.assertEqual(schema["$defs"]["recordRefs"]["items"]["maxLength"], MODULE.MAX_RECORD_REF_LENGTH)

        oversized_unknowns = json.dumps([f"unknown-{index}" for index in range(MODULE.MAX_STRING_LIST_ITEMS + 1)])
        with self.assertRaisesRegex(ValueError, "at most"):
            self.validate_receipt(self.receipt_markdown().replace("unknowns: []", f"unknowns: {oversized_unknowns}"))
        with self.assertRaisesRegex(ValueError, "source label"):
            self.validate_receipt(self.receipt_markdown().replace("Pull request #42", "x" * 161))
        oversized_refs = json.dumps([f"record-{index}@1" for index in range(MODULE.MAX_RECORD_REFS + 1)])
        with self.assertRaisesRegex(ValueError, "at most"):
            self.validate_receipt(self.receipt_markdown(rich_record_refs=oversized_refs))

    def test_classification_pattern_is_derived_from_the_canonical_map(self):
        for label in MODULE.CLASSIFICATIONS:
            self.assertRegex(f"- [x] {label}", MODULE.CLASSIFICATION_PATTERN)

    def test_record_type_must_be_in_the_leading_frontmatter(self):
        with self.assertRaisesRegex(ValueError, "valid type in leading front matter"):
            MODULE.record_type_from_markdown("# Body\n\ntype: capability-dossier\n", "record.md")
        with self.assertRaisesRegex(ValueError, "valid type in leading front matter"):
            MODULE.record_type_from_markdown("---\ntitle: Missing type\n---\n\ntype: capability-dossier\n", "record.md")

    def test_frontmatter_rejects_yaml_only_syntax(self):
        for value in ("'single quoted'", "|", ">", "&anchor", "*alias", "!tag"):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "unsupported YAML-only syntax"):
                MODULE.frontmatter_document(f"---\ntitle: {value}\n---\n", "record.md")

    def test_record_type_reuses_the_canonical_frontmatter_parser(self):
        with patch.object(
            MODULE,
            "frontmatter_document",
            return_value=({"type": "capability-dossier"}, "# Body"),
        ) as parser:
            self.assertEqual(
                MODULE.record_type_from_markdown("ignored", "record.md"),
                "capability-dossier",
            )
        parser.assert_called_once_with("ignored", "record.md")

    def test_existing_broken_head_never_falls_back_to_stale_base_metadata(self):
        path = "docs/engineering/records/example.md"
        with (
            patch.object(MODULE, "git_objects_exist", return_value={path}),
            patch.object(MODULE, "matching_record_paths", return_value=[]) as matching_paths,
            patch.object(
                MODULE,
                "iter_frontmatters_at",
                return_value=iter([(path, {"id": "example", "revision": 1, "title": "Broken"})]),
            ),
        ):
            with self.assertRaisesRegex(ValueError, "invalid type"):
                MODULE.record_index_and_changed_types_at("head", [path])
        matching_paths.assert_called_once_with("head", {"example"})

    def test_canonical_records_must_be_superseded_instead_of_deleted(self):
        path = "docs/engineering/records/example.md"
        with patch.object(MODULE, "git_objects_exist", return_value=set()):
            with self.assertRaisesRegex(ValueError, "cannot be deleted"):
                MODULE.record_index_and_changed_types_at("head", [path])

    def test_requires_exactly_one_choice(self):
        with self.assertRaisesRegex(ValueError, "exactly one"):
            MODULE.validate("", [])
        with self.assertRaisesRegex(ValueError, "exactly one"):
            MODULE.validate("- [x] ADR\n- [x] Postmortem", ["adr"])

    def test_none_requires_a_reason_and_no_record(self):
        with self.assertRaisesRegex(ValueError, "concrete reason"):
            MODULE.validate("- [x] None — reason: TODO", [])
        with self.assertRaisesRegex(ValueError, "concrete reason"):
            MODULE.validate("- [x] None — reason: REPLACE WITH A CONCRETE REASON", [])
        with self.assertRaisesRegex(ValueError, "concrete reason"):
            MODULE.validate("- [x] None — reason: TODO pending review of this change", [])
        with self.assertRaisesRegex(ValueError, "concrete reason"):
            MODULE.validate("- [x] None — reason: !!!!!!!!!!!!", [])
        self.assertEqual(
            MODULE.validate("- [x] None — reason: This change only corrects non-engineering copy.", []),
            "none",
        )
        self.assertEqual(
            MODULE.validate("- [x] None — reason: This change replaces an obsolete workflow without changing runtime behavior.", []),
            "none",
        )
        with self.assertRaisesRegex(ValueError, "cannot be `None`"):
            MODULE.validate("- [x] None — reason: This change only corrects non-engineering copy.", ["capability-dossier"])

    def test_material_classification_may_reuse_an_existing_matching_record(self):
        self.assertEqual(MODULE.validate("- [x] Capability Dossier", ["capability-dossier"]), "capability-dossier")
        self.assertEqual(MODULE.validate("- [x] Capability Dossier", []), "capability-dossier")
        parsed = self.validate_receipt()
        self.assertEqual(parsed["richRecordRefs"], ["capability-dossier-deep-interview-room-session@1"])
        with self.assertRaisesRegex(ValueError, "does not match"):
            MODULE.validate("- [x] Capability Dossier", ["postmortem"])

    def test_every_pull_request_requires_its_exact_receipt_path(self):
        self.assertEqual(
            MODULE.required_receipt_path(
                ["README.md", "docs/engineering/changes/pr-42.md"],
                42,
            ),
            "docs/engineering/changes/pr-42.md",
        )
        with self.assertRaisesRegex(ValueError, "exactly one receipt.*pr-42.md"):
            MODULE.required_receipt_path(["README.md"], 42)
        with self.assertRaisesRegex(ValueError, "exactly one receipt.*pr-42.md"):
            MODULE.required_receipt_path(
                [
                    "docs/engineering/changes/pr-41.md",
                    "docs/engineering/changes/pr-42.md",
                ],
                42,
            )

    def test_receipt_requires_strict_forward_v1_identity(self):
        receipt = self.receipt_markdown()
        parsed = self.validate_receipt(receipt)
        self.assertEqual(parsed["pr"], 42)

        with self.assertRaisesRegex(ValueError, "repository"):
            self.validate_receipt(self.receipt_markdown(repository="interview-arc"))
        with self.assertRaisesRegex(ValueError, "reconstructed"):
            self.validate_receipt(receipt.replace("reconstructed: false", "reconstructed: true"))
        with self.assertRaisesRegex(ValueError, "leading front matter"):
            self.validate_receipt("")

    def test_receipt_classification_and_exact_rich_record_must_match(self):
        with self.assertRaisesRegex(ValueError, "classification"):
            self.validate_receipt(self.receipt_markdown(classification="postmortem"))
        with self.assertRaisesRegex(ValueError, "does not resolve"):
            self.validate_receipt(self.receipt_markdown(rich_record_refs='["missing-record@1"]'))
        with self.assertRaisesRegex(ValueError, "matching type"):
            self.validate_receipt(
                record_index={"capability-dossier-deep-interview-room-session@1": "architecture-review"},
            )

    def test_none_receipt_has_no_rich_record_and_summary_stays_compact(self):
        parsed = self.validate_receipt(
            self.receipt_markdown(classification="none", rich_record_refs="[]"),
            classification="none",
            record_index={},
        )
        self.assertEqual(parsed["richRecordRefs"], [])
        with self.assertRaisesRegex(ValueError, "280 characters"):
            self.validate_receipt(
                self.receipt_markdown().replace(
                    "Adopted complete pull-request receipts and a curated Engineering record for the Live session Module.",
                    "x" * 281,
                ),
            )

    def test_pr_42_receipt_passes_the_forward_contract(self):
        parsed = self.validate_receipt(CURRENT_RECEIPT.read_text(encoding="utf-8"))
        self.assertEqual(parsed["richRecordRefs"], ["capability-dossier-deep-interview-room-session@1"])

    def test_oversized_receipt_is_rejected_before_blob_content_is_read(self):
        size_result = Mock(returncode=0, stdout=str(MODULE.MAX_RECEIPT_BYTES + 1), stderr="")
        with patch.object(MODULE.subprocess, "run", return_value=size_result) as run:
            with self.assertRaisesRegex(ValueError, "oversized"):
                MODULE.bounded_git_blob("head", "docs/engineering/changes/pr-42.md")
        self.assertEqual(run.call_count, 1)

    def test_accepted_record_revisions_cannot_be_replaced_in_place(self):
        path = "docs/engineering/records/session.md"
        with patch.object(MODULE, "git_objects_exist", return_value={path}):
            with self.assertRaisesRegex(ValueError, "immutable.*new record"):
                MODULE.validate_record_history("base", [path])
        with patch.object(MODULE, "git_objects_exist", return_value=set()):
            MODULE.validate_record_history("base", [path])

    def test_record_existence_checks_are_batched(self):
        present = "docs/engineering/records/present.md"
        missing = "docs/engineering/records/missing.md"
        result = Mock(
            stdout=f"{'0' * 40} blob 123\nhead:{missing} missing\n",
        )
        with patch.object(MODULE.subprocess, "run", return_value=result) as run:
            self.assertEqual(MODULE.git_objects_exist("head", [present, missing]), {present})
        run.assert_called_once()
        self.assertEqual(
            run.call_args.kwargs["input"],
            f"head:{present}\nhead:{missing}\n",
        )

    def test_record_discovery_matches_unquoted_and_json_quoted_ids_in_one_scan(self):
        result = Mock(returncode=1, stdout=b"", stderr=b"")
        with patch.object(MODULE.subprocess, "run", return_value=result) as run:
            self.assertEqual(MODULE.matching_record_paths("head", {"shared"}), [])
        command = run.call_args.args[0]
        self.assertIn(r"^[[:space:]]*id[[:space:]]*:[[:space:]]*shared[[:space:]]*$", command)
        self.assertIn(r'^[[:space:]]*id[[:space:]]*:[[:space:]]*"shared"[[:space:]]*$', command)
        run.assert_called_once()

    def test_record_lookup_parses_only_changed_records_and_exact_receipt_references(self):
        validator = SCRIPT.read_text(encoding="utf-8")
        self.assertNotIn('"ls-tree"', validator)
        changed_path = "docs/engineering/records/session.md"
        linked_path = "docs/engineering/records/shared.md"
        with (
            patch.object(MODULE, "git_objects_exist", return_value={changed_path}),
            patch.object(MODULE, "matching_record_paths", return_value=[linked_path]) as matching_paths,
            patch.object(MODULE, "bounded_git_blob", side_effect=AssertionError("must not buffer the record corpus")),
            patch.object(
                MODULE,
                "iter_frontmatters_at",
                side_effect=[
                    iter([(changed_path, {"id": "session", "revision": 1, "type": "capability-dossier"})]),
                    iter([(linked_path, {"id": "shared", "revision": 2, "type": "capability-dossier"})]),
                ],
            ) as iter_frontmatters_at,
        ):
            self.assertEqual(
                MODULE.record_index_and_changed_types_at("head", [changed_path], ["shared@2"]),
                (
                    {"session@1": "capability-dossier", "shared@2": "capability-dossier"},
                    ["capability-dossier"],
                ),
            )
        matching_paths.assert_called_once_with("head", {"session", "shared"})
        self.assertEqual(iter_frontmatters_at.call_count, 2)
        iter_frontmatters_at.assert_any_call("head", [changed_path])
        iter_frontmatters_at.assert_any_call("head", [linked_path])

    def test_changed_record_identity_is_queried_for_duplicates_even_when_not_linked(self):
        changed_path = "docs/engineering/records/session.md"
        duplicate_path = "docs/engineering/records/other.md"
        with (
            patch.object(MODULE, "git_objects_exist", return_value={changed_path}),
            patch.object(MODULE, "matching_record_paths", return_value=[changed_path, duplicate_path]) as matching_paths,
            patch.object(
                MODULE,
                "iter_frontmatters_at",
                side_effect=[
                    iter([(changed_path, {"id": "session", "revision": 1, "type": "capability-dossier"})]),
                    iter([
                        (duplicate_path, {"id": "session", "revision": 1, "type": "capability-dossier"}),
                    ]),
                ],
            ),
        ):
            with self.assertRaisesRegex(ValueError, "Duplicate canonical"):
                MODULE.record_index_and_changed_types_at("head", [changed_path], [])
        matching_paths.assert_called_once_with("head", {"session"})

    def test_verified_rich_record_requires_recorded_evidence(self):
        path = "docs/engineering/records/session.md"
        metadata = {
            "id": "session",
            "revision": 1,
            "type": "capability-dossier",
            "confidence": "verified",
            "verification": {"state": "not-recorded", "evidenceRefs": []},
        }
        with self.assertRaisesRegex(ValueError, "verified confidence.*evidence"):
            MODULE.build_record_index({path: metadata}, [path])

    def test_record_frontmatters_are_requested_in_bounded_batches(self):
        paths = [f"docs/engineering/records/record-{index}.md" for index in range(65)]
        output = bytearray()
        for index, path in enumerate(paths):
            markdown = (
                f"---\nid: record-{index}\nrevision: 1\ntype: capability-dossier\n---\n"
            ).encode()
            output.extend(f"{'0' * 40} blob {len(markdown)}\n".encode())
            output.extend(markdown)
            output.extend(b"\n")

        process = Mock()
        process.args = ["git", "cat-file", "--batch"]
        process.stdin = Mock()
        process.stdout = BytesIO(output)
        process.stderr = BytesIO()
        process.wait.return_value = 0
        with patch.object(MODULE.subprocess, "Popen", return_value=process):
            frontmatters = list(MODULE.iter_frontmatters_at("head", paths))

        self.assertEqual(len(frontmatters), 65)
        self.assertEqual(process.stdin.flush.call_count, 2)

    def test_oversized_record_is_rejected_before_blob_content_is_read(self):
        path = "docs/engineering/records/oversized.md"
        process = Mock()
        process.args = ["git", "cat-file", "--batch"]
        process.stdin = Mock()
        process.stdout = Mock()
        process.stdout.readline.return_value = (
            f"{'0' * 40} blob {MODULE.MAX_RECORD_BYTES + 1}\n".encode()
        )
        process.stdout.read.side_effect = AssertionError("oversized blob content must not be read")
        process.stderr = BytesIO()
        process.wait.return_value = 0
        with patch.object(MODULE.subprocess, "Popen", return_value=process):
            with self.assertRaisesRegex(ValueError, "invalid or oversized"):
                list(MODULE.iter_frontmatters_at("head", [path]))
        process.stdout.read.assert_not_called()


if __name__ == "__main__":
    unittest.main()
