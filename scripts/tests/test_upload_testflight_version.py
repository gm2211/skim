"""Check which version upload-testflight.sh picks, stopping before any Xcode work."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FILES = ['scripts/upload-testflight.sh', 'scripts/bump-version.sh', 'native/SkimNative/project.yml',
         'native/SkimNative/SkimNative.xcodeproj/project.pbxproj', 'src-tauri/tauri.conf.json']


class UploadVersionTests(unittest.TestCase):
    def run_upload(self, commit_subject, **env):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            for name in FILES:
                (base/name).parent.mkdir(parents=True, exist_ok=True)
                shutil.copy(ROOT/name, base/name)
            git = lambda *a: subprocess.run(['git', '-C', str(base), *a], check=True, capture_output=True)
            git('init', '-q')
            git('add', '-A')
            git('-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qm', commit_subject)
            tools = base/'tools'
            tools.mkdir()
            for tool in ['xcodebuild', 'xcodegen']:
                (tools/tool).write_text('#!/bin/sh\nexit 7\n')
                (tools/tool).chmod(0o755)
            key = base/'key.p8'
            key.write_text('fake')
            result = subprocess.run(['bash', str(base/FILES[0])], capture_output=True, text=True, env={
                **os.environ, 'PATH': str(tools)+os.pathsep+os.environ['PATH'], 'ASC_KEY_ID': 'k',
                'ASC_ISSUER_ID': 'i', 'ASC_KEY_PATH': str(key), **env})
            return result.stdout + result.stderr

    def current(self):
        spec = (ROOT/FILES[2]).read_text()
        return (re.search(r'MARKETING_VERSION: (\S+)', spec).group(1),
                int(re.search(r'CURRENT_PROJECT_VERSION: (\d+)', spec).group(1)))

    def test_committed_bump_uploads_as_is(self):
        version, build = self.current()
        out = self.run_upload(f'Ship {version}')
        self.assertIn(f'-> {version}/{build}', out)

    def test_unbumped_head_bumps_once(self):
        version, build = self.current()
        out = self.run_upload('Some feature')
        self.assertIn(f'-> ', out)
        self.assertNotIn(f'-> {version}/{build}', out)
        self.assertRegex(out, rf'-> \d+\.\d+\.\d+/{build + 1}\b')

    def test_explicit_build_number_with_same_version_is_refused(self):
        version, build = self.current()
        out = self.run_upload('Some feature', SKIM_BUILD_NUMBER=str(build + 1))
        self.assertIn('unchanged version', out)


if __name__ == '__main__':
    unittest.main()
