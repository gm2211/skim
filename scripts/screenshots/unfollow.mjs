// Captures unfollowing a feed for the visual check before a ship: Discover's
// Following button at rest and on hover, its confirmation, and the feed menu.
//   pnpm dev; OUT=/tmp/unfollow WIDTHS=1440,900,390 node scripts/screenshots/unfollow.mjs
import { chromium } from "playwright";
import path from "node:path";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../..");
const OUT = process.env.OUT || "/tmp/unfollow";
const URL_ = process.env.SKIM_URL || "http://localhost:1420/";
const WIDTHS = (process.env.WIDTHS || "1440").split(",").map(Number);

async function setup(ctx) {
  const p = await ctx.newPage();
  p.on("pageerror", (e) => console.warn(`! ${e}`));
  const catalog = await fs.readFile(path.join(ROOT, "shared/feed-catalog.json"), "utf8");
  await p.addInitScript({ content: `window.__SKIM_CATALOG__ = ${catalog};` });
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

const main = async () => {
  await fs.mkdir(OUT, { recursive: true });
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || undefined });
  for (const width of WIDTHS) {
    const ctx = await browser.newContext({ viewport: { width, height: 900 }, deviceScaleFactor: 2, colorScheme: "dark", reducedMotion: "reduce" });
    const p = await setup(ctx);
    await openDiscover(p);
    await p.getByRole("textbox", { name: /paste a website/ }).fill("hacker news");
    const following = p.getByRole("button", { name: /^Unfollow / }).first();
    await following.waitFor({ timeout: 5000 });
    await following.scrollIntoViewIfNeeded();
    await p.mouse.move(0, 0);
    await p.waitForTimeout(300);
    await p.screenshot({ path: `${OUT}/1-following-${width}.png` });
    await following.hover();
    await p.waitForTimeout(200);
    await p.screenshot({ path: `${OUT}/2-hover-${width}.png` });
    await following.click();
    await p.getByRole("dialog").waitFor();
    await p.waitForTimeout(200);
    await p.screenshot({ path: `${OUT}/3-confirm-${width}.png` });
    await p.getByRole("button", { name: "Unfollow", exact: true }).click();
    await p.waitForTimeout(600);
    await p.mouse.move(0, 0);
    await p.screenshot({ path: `${OUT}/4-unfollowed-${width}.png` });
    await ctx.close();
    console.log("captured", width);
  }
  await browser.close();
};

main().catch((e) => { console.error(e); process.exit(1); });
