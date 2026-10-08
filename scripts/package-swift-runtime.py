#!/usr/bin/env python3
"""Bundle Swift compatibility libraries before signing the native helper."""
import subprocess
import sys
from pathlib import Path


def package(app: Path) -> None:
    helper = app / "Contents/MacOS/skim-ai-macos-bridge"
    frameworks = app / "Contents/Frameworks"
    frameworks.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        "xcrun", "swift-stdlib-tool", "--copy", "--platform", "macosx",
        "--scan-executable", str(helper), "--destination", str(frameworks),
    ], check=True)
    commands = subprocess.check_output(["otool", "-l", str(helper)], text=True)
    rpaths = []
    is_rpath = False
    for line in commands.splitlines():
        text = line.strip()
        if text.startswith("cmd "):
            is_rpath = text == "cmd LC_RPATH"
        elif is_rpath and text.startswith("path "):
            rpaths.append(text[5:].rsplit(" (offset ", 1)[0])
            is_rpath = False
    arguments = []
    for rpath in rpaths:
        # SDK toolchains are build dependencies, not installed app dependencies.
        if rpath.startswith("/") and ".xctoolchain/" in rpath:
            arguments.extend(["-delete_rpath", rpath])
    local_path = "@loader_path/../Frameworks"
    if local_path not in rpaths:
        arguments.extend(["-add_rpath", local_path])
    if arguments:
        subprocess.run(["install_name_tool", *arguments, str(helper)], check=True)


if __name__ == "__main__":
    package(Path(sys.argv[1]))
