import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "package_swift_runtime", Path(__file__).with_name("package-swift-runtime.py")
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PackagingTests(unittest.TestCase):
    def test_embeds_runtime_and_removes_build_machine_paths(self):
        output = """cmd LC_RPATH
cmdsize 32
path /usr/lib/swift (offset 12)
cmd LC_RPATH
path @loader_path (offset 12)
cmd LC_RPATH
path /var/run/Metal.xctoolchain/usr/lib/swift-6.2/macosx (offset 12)
cmd LC_RPATH
path /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx (offset 12)
"""
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(module.subprocess, "run") as run, \
                patch.object(module.subprocess, "check_output", return_value=output):
            app = Path(directory) / "Skim.app"
            module.package(app)
            self.assertTrue((app / "Contents/Frameworks").is_dir())
            copy = run.call_args_list[0].args[0]
            self.assertEqual(copy[:4], ["xcrun", "swift-stdlib-tool", "--copy", "--platform"])
            self.assertIn(str(app / "Contents/Frameworks"), copy)
            edits = run.call_args_list[1].args[0]
            self.assertIn("@loader_path/../Frameworks", edits)
            self.assertNotIn("/usr/lib/swift", edits)
            self.assertNotIn("@loader_path", edits)
            self.assertEqual(edits.count("-delete_rpath"), 2)

    def test_packaged_helper_is_not_modified_again(self):
        output = "cmd LC_RPATH\npath @loader_path/../Frameworks (offset 12)\n"
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(module.subprocess, "run") as run, \
                patch.object(module.subprocess, "check_output", return_value=output):
            module.package(Path(directory) / "Skim.app")
            self.assertEqual(run.call_count, 1)

    def test_copy_failure_stops_before_helper_load_paths_change(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(module.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "xcrun")), \
                patch.object(module.subprocess, "check_output") as read:
            with self.assertRaises(subprocess.CalledProcessError):
                module.package(Path(directory) / "Skim.app")
            read.assert_not_called()


if __name__ == "__main__":
    unittest.main()
