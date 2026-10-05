#!/usr/bin/env node
// `pnpm tauri …` entry point. Forwards to the Tauri CLI, then, after a macOS
// `build`, re-signs the bundle with scripts/sign-macos.sh. Tauri signs the
// on-device AI helper and DS4 server with the app's own sandbox entitlements;
// a sandboxed parent cannot launch a child that asks for its own sandbox, so
// the helper dies at launch and on-device MLX reports itself unavailable. The
// signing script gives helpers sandbox inheritance and adds the Metal library
// and SwiftPM resource aliases MLX needs beside the executable.
import { spawnSync } from "node:child_process";
import { existsSync, readdirSync, statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const projectDir = join(dirname(fileURLToPath(import.meta.url)), "..");
const args = process.argv.slice(2);

/// Bundles under src-tauri/target written at or after `since` (ms).
export function freshAppBundles(targetDir, since) {
  const found = [];
  const visit = (dir, depth) => {
    if (depth > 4 || !existsSync(dir)) return;
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      if (!entry.isDirectory()) continue;
      const path = join(dir, entry.name);
      if (entry.name.endsWith(".app") && dir.endsWith(join("bundle", "macos"))) {
        if (statSync(path).mtimeMs >= since) found.push(path);
      } else if (!entry.name.endsWith(".app")) {
        visit(path, depth + 1);
      }
    }
  };
  visit(targetDir, 0);
  return found;
}

export function needsResign(argv, platform) {
  return (
    platform === "darwin" &&
    argv[0] === "build" &&
    !argv.includes("--no-sign") &&
    !argv.includes("--no-bundle")
  );
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  // Coarse mtime resolution can round a fresh bundle just below the start time.
  const started = Date.now() - 2000;
  const cli = spawnSync("tauri", args, { stdio: "inherit", cwd: projectDir, shell: process.platform === "win32" });
  if (cli.status !== 0 || !needsResign(args, process.platform)) {
    process.exit(cli.status ?? 1);
  }
  const bundles = freshAppBundles(join(projectDir, "src-tauri", "target"), started);
  if (bundles.length === 0) {
    console.error("tauri build finished but no fresh Skim.app was found to re-sign.");
    process.exit(1);
  }
  for (const app of bundles) {
    console.log(`Re-signing ${app} so the on-device AI helper inherits the sandbox`);
    const sign = spawnSync("sh", [join(projectDir, "scripts", "sign-macos.sh"), app], { stdio: "inherit" });
    if (sign.status !== 0) process.exit(sign.status ?? 1);
  }
}
