"""Exercise release rejection and temporary credential cleanup without Apple access."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/upload-macos-testflight.sh'


class MacTestFlightTests(unittest.TestCase):
    def run_release(self, *, wrong_metadata=False, export_exit=9):
        with tempfile.TemporaryDirectory(prefix='skim-mac-upload-test-') as folder:
            base = Path(folder)
            app = base / 'Skim.app'
            (app / 'Contents/MacOS').mkdir(parents=True)
            config = json.loads((ROOT / 'src-tauri/tauri.conf.json').read_text())
            metadata = {
                'CFBundleIdentifier': config['identifier'],
                'CFBundleShortVersionString': '0.0.0' if wrong_metadata else config['version'],
                'CFBundleVersion': config['bundle']['macOS']['bundleVersion'],
            }
            with (app / 'Contents/Info.plist').open('wb') as output:
                plistlib.dump(metadata, output)
            fake_secret = 'FAKE_SECRET_NOT_A_REAL_APPLE_KEY'
            key = base / 'original-key.p8'
            key.write_text(fake_secret)
            key.chmod(0o600)
            tools = base / 'tools'
            tools.mkdir()
            codesign = tools / 'codesign'
            codesign.write_text('#!/bin/sh\nexit 0\n')
            codesign.chmod(0o755)
            xcode = tools / 'xcodebuild'
            xcode.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
key = pathlib.Path(sys.argv[sys.argv.index('-authenticationKeyPath')+1])
record = {'args': sys.argv, 'key_path': str(key),
          'key_mode': key.stat().st_mode & 0o777,
          'dir_mode': key.parent.stat().st_mode & 0o777}
pathlib.Path(os.environ['TEST_RECORD']).write_text(json.dumps(record))
sys.exit(int(os.environ['TEST_EXPORT_EXIT']))
''')
            xcode.chmod(0o755)
            record_file = base / 'record.json'
            env = {**os.environ, 'PATH': str(tools)+os.pathsep+os.environ['PATH'],
                   'ASC_KEY_ID': 'fake-public-id', 'ASC_ISSUER_ID': 'fake-issuer',
                   'ASC_KEY_PATH': str(key), 'SKIM_TESTFLIGHT_ENV_FILE': str(base/'absent.env'),
                   'SKIM_MAC_TESTFLIGHT_OUTPUT': str(base/'output'),
                   'TEST_RECORD': str(record_file), 'TEST_EXPORT_EXIT': str(export_exit)}
            result = subprocess.run(['bash', str(SCRIPT), str(app)], env=env,
                                    capture_output=True, text=True)
            self.assertNotIn(fake_secret, result.stdout + result.stderr)
            record = json.loads(record_file.read_text()) if record_file.exists() else None
            if record:
                self.assertNotIn(fake_secret, ' '.join(record['args']))
                self.assertEqual(record['key_mode'], 0o600)
                self.assertEqual(record['dir_mode'], 0o700)
                self.assertFalse(Path(record['key_path']).parent.exists())
            self.assertTrue(key.exists(), 'Original credential must remain untouched')
            return result, record

    def test_wrong_metadata_stops_before_signing_or_authentication(self):
        result, record = self.run_release(wrong_metadata=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Bundle metadata mismatch', result.stderr)
        self.assertIsNone(record)

    def test_export_failure_cleans_owner_only_authentication_copy(self):
        result, record = self.run_release()
        self.assertEqual(result.returncode, 9)
        self.assertIsNotNone(record)

    def test_missing_package_stops_upload_and_cleans_authentication(self):
        result, record = self.run_release(export_exit=0)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no Mac installer package', result.stdout)
        self.assertIsNotNone(record)


if __name__ == '__main__':
    unittest.main()
