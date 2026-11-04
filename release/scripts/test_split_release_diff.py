import importlib.util
import unittest
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("split-release-diff.py")
SPEC = importlib.util.spec_from_file_location("split_release_diff", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def section(path, body="@@ -1 +1 @@\n-old\n+new\n"):
    return f"diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n{body}"


class SplitReleaseDiffTests(unittest.TestCase):
    def test_groups_whole_files_under_byte_limit(self):
        diff = section("a.txt") + section("b.txt") + section("c.txt")
        chunks = MODULE.split_diff(diff, 100)
        self.assertGreater(len(chunks), 1)
        self.assertEqual([p for c in chunks for p in c["files"]], ["a.txt", "b.txt", "c.txt"])
        self.assertTrue(all(c["bytes"] <= 100 for c in chunks))

    def test_keeps_small_diff_as_one_chunk(self):
        diff = section("a.txt")
        chunks = MODULE.split_diff(diff, 1000)
        self.assertEqual(len(chunks), 1)
        self.assertEqual(chunks[0]["diff"], diff)

    def test_oversized_single_file_requires_manual_review(self):
        diff = section("huge.txt", "@@ -1 +1 @@\n-" + ("x" * 200) + "\n")
        with self.assertRaisesRegex(ValueError, "single diff line exceeds"):
            MODULE.split_diff(diff, 100)


    def test_splits_large_file_only_at_hunk_boundaries(self):
        diff = (
            "diff --git a/large.txt b/large.txt\n"
            "index 1111111..2222222 100644\n"
            "--- a/large.txt\n+++ b/large.txt\n"
            "@@ -1 +1 @@\n-" + ("a" * 35) + "\n+" + ("b" * 35) + "\n"
            "@@ -100 +100 @@\n-" + ("c" * 35) + "\n+" + ("d" * 35) + "\n"
        )
        chunks = MODULE.split_diff(diff, 200)
        self.assertEqual(len(chunks), 2)
        self.assertTrue(all(c["bytes"] <= 200 for c in chunks))
        self.assertTrue(all(c["diff"].startswith("diff --git a/large.txt") for c in chunks))
        self.assertEqual(sum(c["diff"].count("@@ -") for c in chunks), 2)


    def test_splits_one_large_hunk_without_dropping_lines(self):
        body = "".join(f"-old line {i:03d}\n+new line {i:03d}\n" for i in range(40))
        diff = section("large-hunk.txt", "@@ -1,40 +1,40 @@\n" + body)
        chunks = MODULE.split_diff(diff, 220)
        self.assertGreater(len(chunks), 1)
        self.assertTrue(all(c["bytes"] <= 220 for c in chunks))
        combined = "".join(c["diff"] for c in chunks)
        self.assertEqual(combined.count("-old line "), 40)
        self.assertEqual(combined.count("+new line "), 40)
        self.assertEqual(combined.count("@@ -"), len(chunks))

    def test_empty_diff_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "diff is empty"):
            MODULE.split_diff("", 100)

    def test_unified_diff_without_file_headers_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "unexpected content"):
            MODULE.split_diff("@@ -1 +1 @@\n", 100)


if __name__ == "__main__":
    unittest.main()
