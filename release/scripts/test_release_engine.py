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
        gh.write_text('#!/bin/sh\ncase "$1 $2" in "api graphql") echo 0;; "pr list") echo "[]";; *) echo "unexpected gh call: $*" >&2; exit 1;; esac\n')
        gh.chmod(0o755)
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}', GH_TOKEN='test', JEV_API_KEY='test', REPOSITORY='org/project', ENGINE_ROOT=str(ENGINE.parent), STABILIZATION_SECONDS='0', GITHUB_STEP_SUMMARY=str(self.root / 'summary'), DRY_RUN='true')

    def test_untagged_direct_commit_is_analyzed_without_mutation(self):
        (self.work / '.github' / 'workflows').mkdir(parents=True)
        (self.work / '.github' / 'workflows' / 'ci.yml').write_text('name: test\n')
        run('git', 'add', '.', cwd=self.work)
        run('git', 'commit', '-m', 'ci: configure', cwd=self.work)
        run('git', 'push', 'origin', 'main', cwd=self.work)
        result = run('bash', str(ENGINE / 'intelligent-release.sh'), cwd=self.work, env=self.env)
        self.assertIn('using the first commit as baseline', result)
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


if __name__ == '__main__':
    unittest.main()
