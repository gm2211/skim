// Captures the reader's AI summary when Claude is rate-limited, for the
// visual check before a ship.
//   pnpm dev; OUT=/tmp/rate-limit WIDTHS=1440,900,390 node scripts/screenshots/rate-limit.mjs
import { chromium } from "playwright";
import path from "node:path";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../..");
const OUT = process.env.OUT || "/tmp/rate-limit";
const URL_ = process.env.SKIM_URL || "http://localhost:1420/";
const WIDTHS = (process.env.WIDTHS || "1440").split(",").map(Number);
const LEAD_TITLE = "Why “Just Pick AWS” Is Bad Advice in 2026";
const CASES = {
  "rate-limit": "Claude has hit your account's rate limit for the moment. Try again in a minute.",
  "plan-limit": "You've reached your Claude plan's usage limit. It resets at 11:40 PM. Claude.ai and Claude Code count toward the same limit.",
};

const main = async () => {
  await fs.mkdir(OUT, { recursive: true });
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || undefined });
  const catalog = await fs.readFile(path.join(ROOT, "shared/feed-catalog.json"), "utf8");
  for (const width of WIDTHS) {
    for (const [name, message] of Object.entries(CASES)) {
      const ctx = await browser.newContext({ viewport: { width, height: 900 }, deviceScaleFactor: 2, colorScheme: "dark", reducedMotion: "reduce" });
      const p = await ctx.newPage();
      p.on("pageerror", (e) => console.warn(`! ${e}`));
      await p.addInitScript({ content: `window.__SKIM_CATALOG__ = ${catalog}; window.__SKIM_SUMMARY_ERROR__ = ${JSON.stringify(message)};` });
      await p.addInitScript({ path: path.join(HERE, "fixtures.js") });
      await p.addInitScript({ path: path.join(HERE, "mock-backend.js") });
      await p.goto(URL_, { waitUntil: "networkidle" });
      await p.waitForTimeout(1200);
      const gotIt = p.getByRole("button", { name: /got it/i });
      if (await gotIt.count()) { await gotIt.first().click(); await p.waitForTimeout(300); }
      if (!(await p.getByText(LEAD_TITLE).first().isVisible())) await p.getByText("All Articles", { exact: true }).first().dispatchEvent("click");
      await p.waitForTimeout(500);
      await p.getByText(LEAD_TITLE).first().dispatchEvent("click");
      await p.locator("h1", { hasText: "Bad Advice in 2026" }).first().waitFor({ state: "visible" });
      await p.waitForTimeout(500);
      await p.getByRole("button", { name: /^summari[sz]e/i }).first().click();
      await p.getByRole("button", { name: "Try again" }).first().waitFor({ state: "visible", timeout: 5000 });
      await p.waitForTimeout(300);
      await p.screenshot({ path: path.join(OUT, `${name}-${width}.png`) });
      console.log("captured", name, width);
      await ctx.close();
    }
  }
  await browser.close();
};

main().catch((e) => { console.error(e); process.exit(1); });
