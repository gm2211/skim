// Captures the Auto-organize with AI dialog for the visual check before a ship:
// proposals, a folder being renamed, the rename after a case change, and a re-run.
//   pnpm dev; OUT=/tmp/auto-organize WIDTHS=1440,900,390 node scripts/screenshots/auto-organize.mjs
import { chromium } from "playwright";
import path from "node:path";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../..");
const OUT = process.env.OUT || "/tmp/auto-organize";
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
  await gotIt.first().waitFor({ timeout: 3000 }).catch(() => {});
  if (await gotIt.count()) { await gotIt.first().click(); await p.waitForTimeout(300); }
  return p;
}

const main = async () => {
  await fs.mkdir(OUT, { recursive: true });
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || undefined });
  for (const width of WIDTHS) {
    const ctx = await browser.newContext({ viewport: { width, height: 900 }, deviceScaleFactor: 2, colorScheme: "dark", reducedMotion: "reduce" });
    const p = await setup(ctx);
    const shot = async (name) => {
      const file = path.join(OUT, `${name}-${width}.png`);
      await p.screenshot({ path: file });
      console.log("captured", file);
    };
    // Narrow layouts tuck the sidebar behind the menu button.
    if (width < 700) { await p.mouse.click(34, 26); await p.waitForTimeout(500); }
    await p.locator('[aria-label="Folders"]').first().evaluate((el) => el.click());
    await p.waitForTimeout(200);
    await p.getByText("Auto-organize with AI").last().evaluate((el) => el.click());
    await p.waitForTimeout(300);
    await shot("0-open");
    await p.getByRole("button", { name: /Run/ }).click();
    await p.waitForTimeout(800);
    await shot("1-proposals");

    const name = p.getByLabel("Folder name", { exact: true }).first();
    await name.hover();
    await shot("2-hover");
    await name.fill("Dev blogs & essays");
    await shot("3-renaming");

    await p.getByLabel("Folder name case").selectOption("kebab");
    await p.waitForTimeout(200);
    await shot("4-kebab-keeps-rename");

    await p.getByRole("button", { name: /Re-run/ }).click();
    await p.waitForTimeout(800);
    await shot("5-rerun-keeps-rename");
    console.log("names after re-run:", await p.getByLabel("Folder name", { exact: true }).evaluateAll((els) => els.map((e) => e.value)));
    await ctx.close();
  }
  await browser.close();
};

main().catch((e) => { console.error(e); process.exit(1); });
