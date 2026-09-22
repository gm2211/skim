#!/usr/bin/env node
// Builds docs/skim-demo.gif from the composed frames in
// docs/screenshots/frames.
//
// Every slide gets the same hold and the same crossfade at a fixed frame
// rate. The gif this replaced was a screen recording: its frame delays ranged
// from 70ms to 2.3s, which is why it never looked like it was playing at a
// steady speed.
//
// Requires ffmpeg on PATH (`brew install ffmpeg`), or set FFMPEG to a binary.
//
// Usage: node scripts/screenshots/build-demo.mjs
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../..");
const FRAMES = path.join(ROOT, "docs/screenshots/frames");
const OUT = path.join(ROOT, "docs/skim-demo.gif");

const FFMPEG = process.env.FFMPEG || "ffmpeg";
const FPS = 10; // only the crossfades move, and gif bytes scale with this
const HOLD = 2.6; // seconds a slide is fully visible
const FADE = 0.34; // crossfade length
const COLORS = 160; // 256 costs ~25% more bytes for no visible gain on dark UI

const frames = fs.readdirSync(FRAMES).filter((f) => f.endsWith(".png")).sort();
if (frames.length < 2) throw new Error(`need at least 2 frames in ${FRAMES}`);

/** xfade only chains two streams at a time, so build the ladder. */
function filterGraph(n) {
  const parts = [];
  for (let i = 0; i < n; i++) {
    parts.push(`[${i}:v]settb=AVTB,fps=${FPS},format=rgba[v${i}]`);
  }
  let prev = "[v0]";
  for (let k = 1; k < n; k++) {
    parts.push(
      `${prev}[v${k}]xfade=transition=fade:duration=${FADE}:offset=${(HOLD * k).toFixed(2)}[x${k}]`,
    );
    prev = `[x${k}]`;
  }
  return { graph: parts.join(";"), last: prev };
}

const inputs = frames.flatMap((f) => [
  "-loop", "1",
  "-t", String(HOLD + FADE),
  "-i", path.join(FRAMES, f),
]);
const { graph, last } = filterGraph(frames.length);

// One palette for the whole clip, so colours don't shift between slides.
const palette =
  `${last}split[a][b];` +
  `[a]palettegen=max_colors=${COLORS}:stats_mode=diff[p];` +
  `[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle`;

execFileSync(
  FFMPEG,
  ["-y", "-hide_banner", "-loglevel", "error", ...inputs,
   "-filter_complex", `${graph};${palette}`, "-loop", "0", OUT],
  { stdio: "inherit" },
);

const mb = (fs.statSync(OUT).size / 1024 / 1024).toFixed(2);
console.log(
  `${path.relative(ROOT, OUT)}  ${mb} MB  ` +
  `${frames.length} slides  ${(frames.length * HOLD + FADE).toFixed(1)}s`,
);
