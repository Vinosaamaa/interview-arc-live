#!/usr/bin/env python3
import importlib.util
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).parents[2] / "scripts" / "validate-engineering-impact.py"
WORKFLOW = Path(__file__).parents[2] / ".github" / "workflows" / "swift.yml"
SPEC = importlib.util.spec_from_file_location("engineering_impact", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class EngineeringImpactPolicyTests(unittest.TestCase):
    def test_workflow_fetches_only_exact_pr_revisions_for_diff(self):
        workflow = WORKFLOW.read_text(encoding="utf-8")
        self.assertNotIn("fetch-depth: 0", workflow)
        self.assertIn("git fetch --no-tags --depth=1 origin \"$BASE_SHA\" \"$HEAD_SHA\"", workflow)

    def test_classification_pattern_is_derived_from_the_canonical_map(self):
        for label in MODULE.CLASSIFICATIONS:
            self.assertRegex(f"- [x] {label}", MODULE.CLASSIFICATION_PATTERN)

    def test_record_type_must_be_in_the_leading_frontmatter(self):
        with self.assertRaisesRegex(ValueError, "valid type in leading front matter"):
            MODULE.record_type_from_markdown("# Body\n\ntype: capability-dossier\n", "record.md")
        with self.assertRaisesRegex(ValueError, "valid type in leading front matter"):
            MODULE.record_type_from_markdown("---\ntitle: Missing type\n---\n\ntype: capability-dossier\n", "record.md")

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


if __name__ == "__main__":
    unittest.main()
