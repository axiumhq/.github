import importlib.util
import json
import tempfile
import unittest
from unittest import mock
from pathlib import Path

MODULE_PATH = Path(__file__).with_name("prepare-release-diff.py")
SPEC = importlib.util.spec_from_file_location("prepare_release_diff", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def section(path, body="@@ -1 +1 @@\n-old\n+new\n"):
    return f"diff --git a/{path} b/{path}\n--- a/{path}\n+++ b/{path}\n{body}"


class PrepareReleaseDiffTests(unittest.TestCase):
    def test_test_only_pr_is_deterministically_none(self):
        prepared = MODULE.prepare(section("src/foo.test.ts") + section("src/testes/helper.ts"), "test", "")
        self.assertEqual(prepared["action"], "none")
        self.assertEqual(prepared["analysis_diff"], "")

    def test_docs_only_pr_is_deterministically_none(self):
        prepared = MODULE.prepare(section("docs/api.md") + section("README.md"), "docs", "")
        self.assertEqual(prepared["action"], "none")

    def test_dependency_only_pr_is_none_even_with_user_facing_upstream_notes(self):
        diff = section("server/docs/pnpm-lock.yaml") + section("server/docs/package-lock.json")
        body = "Release notes: Fix rendering bug and add a new feature."
        prepared = MODULE.prepare(diff, "chore(deps): update Scalar", body)
        self.assertEqual(prepared["action"], "none")
        self.assertEqual(prepared["analysis_diff"], "")

    def test_dependency_only_pr_with_fix_notes_is_none(self):
        body = "Release notes: Fix hickory-dns to prefer IPv6. Fix sending wrong proxy-auth if multiple proxies intercept a given URL."
        prepared = MODULE.prepare(section("Cargo.lock"), "chore(deps): update reqwest to v0.13.5", body)
        self.assertEqual(prepared["action"], "none")

    def test_dependency_only_pr_does_not_fetch_upstream_changelog(self):
        body = "Release notes: [solidjs/solid](https://redirect.github.com/solidjs/solid/compare/solid-js@1.9.15...v1.9.16)"
        with mock.patch.object(MODULE, "linked_upstream_release_notes", side_effect=AssertionError("should not fetch")):
            prepared = MODULE.prepare(section("pnpm-lock.yaml"), "chore(deps): update dependency solid-js to v1.9.17", body)
        self.assertEqual(prepared["action"], "none")

    def test_tooling_only_dependency_update_is_none(self):
        diff = section("pnpm-lock.yaml")
        prepared = MODULE.prepare(diff, "chore(deps): update formatter", "Release notes: formatting and lint compatibility changes for the build tooling.")
        self.assertEqual(prepared["action"], "none")

    def test_unclear_dependency_only_update_is_none_not_review(self):
        prepared = MODULE.prepare(section("pnpm-lock.yaml"), "chore(deps): update library", "Automated dependency update.")
        self.assertEqual(prepared["action"], "none")
        self.assertIn("dependency-lockfile", prepared["paths_by_category"])

    def test_mixed_pr_sends_only_implementation_diff(self):
        diff = (
            section("src/feature.ts", "@@ -1 +1 @@\n-old implementation\n+new implementation\n")
            + section("src/feature.test.ts")
            + section("docs/feature.md")
            + section("pnpm-lock.yaml")
        )
        prepared = MODULE.prepare(diff, "feat: feature", "Dependency release notes: bug fix.")
        self.assertEqual(prepared["action"], "jev")
        self.assertEqual(prepared["analysis_files"], ["src/feature.ts"])
        self.assertIn("new implementation", prepared["analysis_diff"])
        self.assertNotIn("feature.test.ts", prepared["analysis_diff"])
        self.assertNotIn("pnpm-lock.yaml", prepared["analysis_diff"])
        self.assertEqual(prepared["policy_impact"], "patch")

    def test_config_and_generated_runtime_assets_are_not_dropped(self):
        diff = section("src/theme.generated.css")
        prepared = MODULE.prepare(diff, "fix: theme", "")
        self.assertEqual(prepared["action"], "jev")
        self.assertEqual(prepared["analysis_files"], ["src/theme.generated.css"])

    def test_binary_file_section_is_recognized(self):
        # Seção binária não tem `---`/`+++`; o #378 travou a release com um screenshot novo.
        png = "src/admin/__screenshots__/admin.browser.test.tsx/lista-1.png"
        diff = section("src/admin/Lista.tsx") + (
            f"diff --git a/{png} b/{png}\n"
            "new file mode 100644\n"
            "index 000000000..9d7c1ee23\n"
            f"Binary files /dev/null and b/{png} differ\n"
        )
        prepared = MODULE.prepare(diff, "feat: lista", "")
        self.assertEqual(prepared["action"], "jev")
        self.assertEqual(prepared["analysis_files"], ["src/admin/Lista.tsx"])

    def test_pure_rename_section_uses_new_path(self):
        diff = (
            "diff --git a/src/velho.ts b/src/novo.ts\n"
            "similarity index 100%\n"
            "rename from src/velho.ts\n"
            "rename to src/novo.ts\n"
        )
        self.assertEqual(MODULE.split_sections(diff)[0][0], "src/novo.ts")

    def test_manifest_and_lockfile_bump_is_none(self):
        # #394: Renovate troca uma linha do package.json e o lockfile. Isso
        # ia para o Jev como código e um `review` segurava a release inteira.
        diff = (
            section(
                "client/packages/nucleo/package.json",
                "@@ -25,7 +25,7 @@\n"
                '   "dependencies": {\n'
                '-    "@sapphi-red/web-noise-suppressor": "0.4.0",\n'
                '+    "@sapphi-red/web-noise-suppressor": "0.4.1",\n'
                '-    "solid-js": "^1.9.15",\n'
                '+    "solid-js": "^1.9.16",\n'
                "   }\n",
            )
            + section("client/pnpm-lock.yaml")
        )
        body = "Release notes: [compare](https://github.com/sapphi-red/web-noise-suppressor/compare/v0.4.0...v0.4.1)\nFix rendering."
        with mock.patch.object(MODULE, "linked_upstream_release_notes", side_effect=AssertionError("should not fetch")):
            prepared = MODULE.prepare(diff, "Update dependency @sapphi-red/web-noise-suppressor to v0.4.1", body)
        self.assertEqual(prepared["action"], "none")
        self.assertEqual(prepared["analysis_diff"], "")
        self.assertIn("manifests", prepared["policy_reason"])
        self.assertEqual(
            prepared["paths_by_category"]["dependency-lockfile"],
            ["client/packages/nucleo/package.json", "client/pnpm-lock.yaml"],
        )
        self.assertNotIn("implementation", prepared["counts"])

    def test_manifest_only_bump_is_none(self):
        diff = section(
            "client/packages/app/package.json",
            "@@ -46,7 +46,7 @@\n"
            '-    "@vitejs/plugin-react": "6.1.1",\n'
            '+    "@vitejs/plugin-react": "6.1.2",\n',
        )
        prepared = MODULE.prepare(diff, "chore(deps): update dependency @vitejs/plugin-react to v6.1.2", "")
        self.assertEqual(prepared["action"], "none")
        self.assertEqual(prepared["analysis_diff"], "")

    def test_cargo_manifest_and_lockfile_bump_is_none(self):
        diff = (
            section(
                "server/Cargo.toml",
                '@@ -23,7 +23,7 @@\n-async-tungstenite = "0.17.0"\n+async-tungstenite = "0.35.0"\n',
            )
            + section("server/Cargo.lock")
        )
        prepared = MODULE.prepare(diff, "chore(deps): update rust crate async-tungstenite to 0.35.0", "")
        self.assertEqual(prepared["action"], "none")
        self.assertEqual(prepared["analysis_diff"], "")
        self.assertEqual(
            prepared["paths_by_category"]["dependency-lockfile"],
            ["server/Cargo.lock", "server/Cargo.toml"],
        )

    def test_package_script_change_still_reaches_jev(self):
        diff = (
            section(
                "client/packages/app/package.json",
                "@@ -8,7 +8,7 @@\n"
                '   "scripts": {\n'
                '-    "dev": "vite",\n'
                '+    "dev": "vite --host",\n'
                "   }\n",
            )
            + section("client/pnpm-lock.yaml")
        )
        prepared = MODULE.prepare(diff, "chore: dev script", "")
        self.assertEqual(prepared["action"], "jev")
        self.assertEqual(prepared["analysis_files"], ["client/packages/app/package.json"])
        self.assertIn("vite --host", prepared["analysis_diff"])
        self.assertNotIn("pnpm-lock.yaml", prepared["analysis_diff"])

    def test_manifest_bump_with_source_still_reaches_jev(self):
        diff = (
            section(
                "client/packages/app/package.json",
                '@@ -1 +1 @@\n-    "react": "19.0.0",\n+    "react": "19.1.0",\n',
            )
            + section("src/feature.ts", "@@ -1 +1 @@\n-old implementation\n+new implementation\n")
        )
        prepared = MODULE.prepare(diff, "feat: feature", "")
        self.assertEqual(prepared["action"], "jev")
        self.assertEqual(
            prepared["analysis_files"],
            ["client/packages/app/package.json", "src/feature.ts"],
        )

    def test_own_package_version_still_reaches_jev(self):
        diff = section(
            "client/packages/app/package.json",
            '@@ -1,3 +1,3 @@\n-  "version": "1.4.0",\n+  "version": "1.5.0",\n',
        )
        prepared = MODULE.prepare(diff, "chore: version", "")
        self.assertEqual(prepared["action"], "jev")
        self.assertEqual(prepared["analysis_files"], ["client/packages/app/package.json"])

    def test_cargo_package_version_and_inline_table_still_reach_jev(self):
        version = section(
            "server/Cargo.toml",
            '@@ -1,3 +1,3 @@\n-version = "0.1.0"\n+version = "0.2.0"\n',
        )
        inline = section(
            "server/Cargo.toml",
            "@@ -1,3 +1,3 @@\n"
            '-tokio = { version = "1.49.0", features = ["full"] }\n'
            '+tokio = { version = "1.50.0", features = ["full"] }\n',
        )
        for diff in (version, inline):
            prepared = MODULE.prepare(diff + section("server/Cargo.lock"), "chore: cargo", "")
            self.assertEqual(prepared["action"], "jev")
            self.assertEqual(prepared["analysis_files"], ["server/Cargo.toml"])

    def test_non_version_specifier_still_reaches_jev(self):
        workspace = section(
            "client/packages/app/package.json",
            '@@ -1 +1 @@\n-    "react": "workspace:*",\n+    "react": "workspace:^",\n',
        )
        short = section(
            "client/packages/app/package.json",
            '@@ -1 +1 @@\n-    "node": ">=20",\n+    "node": ">=22",\n',
        )
        renovate = section(
            "renovate.json",
            '@@ -1 +1 @@\n-  "rangeStrategy": "bump"\n+  "rangeStrategy": "pin"\n',
        ) + section(
            "client/packages/app/package.json",
            '@@ -1 +1 @@\n-    "react": "19.0.0",\n+    "react": "19.1.0",\n',
        )
        for diff in (workspace, short, renovate):
            prepared = MODULE.prepare(diff, "chore: not a pure bump", "")
            self.assertEqual(prepared["action"], "jev")

    def test_malformed_diff_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "unexpected content"):
            MODULE.prepare("@@ -1 +1 @@\n-old\n+new\n", "title", "")


if __name__ == "__main__":
    unittest.main()
