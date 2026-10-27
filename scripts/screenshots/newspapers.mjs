// Captures Discover's Newspapers shelf for the visual check before a ship: the
// Discover home with the papers list, a subscription paper signed out (NYT) and
// a free paper (Guardian).
//   pnpm dev; OUT=/tmp/newspapers WIDTHS=1440,900,390 node scripts/screenshots/newspapers.mjs
import { chromium } from "playwright";
import path from "node:path";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../..");
const OUT = process.env.OUT || "/tmp/newspapers";
const URL_ = process.env.SKIM_URL || "http://localhost:1420/";
const WIDTHS = (process.env.WIDTHS || "1440").split(",").map(Number);

async function setup(ctx) {
  const p = await ctx.newPage();
  p.on("pageerror", (e) => console.warn(`! ${e}`));
  const catalog = await fs.readFile(path.join(ROOT, "shared/feed-catalog.json"), "utf8");
  const papers = await fs.readFile(path.join(ROOT, "shared/newspapers.json"), "utf8");
  await p.addInitScript({ content: `window.__SKIM_CATALOG__ = ${catalog}; window.__SKIM_NEWSPAPERS__ = ${papers};` });
  await p.addInitScript({ path: path.join(HERE, "fixtures.js") });
  await p.addInitScript({ path: path.join(HERE, "mock-backend.js") });
  await p.goto(URL_, { waitUntil: "networkidle" });
  await p.waitForTimeout(1200);
  const gotIt = p.getByRole("button", { name: /got it/i });
  if (await gotIt.count()) { await gotIt.first().click(); await p.waitForTimeout(300); }
  return p;
}

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

const back = async (p) => {
  await p.locator(".discover-page button", { hasText: /^‹|Back|Discover/ }).first().click().catch(() => p.keyboard.press("Escape"));
  await p.waitForTimeout(400);
};

const main = async () => {
  await fs.mkdir(OUT, { recursive: true });
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || undefined, args: (process.env.CHROME_ARGS || "").split(" ").filter(Boolean) });
  try {
    for (const width of WIDTHS) {
      const ctx = await browser.newContext({ viewport: { width, height: 900 }, deviceScaleFactor: 2, colorScheme: "dark", reducedMotion: "reduce" });
      const p = await setup(ctx);
      await openDiscover(p);
      const shelf = p.locator(".discover-papers").first();
      await shelf.waitFor({ timeout: 5000 });
      await shelf.scrollIntoViewIfNeeded();
      await p.waitForTimeout(300);
      await p.screenshot({ path: `${OUT}/1-discover-${width}.png` });
      await p.locator(".discover-paper", { hasText: "New York Times" }).click();
      await p.getByRole("heading", { name: "The New York Times" }).waitFor();
      await p.waitForTimeout(400);
      await p.screenshot({ path: `${OUT}/2-nyt-${width}.png` });
      await p.screenshot({ path: `${OUT}/2-nyt-full-${width}.png`, fullPage: true });
      await back(p);
      await p.locator(".discover-paper", { hasText: "Guardian" }).click();
      await p.getByRole("heading", { name: "The Guardian" }).waitFor();
      await p.waitForTimeout(400);
      await p.screenshot({ path: `${OUT}/3-guardian-${width}.png` });
      await ctx.close();
      console.log(`captured ${width}`);
    }
  } finally {
    await browser.close();
  }
};
main().catch((e) => { console.error(e); process.exit(1); });
