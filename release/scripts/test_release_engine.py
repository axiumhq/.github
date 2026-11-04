import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ENGINE = Path(__file__).resolve().parent


def run(*args, cwd, env=None):
    return subprocess.run(args, cwd=cwd, env=env, text=True, capture_output=True, check=True).stdout.strip()


class ReleaseEngineTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.origin = self.root / 'origin.git'
        self.work = self.root / 'work'
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        run('git', 'init', '--bare', str(self.origin), cwd=self.root)
        run('git', 'init', '-b', 'main', str(self.work), cwd=self.root)
        run('git', 'config', 'user.email', 'test@example.com', cwd=self.work)
        run('git', 'config', 'user.name', 'Test', cwd=self.work)
        run('git', 'remote', 'add', 'origin', str(self.origin), cwd=self.work)
        (self.work / 'app.txt').write_text('first\n')
        run('git', 'add', '.', cwd=self.work)
        run('git', 'commit', '-m', 'initial', cwd=self.work)
        run('git', 'push', '-u', 'origin', 'main', cwd=self.work)
        gh = self.bin / 'gh'
        gh.write_text('#!/bin/sh\ncase "$1 $2" in "api graphql") echo 0;; "pr list") if [ -n "${PR_FIXTURE:-}" ]; then cat "$PR_FIXTURE"; else echo "[]"; fi;; "release view") exit 1;; *) echo "unexpected gh call: $*" >&2; exit 1;; esac\n')
        gh.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}', GH_TOKEN='test', JEV_API_KEY='test', REPOSITORY='org/project', ENGINE_ROOT=str(ENGINE.parent), STABILIZATION_SECONDS='0', GITHUB_STEP_SUMMARY=str(self.root / 'summary'), DRY_RUN='true')

    def test_untagged_direct_commit_is_analyzed_without_mutation(self):
        (self.work / '.github' / 'workflows').mkdir(parents=True)
        (self.work / '.github' / 'workflows' / 'ci.yml').write_text('name: test\n')
        run('git', 'add', '.', cwd=self.work)
        run('git', 'commit', '-m', 'ci: configure', cwd=self.work)
        run('git', 'push', 'origin', 'main', cwd=self.work)
        result = run('bash', str(ENGINE / 'intelligent-release.sh'), cwd=self.work, env=self.env)
        self.assertIn('No version tag exists; using baseline', result)
        self.assertIn('Classifying 1 merged PR(s)', result)
        self.assertIn('deterministic: release/CI-only paths', result)
        self.assertEqual(run('git', 'tag', '-l', cwd=self.work), '')

    def test_superseded_checkout_exits_successfully_without_release(self):
        other = self.root / 'other'
        run('git', 'clone', '-b', 'main', str(self.origin), str(other), cwd=self.root)
        run('git', 'config', 'user.email', 'test@example.com', cwd=other)
        run('git', 'config', 'user.name', 'Test', cwd=other)
        (other / 'app.txt').write_text('newer\n')
        run('git', 'add', '.', cwd=other)
        run('git', 'commit', '-m', 'newer', cwd=other)
        run('git', 'push', 'origin', 'main', cwd=other)
        env = dict(self.env, DRY_RUN='false')
        result = run('bash', str(ENGINE / 'intelligent-release.sh'), cwd=self.work, env=env)
        self.assertIn('a newer push will handle it', result)
        self.assertEqual(run('git', 'tag', '-l', cwd=self.work), '')

    def test_maintainer_label_resolves_release_and_conflicts_block(self):
        import json
        (self.work / 'app.txt').write_text('changed\n')
        run('git', 'add', '.', cwd=self.work)
        run('git', 'commit', '-m', 'change', cwd=self.work)
        run('git', 'push', 'origin', 'main', cwd=self.work)
        sha = run('git', 'rev-parse', 'HEAD', cwd=self.work)
        fixture = self.root / 'pulls.json'
        pull = {'number': 12, 'title': 'Feature', 'body': '', 'url': 'https://example.com/pr/12', 'labels': [{'name': 'release-impact/minor'}], 'files': [{'path': 'app.txt'}], 'mergeCommit': {'oid': sha}}
        fixture.write_text(json.dumps([pull]))
        env = dict(self.env, PR_FIXTURE=str(fixture))
        result = run('bash', str(ENGINE / 'intelligent-release.sh'), cwd=self.work, env=env)
        self.assertIn('PR #12 => minor (maintainer label)', result)
        self.assertIn('Would publish: v0.1.0', (self.root / 'summary').read_text())
        pull['labels'].append({'name': 'release-impact/patch'})
        fixture.write_text(json.dumps([pull]))
        result = run('bash', str(ENGINE / 'intelligent-release.sh'), cwd=self.work, env=env)
        self.assertIn('Dry run blocked by 1 PR(s)', result)
        self.assertIn('Conflicting release-impact labels', (self.root / 'summary').read_text())
        self.assertEqual(run('git', 'tag', '-l', cwd=self.work), '')

    def test_direct_commit_override_and_invalid_baseline(self):
        baseline = run('git', 'rev-parse', 'HEAD', cwd=self.work)
        (self.work / 'app.txt').write_text('new behavior\n')
        run('git', 'add', '.', cwd=self.work)
        run('git', 'commit', '-m', 'change', cwd=self.work)
        run('git', 'push', 'origin', 'main', cwd=self.work)
        env = dict(self.env, BASELINE_REF=baseline, BASELINE_VERSION='2.0.0', DIRECT_IMPACT='patch')
        result = run('bash', str(ENGINE / 'intelligent-release.sh'), cwd=self.work, env=env)
        self.assertIn('PR #0 => patch (maintainer label)', result)
        self.assertIn('Would publish: v2.0.1', (self.root / 'summary').read_text())
        invalid = subprocess.run(['bash', str(ENGINE / 'intelligent-release.sh')], cwd=self.work, env=dict(env, BASELINE_REF='abc'), text=True, capture_output=True)
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn('Baseline ref must be a full commit SHA', invalid.stdout)

    def test_automatic_direct_impact_is_accepted(self):
        result = run('bash', str(ENGINE / 'intelligent-release.sh'), cwd=self.work, env=dict(self.env, DIRECT_IMPACT='auto'))
        self.assertIn('No merged PRs after', result)


if __name__ == '__main__':
    unittest.main()
