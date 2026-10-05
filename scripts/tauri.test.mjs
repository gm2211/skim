// @vitest-environment node
import { mkdirSync, mkdtempSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { freshAppBundles, needsResign } from "./tauri.mjs";

describe("tauri wrapper", () => {
  it("re-signs only finished macOS app builds", () => {
    expect(needsResign(["build"], "darwin")).toBe(true);
    expect(needsResign(["build", "--target", "aarch64-apple-darwin"], "darwin")).toBe(true);
    expect(needsResign(["build", "--no-sign"], "darwin")).toBe(false);
    expect(needsResign(["build", "--no-bundle"], "darwin")).toBe(false);
    expect(needsResign(["dev"], "darwin")).toBe(false);
    expect(needsResign(["ios", "build"], "darwin")).toBe(false);
    expect(needsResign(["build"], "linux")).toBe(false);
  });

  it("finds only bundles written by this build", () => {
    const target = mkdtempSync(join(tmpdir(), "skim-target-"));
    const fresh = join(target, "release", "bundle", "macos", "Skim.app");
    const stale = join(target, "x86_64-apple-darwin", "release", "bundle", "macos", "Skim.app");
    mkdirSync(join(fresh, "Contents", "MacOS"), { recursive: true });
    mkdirSync(stale, { recursive: true });
    const old = new Date(Date.now() - 60_000);
    utimesSync(stale, old, old);
    expect(freshAppBundles(target, Date.now() - 10_000)).toEqual([fresh]);
  });
});
