#!/usr/bin/env python3
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/new-engineering-receipt.py"


def fixture(root: Path):
    (root / "docs/contracts").mkdir(parents=True)
    (root / "docs/engineering/changes").mkdir(parents=True)
    (root / "AGENTS.md").write_text("# Fixture\n", encoding="utf-8")
    (root / "docs/contracts/engineering-pull-request-receipt.schema.json").write_text("{}\n", encoding="utf-8")


def scaffold(root: Path, *arguments: str):
    return subprocess.run(["python3", str(SCRIPT), *arguments], cwd=root, text=True, capture_output=True, check=False)


class EngineeringReceiptScaffoldTests(unittest.TestCase):
    def test_help_teaches_draft_pr_and_authorship_boundary(self):
        result = subprocess.run(["python3", str(SCRIPT), "--help"], text=True, capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Decide the Engineering impact before opening", result.stdout)
        self.assertIn("Open a draft pull request", result.stdout)
        self.assertIn("exact revision already available", result.stdout)
        self.assertIn("concrete reason of at least 12 characters", result.stdout)
        self.assertIn("does not author prose or diagrams", result.stdout)

    def test_non_material_receipt_is_canonical_and_never_overwritten(self):
        with tempfile.TemporaryDirectory(prefix="live-receipt-") as directory:
            root = Path(directory)
            fixture(root)
            arguments = (
                "--pr", "45", "--title", "Make Engineering receipt authoring self-teaching",
                "--summary", "Added a local scaffold and durable coordinator guidance without changing Live runtime behavior.",
                "--classification", "none",
            )
            result = scaffold(root, *arguments)
            self.assertEqual(result.returncode, 0, result.stderr)
            target = root / "docs/engineering/changes/pr-45.md"
            markdown = target.read_text(encoding="utf-8")
            self.assertIn("repository: interview-arc-live", markdown)
            self.assertIn("pr: 45", markdown)
            self.assertIn("reconstructed: false", markdown)
            self.assertIn("https://github.com/Vinosaamaa/interview-arc-live/pull/45", markdown)
            repeated = scaffold(root, *arguments)
            self.assertEqual(repeated.returncode, 1)
            self.assertIn("Refusing to overwrite", repeated.stderr)
            self.assertEqual(target.read_text(encoding="utf-8"), markdown)

    def test_material_refs_are_required_valid_unique_and_sorted(self):
        with tempfile.TemporaryDirectory(prefix="live-receipt-") as directory:
            root = Path(directory)
            fixture(root)
            result = scaffold(
                root,
                "--pr", "46", "--title", "Document one reviewed boundary",
                "--summary", "Linked the exact reviewed records that own this material architecture change.",
                "--classification", "architecture-review",
                "--rich-record-ref", "second-record@2",
                "--rich-record-ref", "first-record@1",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            markdown = (root / "docs/engineering/changes/pr-46.md").read_text(encoding="utf-8")
            self.assertIn('richRecordRefs: ["first-record@1","second-record@2"]', markdown)
            invalid_cases = (
                (),
                ("--rich-record-ref", "Bad@0"),
                ("--rich-record-ref", "same@1", "--rich-record-ref", "same@1"),
            )
            for index, suffix in enumerate(invalid_cases, start=50):
                result = scaffold(
                    root,
                    "--pr", str(index), "--title", "Document one reviewed boundary",
                    "--summary", "Linked the exact reviewed record that owns this material architecture change.",
                    "--classification", "architecture-review", *suffix,
                )
                self.assertEqual(result.returncode, 1)

    def test_public_unsafe_values_fail_without_echo_or_file(self):
        unsafe = str(Path("/", "Users", "person", "Projects", "private", "notes.txt"))
        with tempfile.TemporaryDirectory(prefix="live-receipt-") as directory:
            root = Path(directory)
            fixture(root)
            result = scaffold(
                root,
                "--pr", "60", "--title", "Document one safe change",
                "--summary", unsafe, "--classification", "none",
            )
            self.assertEqual(result.returncode, 1)
            self.assertNotIn(unsafe, result.stderr)
            self.assertFalse((root / "docs/engineering/changes/pr-60.md").exists())

    def test_title_json_quoting_matches_the_shared_scalar_grammar(self):
        with tempfile.TemporaryDirectory(prefix="live-receipt-") as directory:
            root = Path(directory)
            fixture(root)
            title = 'Don\'t regress: preserve "receipt" titles'
            result = scaffold(
                root,
                "--pr", "61", "--title", title,
                "--summary", "Preserved public punctuation in the exact pull-request title.",
                "--classification", "none",
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            markdown = (root / "docs/engineering/changes/pr-61.md").read_text(encoding="utf-8")
            title_line = next(line for line in markdown.splitlines() if line.startswith("title: "))
            self.assertEqual(json.loads(title_line.removeprefix("title: ")), title)


if __name__ == "__main__":
    unittest.main()
