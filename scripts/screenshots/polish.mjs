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

const openToday = async (p) => {
  await p.getByText("Today", { exact: true }).first().click();
  await p.waitForTimeout(800);
};

/** Turns the paper back `turns` pages (a week each). */
const turnBack = async (p, turns = 1) => {
  for (let i = 0; i < turns; i++) await p.keyboard.press("ArrowRight");
  await p.waitForTimeout(600);
};

/** Lets the page grow to its content so one capture shows the whole thing. */
const unclip = async (p, selector = ".today-page") => {
  await p.evaluate((selector) => {
    const dialog = document.querySelector(selector);
    if (!dialog) return;
    dialog.style.maxHeight = "none";
    dialog.style.height = "auto";
    for (const el of [dialog, ...dialog.querySelectorAll("*")]) {
      const cs = getComputedStyle(el);
      if (cs.overflowY === "auto" || cs.overflowY === "scroll" || cs.overflow === "hidden") el.style.overflow = "visible";
    }
    for (const el of document.querySelectorAll("#root, #root > *, #root > * > *")) {
      el.style.height = "auto";
      el.style.minHeight = "0";
      el.style.overflow = "visible";
    }
  }, selector);
  await p.waitForTimeout(200);
};

const openDiscover = async (p) => {
  const button = p.locator('[aria-label="Add feed"]:visible').first();
  const opened = (await button.count()) && (await button.click({ timeout: 2000 }).then(() => true, () => false));
  if (!opened) {
    await p.keyboard.press("Meta+k");
    await p.keyboard.type("Add feed");
    await p.keyboard.press("Enter");
  }
  await p.locator(".discover-page").first().waitFor();
  await p.waitForTimeout(600);
};

const SCENES = [
  { name: "today", viewport: DESKTOP, run: openToday },
  // The same paper over a wider window, picked from the cog.
  { name: "today-page-2", viewport: DESKTOP, run: async (p) => { await openToday(p); await turnBack(p, 1); } },
  { name: "today-full", viewport: TALL, run: async (p) => { await openToday(p); await unclip(p); }, target: ".today-page" },
  // The foot of the page, where the paper turns.
  { name: "today-foot", viewport: DESKTOP, run: async (p) => { await openToday(p); await turnBack(p, 1); }, clip: { x: 440, y: 820, width: 1000, height: 80 } },
  // The page stays in the list column while a story's article is open.
  { name: "today-article", viewport: DESKTOP, run: async (p) => {
    await openToday(p);
    await p.locator(".today-page .today-headline").first().click();
    await p.waitForTimeout(700);
  } },
  // A narrow window: the reader toolbar folds its lesser actions into "…".
  { name: "reading-narrow", viewport: { width: 1000, height: 760 }, run: async (p) => {
    const row = p.getByText("Why “Just Pick AWS” Is Bad Advice in 2026").first();
    await row.click();
    await p.waitForTimeout(600);
    if (process.env.DEBUG_TOOLBAR) console.log(await p.evaluate(() => {
      const r = document.querySelector('[aria-label="Article reader"]');
      return { reader: r?.getBoundingClientRect().width, toolbar: r?.firstElementChild?.getBoundingClientRect().width, more: !!document.querySelector('[aria-label="More actions"]') };
    }));
    await p.getByRole("button", { name: "More actions" }).click();
    await p.waitForTimeout(300);
  } },
  { name: "reading", viewport: DESKTOP, run: async (p) => {
    const row = p.getByText("Why “Just Pick AWS” Is Bad Advice in 2026").first();
    await row.click();
    await p.waitForTimeout(600);
  } },
  // The cog popovers, so overflow, wrapping and contrast get a look before a ship.
  { name: "today-cog", viewport: DESKTOP, run: async (p) => {
    await openToday(p);
    await p.getByRole("button", { name: "Today settings" }).click();
    await p.waitForTimeout(300);
  }, clip: { x: 1000, y: 0, width: 440, height: 460 } },
  { name: "chat-cog", viewport: DESKTOP, run: async (p) => {
    await p.locator('[aria-label="Ask Skim"]').first().click();
    await p.waitForTimeout(500);
    await p.getByRole("button", { name: "Chat settings" }).click();
    await p.waitForTimeout(300);
  } },
  { name: "palette", viewport: DESKTOP, run: async (p) => {
    await p.keyboard.press("Meta+k");
    await p.waitForTimeout(400);
  } },
  { name: "ask", viewport: DESKTOP, run: async (p) => {
    await p.locator('[aria-label="Ask Skim"]').first().click();
    await p.waitForTimeout(500);
  } },
  // Discover: browse topics, open a topic, open a feed's page, find a site's feeds.
  { name: "discover", viewport: DESKTOP, run: openDiscover },
  { name: "discover-topic", viewport: DESKTOP, run: async (p) => {
    await openDiscover(p);
    await p.locator(".discover-card").first().click();
    await p.waitForTimeout(500);
  } },
  { name: "discover-feed", viewport: DESKTOP, run: async (p) => {
    await openDiscover(p);
    await p.locator(".discover-card").first().click();
    await p.getByRole("button", { name: /^Ars Technica,/ }).click();
    await p.getByRole("button", { name: "Follow Ars Technica" }).click();
    await p.waitForTimeout(900);
  } },
  { name: "discover-site", viewport: DESKTOP, run: async (p) => {
    await openDiscover(p);
    await p.getByRole("textbox", { name: /paste a website/ }).fill("theverge.com");
    await p.getByText("3 feeds found").waitFor();
    await p.getByRole("button", { name: "Follow The Verge: Tech" }).click();
    await p.waitForTimeout(700);
  } },
  { name: "discover-search", viewport: DESKTOP, run: async (p) => {
    await openDiscover(p);
    await p.getByRole("textbox", { name: /paste a website/ }).fill("rust");
    await p.getByText("Rust Blog").first().waitFor();
    await p.waitForTimeout(300);
  } },
  { name: "discover-narrow", viewport: { width: 1000, height: 760 }, run: openDiscover },
  { name: "discover-phone", viewport: { width: 390, height: 844 }, run: openDiscover },
  { name: "discover-phone-feed", viewport: { width: 390, height: 844 }, run: async (p) => {
    await openDiscover(p);
    await p.locator(".discover-card").first().click();
    await p.getByRole("button", { name: /^The Verge,/ }).click();
    await p.waitForTimeout(800);
  } },
  { name: "import-dialog", viewport: DESKTOP, run: async (p) => {
    await openDiscover(p);
    await p.getByRole("button", { name: "Import OPML" }).click();
    await p.waitForTimeout(400);
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
      await p.addInitScript({ content: `window.__SKIM_CATALOG__ = ${await fs.readFile(path.join(path.resolve(HERE, "../.."), "shared/feed-catalog.json"), "utf8")};` });
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
      else if (scene.clip) await p.screenshot({ path: file, animations: "disabled", clip: scene.clip });
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
