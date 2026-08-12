#!/usr/bin/env python3
import importlib.util
import json
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).parents[2] / "scripts" / "validate-engineering-impact.py"
WORKFLOW = Path(__file__).parents[2] / ".github" / "workflows" / "swift.yml"
SCHEMA = Path(__file__).parents[2] / "docs" / "contracts" / "engineering-pull-request-receipt.schema.json"
CURRENT_RECEIPT = Path(__file__).parents[2] / "docs" / "engineering" / "changes" / "pr-42.md"
SPEC = importlib.util.spec_from_file_location("engineering_impact", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class EngineeringImpactPolicyTests(unittest.TestCase):
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
sources: [{{"label":"Pull request #42","url":"https://github.com/Vinosaamaa/interview-arc-live/pull/42","kind":"pull-request"}}]
verification: {{"state":"verified","evidenceRefs":["pull-request:42"]}}
visibility: public-safe
publicationEligibility: eligible
---
# Adopt the Engineering Journal contract

Adopted complete pull-request receipts and a curated Engineering record for the Live session Module.
"""

    def test_workflow_fetches_only_exact_pr_revisions_for_diff(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("fetch-depth: 0", workflow)
        self.assertIn("git fetch --no-tags --depth=1 origin \"$BASE_SHA\" \"$HEAD_SHA\"", workflow)

    def test_validator_fields_match_the_versioned_receipt_schema(self):
        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        self.assertEqual(set(schema["required"]), MODULE.RECEIPT_FIELDS)
        self.assertFalse(schema["additionalProperties"])

    def test_classification_pattern_is_derived_from_the_canonical_map(self):
        for label in MODULE.CLASSIFICATIONS:
            self.assertRegex(f"- [x] {label}", MODULE.CLASSIFICATION_PATTERN)

    def test_record_type_must_be_in_the_leading_frontmatter(self):
        with self.assertRaisesRegex(ValueError, "valid type in leading front matter"):
            MODULE.record_type_from_markdown("# Body\n\ntype: capability-dossier\n", "record.md")
        with self.assertRaisesRegex(ValueError, "valid type in leading front matter"):
            MODULE.record_type_from_markdown("---\ntitle: Missing type\n---\n\ntype: capability-dossier\n", "record.md")

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
        with patch.object(MODULE, "git_blobs", side_effect=[{path: "---\ntitle: Broken\n---\n"}, {path: "---\ntype: capability-dossier\n---\n"}]):
            with self.assertRaisesRegex(ValueError, "valid type in leading front matter"):
                MODULE.record_types([path], "head", "base")

    def test_deleted_record_uses_base_frontmatter_for_classification(self):
        path = "docs/engineering/records/example.md"
        with patch.object(MODULE, "git_blobs", side_effect=[{path: None}, {path: "---\ntype: capability-dossier\n---\n"}]):
            self.assertEqual(MODULE.record_types([path], "head", "base"), ["capability-dossier"])

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

    def test_rich_choice_requires_a_matching_record(self):
        self.assertEqual(MODULE.validate("- [x] Capability Dossier", ["capability-dossier"]), "capability-dossier")
        with self.assertRaisesRegex(ValueError, "matching canonical record"):
            MODULE.validate("- [x] Capability Dossier", [])
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
        parsed = MODULE.validate_receipt(
            receipt,
            "docs/engineering/changes/pr-42.md",
            repository="interview-arc-live",
            pr_number=42,
            pr_title="Adopt the Engineering Journal contract",
            classification="capability-dossier",
            record_index={"capability-dossier-deep-interview-room-session@1": "capability-dossier"},
        )
        self.assertEqual(parsed["pr"], 42)

        with self.assertRaisesRegex(ValueError, "repository"):
            MODULE.validate_receipt(
                self.receipt_markdown(repository="interview-arc"),
                "docs/engineering/changes/pr-42.md",
                repository="interview-arc-live",
                pr_number=42,
                pr_title="Adopt the Engineering Journal contract",
                classification="capability-dossier",
                record_index={"capability-dossier-deep-interview-room-session@1": "capability-dossier"},
            )
        with self.assertRaisesRegex(ValueError, "reconstructed"):
            MODULE.validate_receipt(
                receipt.replace("reconstructed: false", "reconstructed: true"),
                "docs/engineering/changes/pr-42.md",
                repository="interview-arc-live",
                pr_number=42,
                pr_title="Adopt the Engineering Journal contract",
                classification="capability-dossier",
                record_index={"capability-dossier-deep-interview-room-session@1": "capability-dossier"},
            )

    def test_receipt_classification_and_exact_rich_record_must_match(self):
        with self.assertRaisesRegex(ValueError, "classification"):
            MODULE.validate_receipt(
                self.receipt_markdown(classification="postmortem"),
                "docs/engineering/changes/pr-42.md",
                repository="interview-arc-live",
                pr_number=42,
                pr_title="Adopt the Engineering Journal contract",
                classification="capability-dossier",
                record_index={"capability-dossier-deep-interview-room-session@1": "capability-dossier"},
            )
        with self.assertRaisesRegex(ValueError, "does not resolve"):
            MODULE.validate_receipt(
                self.receipt_markdown(rich_record_refs='["missing-record@1"]'),
                "docs/engineering/changes/pr-42.md",
                repository="interview-arc-live",
                pr_number=42,
                pr_title="Adopt the Engineering Journal contract",
                classification="capability-dossier",
                record_index={"capability-dossier-deep-interview-room-session@1": "capability-dossier"},
            )
        with self.assertRaisesRegex(ValueError, "matching type"):
            MODULE.validate_receipt(
                self.receipt_markdown(),
                "docs/engineering/changes/pr-42.md",
                repository="interview-arc-live",
                pr_number=42,
                pr_title="Adopt the Engineering Journal contract",
                classification="capability-dossier",
                record_index={"capability-dossier-deep-interview-room-session@1": "architecture-review"},
            )

    def test_none_receipt_has_no_rich_record_and_summary_stays_compact(self):
        parsed = MODULE.validate_receipt(
            self.receipt_markdown(classification="none", rich_record_refs="[]"),
            "docs/engineering/changes/pr-42.md",
            repository="interview-arc-live",
            pr_number=42,
            pr_title="Adopt the Engineering Journal contract",
            classification="none",
            record_index={},
        )
        self.assertEqual(parsed["richRecordRefs"], [])
        with self.assertRaisesRegex(ValueError, "280 characters"):
            MODULE.validate_receipt(
                self.receipt_markdown().replace(
                    "Adopted complete pull-request receipts and a curated Engineering record for the Live session Module.",
                    "x" * 281,
                ),
                "docs/engineering/changes/pr-42.md",
                repository="interview-arc-live",
                pr_number=42,
                pr_title="Adopt the Engineering Journal contract",
                classification="capability-dossier",
                record_index={"capability-dossier-deep-interview-room-session@1": "capability-dossier"},
            )

    def test_pr_42_receipt_passes_the_forward_contract(self):
        parsed = MODULE.validate_receipt(
            CURRENT_RECEIPT.read_text(encoding="utf-8"),
            "docs/engineering/changes/pr-42.md",
            repository="interview-arc-live",
            pr_number=42,
            pr_title="Adopt the Engineering Journal contract",
            classification="capability-dossier",
            record_index={"capability-dossier-deep-interview-room-session@1": "capability-dossier"},
        )
        self.assertEqual(parsed["richRecordRefs"], ["capability-dossier-deep-interview-room-session@1"])

    def test_record_index_reads_only_frontmatter_instead_of_buffering_record_bodies(self):
        path = "docs/engineering/records/session.md"
        with (
            patch.object(MODULE, "git", return_value=path),
            patch.object(MODULE, "git_blobs", side_effect=AssertionError("must not buffer the record corpus")),
            patch.object(
                MODULE,
                "frontmatter_at",
                return_value={"id": "session", "revision": 1, "type": "capability-dossier"},
            ) as frontmatter_at,
        ):
            self.assertEqual(MODULE.record_index_at("head"), {"session@1": "capability-dossier"})
        frontmatter_at.assert_called_once_with("head", path)


if __name__ == "__main__":
    unittest.main()
