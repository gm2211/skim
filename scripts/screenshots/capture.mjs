#!/usr/bin/env node
// Captures the stills the docs site carousel shows (docs/index.html).
//
// Every still comes out of the same browser at the same viewport and device
// pixel ratio, so the slides share one zoom level and one crop — which is the
// whole point: hand-taken screenshots of different window sizes are what made
// the old carousel look like a ransom note. The README's video comes from
// record.mjs instead.
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

/** Each step drives the app to one screen, then the still is captured. */
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
    name: "03-today",
    caption: "Today — your feeds as one front page, a week per page turned",
    async run(p) {
      await p.getByText("Today", { exact: true }).first().click();
      await p.locator('[aria-label="Newspaper pages"]').waitFor({ state: "visible" });
      await p.waitForTimeout(900);
    },
  },
  {
    name: "04-ask",
    caption: "Ask Skim — chat across every feed, with citations",
    async run(p) {
      await p.locator('[aria-label="Ask Skim"]').first().click();
      await p.waitForTimeout(500);
      const box = p.locator("textarea, input[type=text]").last();
      await box.fill("Did anything change in Claude Code pricing?");
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
  const browser = await chromium.launch({
    executablePath: process.env.CHROME_PATH || undefined,
  });
  const ctx = await browser.newContext({
    viewport: VIEWPORT,
    deviceScaleFactor: SCALE,
    colorScheme: "dark",
    reducedMotion: "reduce",
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
    await p.screenshot({ path: file, animations: "disabled" });
    await p.close();
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
