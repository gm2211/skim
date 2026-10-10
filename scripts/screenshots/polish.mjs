#!/usr/bin/env node
// Renders the screens a design pass looks at, each at a fixed viewport and
// device pixel ratio, so two runs can be compared side by side.
//
//   pnpm dev                                   # in another shell
//   node scripts/screenshots/polish.mjs out/   # writes <scene>.png into out/
//
// Env: SKIM_URL (default http://localhost:1420/), CHROME_PATH, SCENES (a
// comma-separated subset of the scene names below), SKIM_MOCK=0 to drive the
// real app over the dev bridge, CATCHUP_WAIT_MS for how long a real run gets.
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs/promises";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.resolve(process.argv[2] || "docs/screenshots/polish");
const URL_ = process.env.SKIM_URL || "http://localhost:1420/";
const ONLY = process.env.SCENES ? new Set(process.env.SCENES.split(",")) : null;

const DESKTOP = { width: 1440, height: 900 };
const TALL = { width: 1440, height: 2400 };

const STILL_CSS = `
  *, *::before, *::after {
    transition-duration: 0s !important;
    animation-duration: 0s !important;
    animation-delay: 0s !important;
    caret-color: transparent !important;
  }
  ::-webkit-scrollbar { width: 0 !important; height: 0 !important; }
`;

const openCatchup = async (p) => {
  await p.locator('[aria-label="Quick Catch-up"]').first().click();
  await p.locator('[role="dialog"]').waitFor({ state: "visible" });
  await p.waitForTimeout(300);
};

const runCatchup = async (p) => {
  await openCatchup(p);
  await p.getByRole("button", { name: /run catch-up/i }).first().click();
  await p.waitForTimeout(Number(process.env.CATCHUP_WAIT_MS ?? 900));
};

/** Lets the dialog grow to its content so one capture shows the whole page. */
const unclip = async (p) => {
  await p.evaluate(() => {
    const dialog = document.querySelector('[role="dialog"]');
    if (!dialog) return;
    dialog.style.maxHeight = "none";
    dialog.style.height = "auto";
    for (const el of dialog.querySelectorAll("*")) {
      const cs = getComputedStyle(el);
      if (cs.overflowY === "auto" || cs.overflowY === "scroll") el.style.overflow = "visible";
    }
  });
  await p.waitForTimeout(200);
};

const SCENES = [
  { name: "catchup-ready", viewport: DESKTOP, run: openCatchup },
  { name: "catchup-page", viewport: DESKTOP, run: runCatchup },
  {
    name: "catchup-page-full",
    viewport: TALL,
    run: async (p) => { await runCatchup(p); await unclip(p); },
    target: '[role="dialog"]',
  },
  {
    name: "catchup-filling",
    viewport: TALL,
    init: () => { window.__SKIM_CATCHUP_WRITTEN__ = 2; },
    run: async (p) => { await runCatchup(p); await unclip(p); },
    target: '[role="dialog"]',
  },
  {
    name: "catchup-reading",
    viewport: DESKTOP,
    init: () => { window.__SKIM_CATCHUP_WRITTEN__ = -1; },
    run: runCatchup,
  },
  { name: "reading", viewport: DESKTOP, run: async (p) => {
    const row = p.getByText("Why “Just Pick AWS” Is Bad Advice in 2026").first();
    await row.click();
    await p.waitForTimeout(600);
  } },
  { name: "today", viewport: DESKTOP, run: async (p) => {
    await p.getByText("Today", { exact: true }).first().click();
    await p.waitForTimeout(800);
  } },
  { name: "palette", viewport: DESKTOP, run: async (p) => {
    await p.keyboard.press("Meta+k");
    await p.waitForTimeout(400);
  } },
  { name: "ask", viewport: DESKTOP, run: async (p) => {
    await p.locator('[aria-label="Ask Skim"]').first().click();
    await p.waitForTimeout(500);
  } },
  { name: "settings", viewport: DESKTOP, run: async (p) => {
    await p.getByText("Settings", { exact: true }).first().click();
    await p.waitForTimeout(600);
  } },
];

const main = async () => {
  await fs.mkdir(OUT, { recursive: true });
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || undefined });
  for (const scene of SCENES) {
    if (ONLY && !ONLY.has(scene.name)) continue;
    const ctx = await browser.newContext({
      viewport: scene.viewport,
      deviceScaleFactor: 2,
      colorScheme: "dark",
      reducedMotion: "reduce",
    });
    const p = await ctx.newPage();
    p.on("pageerror", (e) => console.warn(`  ! ${scene.name}: ${e}`));
    // SKIM_MOCK=0 drives the real app (over the dev bridge) instead of the
    // demo fixtures; the mid-run scenes then show whatever the backend has.
    if (process.env.SKIM_MOCK !== "0") {
      await p.addInitScript({ path: path.join(HERE, "fixtures.js") });
      await p.addInitScript({ path: path.join(HERE, "mock-backend.js") });
      if (scene.init) await p.addInitScript(scene.init);
    }
    await p.goto(URL_, { waitUntil: process.env.SKIM_MOCK === "0" ? "load" : "networkidle" });
    await p.addStyleTag({ content: STILL_CSS });
    await p.waitForTimeout(800);
    const gotIt = p.getByRole("button", { name: /got it/i });
    if (await gotIt.count()) { await gotIt.first().click(); await p.waitForTimeout(300); }
    try {
      await scene.run(p);
      await p.mouse.move(scene.viewport.width - 2, scene.viewport.height - 2);
      await p.waitForTimeout(250);
      const file = path.join(OUT, `${scene.name}.png`);
      if (scene.target) await p.locator(scene.target).first().screenshot({ path: file, animations: "disabled" });
      else await p.screenshot({ path: file, animations: "disabled" });
      console.log(`  ${scene.name}`);
    } catch (e) {
      console.warn(`  ! ${scene.name} failed: ${e.message}`);
    }
    await ctx.close();
  }
  await browser.close();
};

main().catch((e) => { console.error(e); process.exit(1); });
