#!/usr/bin/env node
// Encodes the frames record.mjs captured into the README walkthrough:
//
//   docs/skim-walkthrough.mp4  full resolution, for the docs site and the link
//   docs/skim-walkthrough.gif  what the README shows inline (GitHub does not
//                              play repository video files in a README)
//
// The screencast only emits a frame when the page repaints, so each frame is
// held until the next one's paint time; ffmpeg then resamples that to a
// constant rate.
//
// Requires ffmpeg on PATH, or FFMPEG=/path/to/ffmpeg.
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../..");
const SRC = path.join(ROOT, ".walkthrough");
const FFMPEG = process.env.FFMPEG || "ffmpeg";
const MP4 = path.join(ROOT, "docs/skim-walkthrough.mp4");
const GIF = path.join(ROOT, "docs/skim-walkthrough.gif");

const GIF_W = Number(process.env.GIF_WIDTH || 1100);
const GIF_FPS = Number(process.env.GIF_FPS || 12);

const { stamps, chapters } = JSON.parse(fs.readFileSync(path.join(SRC, "frames.json"), "utf8"));
const end = chapters.at(-1).end;
const lines = ["ffconcat version 1.0"];
stamps.forEach((s, i) => {
  const next = i + 1 < stamps.length ? stamps[i + 1].t : end;
  lines.push(`file frames/${s.file}`, `duration ${Math.max(0.001, next - s.t).toFixed(4)}`);
});
// The concat demuxer ignores the last entry's duration unless it is repeated.
lines.push(`file frames/${stamps.at(-1).file}`);
const list = path.join(SRC, "frames.ffconcat");
fs.writeFileSync(list, lines.join("\n") + "\n");

const run = (args) => execFileSync(FFMPEG, ["-y", "-hide_banner", "-loglevel", "error", ...args], { stdio: "inherit" });
const input = ["-f", "concat", "-safe", "0", "-i", list];

run([...input, "-vf", "fps=30,scale=1920:-2:flags=lanczos,format=yuv420p",
  "-c:v", "libx264", "-preset", "slow", "-crf", "22", "-tune", "animation",
  "-movflags", "+faststart", MP4]);

// One palette for the whole clip so colours don't shift between chapters;
// diff_mode=rectangle only re-dithers what changed, which keeps static UI
// from shimmering and keeps the file small.
run([...input, "-vf",
  `fps=${GIF_FPS},scale=${GIF_W}:-1:flags=lanczos,split[a][b];` +
  `[a]palettegen=max_colors=192:stats_mode=diff[p];` +
  `[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle`,
  "-loop", "0", GIF]);

for (const f of [MP4, GIF]) {
  const mb = (fs.statSync(f).size / 1024 / 1024).toFixed(2);
  console.log(`${path.relative(ROOT, f)}  ${mb} MB`);
}
const secs = end - stamps[0].t;
console.log(`${secs.toFixed(1)}s, ${chapters.length} chapters`);
