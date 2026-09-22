#!/usr/bin/env node
// Captures the README demo frames.
//
// Every frame comes out of the same browser at the same viewport and device
// pixel ratio, so the slides share one zoom level and one crop — which is the
// whole point: hand-taken screenshots of different window sizes are what made
// the old carousel look like a ransom note.
//
// Usage:
//   pnpm dev            # in another shell, or set SKIM_URL to a preview server
//   node scripts/screenshots/capture.mjs
//
// Env:
//   SKIM_URL      app URL (default http://localhost:1420/)
//   CHROME_PATH   explicit Chromium binary, for sandboxes with a preinstalled one
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs/promises";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../..");
const OUT = path.join(ROOT, "docs/screenshots");
const FRAMES = path.join(OUT, "frames");

export const VIEWPORT = { width: 1440, height: 900 };
export const SCALE = 2;

const URL_ = process.env.SKIM_URL || "http://localhost:1420/";

// Kill transitions so a capture never lands mid-animation, and hide
// scrollbars so panes don't shift width between frames.
const DETERMINISTIC_CSS = `
  *, *::before, *::after {
    transition-duration: 0s !important;
    animation-duration: 0s !important;
    animation-delay: 0s !important;
    caret-color: transparent !important;
  }
  ::-webkit-scrollbar { width: 0 !important; height: 0 !important; }
`;

const LEAD_TITLE = "Why \u201cJust Pick AWS\u201d Is Bad Advice in 2026";

/** Opens the lead article in the reader pane. Several frames start here. */
const openLeadArticle = async (p) => {
  const row = p.getByText(LEAD_TITLE).first();
  await row.waitFor({ state: "visible" });
  await row.click();
  // The reader renders the title as an <h1>; waiting on it keeps the capture
  // from racing the list's re-render.
  await p.locator("h1", { hasText: "Bad Advice in 2026" }).first().waitFor({ state: "visible" });
  await p.waitForTimeout(500);
};

/** Each step drives the app to one screen, then the frame is captured. */
const STEPS = [
  {
    name: "00-reading",
    caption: "Read your feeds — sidebar, list, and article in one window",
    run: openLeadArticle,
  },
  {
    name: "01-summarize",
    caption: "Summarize any article without leaving the reader",
    async run(p) {
      await openLeadArticle(p);
      await p.locator('[aria-label="Summarize"]').first().click();
      await p.waitForTimeout(1200);
    },
  },
  {
    name: "02-triage",
    caption: "AI Inbox — every unread article scored 1 to 5",
    async run(p) {
      await p.getByText("AI Inbox", { exact: true }).first().click();
      await p.waitForTimeout(900);
      await openLeadArticle(p);
    },
  },
  {
    name: "03-catchup",
    caption: "Super-quick catch-up — the week in ten takeaways",
    async run(p) {
      await p.locator('[title="Super-quick catch-up"]').first().click();
      await p.waitForTimeout(500);
      await p.getByRole("button", { name: /run catch-up/i }).first().click();
      await p.waitForTimeout(1500);
    },
  },
  {
    name: "04-ask",
    caption: "Ask Skim — chat across every feed, with citations",
    async run(p) {
      await p.locator('[aria-label="Ask Skim"]').first().click();
      await p.waitForTimeout(500);
      const box = p.locator("textarea, input[type=text]").last();
      await box.fill("What broke in security this week?");
      await box.press("Enter");
      await p.waitForTimeout(1500);
      // The transcript auto-scrolls to the composer; show the answer instead.
      await p.evaluate(() => {
        const scrollers = Array.from(document.querySelectorAll("*")).filter(
          (el) => el.scrollHeight > el.clientHeight + 40 && el.clientHeight > 180,
        );
        for (const el of scrollers) el.scrollTop = 0;
      });
      await p.waitForTimeout(400);
    },
  },
  {
    name: "05-organize",
    caption: "Auto-organize — the model files your feeds into folders",
    async run(p) {
      await p.locator('[title="Add folder or smart folder"]').first().click();
      await p.waitForTimeout(300);
      await p.getByText("Auto-organize with AI").first().click();
      await p.waitForTimeout(500);
      await p.getByRole("button", { name: /Run$/ }).first().click();
      await p.waitForTimeout(1500);
    },
  },
];

// Final frame geometry. The app shot is downscaled to FRAME_W with a caption
// strip underneath, so every frame in the demo is pixel-identical in size.
export const FRAME_W = 1600;
export const FRAME_H = Math.round((FRAME_W * VIEWPORT.height) / VIEWPORT.width);
export const CAPTION_H = 64;

/**
 * Composes one demo frame: the app screenshot over a caption strip. Done in
 * the browser so the caption uses real font rendering instead of whatever
 * fonts happen to exist on the machine running ffmpeg.
 */
async function compose(composeCtx, shot, caption, outFile) {
  const page = await composeCtx.newPage();
  await page.setContent(`<!doctype html><meta charset="utf-8"><style>
    html, body { margin: 0; background: #06080c; }
    body { width: ${FRAME_W}px; height: ${FRAME_H + CAPTION_H}px; overflow: hidden;
      font: 500 24px/1 -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; }
    img { display: block; width: ${FRAME_W}px; height: ${FRAME_H}px; }
    .cap { height: ${CAPTION_H}px; display: flex; align-items: center; justify-content: center;
      color: #d7dde7; letter-spacing: 0.2px; border-top: 1px solid rgba(255,255,255,0.07); }
  </style>
  <img src="data:image/png;base64,${shot.toString("base64")}">
  <div class="cap">${caption.replace(/&/g, "&amp;").replace(/</g, "&lt;")}</div>`);
  await page.waitForTimeout(250);
  await page.screenshot({ path: outFile });
  await page.close();
}

async function freshPage(ctx) {
  const p = await ctx.newPage();
  await p.addInitScript({ path: path.join(HERE, "fixtures.js") });
  await p.addInitScript({ path: path.join(HERE, "mock-backend.js") });
  await p.goto(URL_, { waitUntil: "networkidle" });
  await p.addStyleTag({ content: DETERMINISTIC_CSS });
  await p.waitForTimeout(1200);
  const gotIt = p.getByRole("button", { name: /got it/i });
  if (await gotIt.count()) {
    await gotIt.first().click();
    await p.waitForTimeout(400);
  }
  return p;
}

const main = async () => {
  await fs.mkdir(OUT, { recursive: true });
  await fs.mkdir(FRAMES, { recursive: true });
  const browser = await chromium.launch({
    executablePath: process.env.CHROME_PATH || undefined,
  });
  const ctx = await browser.newContext({
    viewport: VIEWPORT,
    deviceScaleFactor: SCALE,
    colorScheme: "dark",
    reducedMotion: "reduce",
  });
  // Composing runs at DPR 1 so the 2x app shot is downscaled into the frame
  // rather than stretched back up.
  const composeCtx = await browser.newContext({
    viewport: { width: FRAME_W, height: FRAME_H + CAPTION_H },
    deviceScaleFactor: 1,
    colorScheme: "dark",
  });

  const captions = {};
  for (const step of STEPS) {
    // A fresh page per frame: no leftover dialog or scroll position from the
    // previous screen can leak into the next capture.
    const p = await freshPage(ctx);
    p.on("pageerror", (e) => console.warn(`  ! ${step.name}: ${e}`));
    await step.run(p);
    // Park the pointer off-canvas so no row is left in a hover state.
    await p.mouse.move(VIEWPORT.width - 2, VIEWPORT.height - 2);
    await p.waitForTimeout(250);
    const file = path.join(OUT, `${step.name}.png`);
    const shot = await p.screenshot({ path: file, animations: "disabled" });
    await p.close();
    await compose(composeCtx, shot, step.caption, path.join(FRAMES, `${step.name}.png`));
    captions[`${step.name}.png`] = step.caption;
    console.log(`captured ${step.name}.png`);
  }

  await fs.writeFile(
    path.join(OUT, "captions.json"),
    JSON.stringify({ viewport: VIEWPORT, scale: SCALE, captions }, null, 2) + "\n",
  );
  await browser.close();
};

await main();
