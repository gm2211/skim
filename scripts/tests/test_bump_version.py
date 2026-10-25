"""Check that bump-version.sh moves iOS and macOS to one new version and bumps both builds."""
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
FILES = ['scripts/bump-version.sh', 'native/SkimNative/project.yml',
         'native/SkimNative/SkimNative.xcodeproj/project.pbxproj', 'src-tauri/tauri.conf.json']


class BumpVersionTests(unittest.TestCase):
    def copy_tree(self, base):
        for name in FILES:
            (base/name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(ROOT/name, base/name)

    def metadata(self, base):
        spec = (base/FILES[1]).read_text()
        pbx = (base/FILES[2]).read_text()
        config = json.loads((base/FILES[3]).read_text())
        return (set(re.findall(r'MARKETING_VERSION: (\S+)', spec)),
                set(re.findall(r'CURRENT_PROJECT_VERSION: (\d+)', spec)),
                set(re.findall(r'MARKETING_VERSION = ([^;]+);', pbx)),
                set(re.findall(r'CURRENT_PROJECT_VERSION = (\d+);', pbx)),
                config['version'], config['bundle']['macOS']['bundleVersion'])

    def test_default_bump_shares_next_patch_and_bumps_builds(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            self.copy_tree(base)
            ios_v, ios_b, _, _, mac_v, mac_b = self.metadata(base)
            subprocess.run(['bash', str(base/FILES[0])], check=True, capture_output=True)
            new_ios_v, new_ios_b, pbx_v, pbx_b, new_mac_v, new_mac_b = self.metadata(base)
            highest = max(tuple(map(int, v.split('.'))) for v in [*ios_v, mac_v])
            expected = f'{highest[0]}.{highest[1]}.{highest[2] + 1}'
            self.assertEqual(new_ios_v, {expected})
            self.assertEqual(pbx_v, {expected})
            self.assertEqual(new_mac_v, expected)
            self.assertEqual(new_ios_b, {str(int(next(iter(ios_b))) + 1)})
            self.assertEqual(pbx_b, new_ios_b)
            self.assertEqual(new_mac_b, str(int(mac_b) + 1))

    def test_rejects_version_that_does_not_go_up(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            self.copy_tree(base)
            before = self.metadata(base)
            result = subprocess.run(['bash', str(base/FILES[0]), '0.0.1'], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.metadata(base), before)


if __name__ == '__main__':
    unittest.main()
