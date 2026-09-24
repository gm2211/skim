"""Hermetic packaging regression; never builds models or alters real app bundles."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(os.environ.get("BRIDGE_BUILD_SCRIPT", Path(__file__).resolve().parents[1] / "build-macos-bridge.sh"))


class BridgePackagingTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="skim bridge packaging ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.plugin = self.root / "plugin with spaces"
        (self.plugin / "ios").mkdir(parents=True)
        shutil.copyfile(SCRIPT, self.plugin / "build-macos-bridge.sh")
        self.scratch = self.root / "temporary files" / "skim-ai-macos-bridge-build"
        self.current = self.scratch / "out" / "Products" / "Release"
        self.legacy = self.scratch / "arm64-apple-macosx" / "release"
        for directory, marker in [(self.legacy, "STALE"), (self.current, "CURRENT")]:
            directory.mkdir(parents=True)
            (directory / "skim-ai-macos-bridge").write_text(marker)
            bundle = directory / "swift-transformers_Hub.bundle"
            bundle.mkdir()
            (bundle / "marker").write_text(marker)
        metal = self.scratch / "checkouts" / "mlx-swift" / "mlx-generated" / "metal"
        metal.mkdir(parents=True)
        (metal / "kernel.metal").write_text("synthetic")
        self.fake_bin = self.root / "fake tools"
        self.fake_bin.mkdir()
        self.log = self.root / "swift calls.jsonl"
        self.env = dict(os.environ, PATH=f"{self.fake_bin}:{os.environ['PATH']}", TMPDIR=str(self.scratch.parent), TEST_BIN=str(self.current), TEST_LOG=str(self.log))
        self.tool("swift", '''import json, os, sys
with open(os.environ["TEST_LOG"], "a") as log: log.write(json.dumps(sys.argv[1:]) + "\\n")
assert os.environ["SKIM_AI_MAC_BRIDGE_ONLY"] == "1"
assert os.environ["MACOSX_DEPLOYMENT_TARGET"] == "14.0"
if "--show-bin-path" in sys.argv: print(os.environ["TEST_BIN"])
''')
        self.tool("xcrun", '''import pathlib, sys
pathlib.Path(sys.argv[sys.argv.index("-o") + 1]).write_text("synthetic metal output")
''')
        self.tool("codesign", '''import pathlib, sys
assert pathlib.Path(sys.argv[-1]).read_text() == "CURRENT", "stale helper signed"
''')

    def tool(self, name, body):
        path = self.fake_bin / name
        path.write_text("#!/usr/bin/env python3\n" + body)
        path.chmod(0o755)

    def run_script(self):
        return subprocess.run(["sh", str(self.plugin / "build-macos-bridge.sh")], env=self.env, text=True, capture_output=True, timeout=10)

    def test_authoritative_binary_and_resources_win_over_stale_legacy_output(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.plugin / "bin" / "skim-ai-macos-bridge-aarch64-apple-darwin").read_text(), "CURRENT")
        self.assertEqual((self.plugin / "resources" / "swift-transformers_Hub.bundle" / "marker").read_text(), "CURRENT")
        calls = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertEqual(len(calls), 2)
        self.assertNotIn("--show-bin-path", calls[0])
        self.assertIn("--show-bin-path", calls[1])
        self.assertEqual(calls[0], [arg for arg in calls[1] if arg != "--show-bin-path"])
        self.assertIn(str(self.plugin / "ios"), calls[0])
        self.assertIn(str(self.scratch), calls[0])

    def test_missing_current_binary_fails_instead_of_using_legacy(self):
        (self.current / "skim-ai-macos-bridge").unlink()
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.plugin / "bin").exists(), "published stale or partial output")

    def test_missing_current_resources_fails_before_publishing(self):
        shutil.rmtree(self.current / "swift-transformers_Hub.bundle")
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.plugin / "bin").exists(), "published partial output")


if __name__ == "__main__":
    unittest.main()
