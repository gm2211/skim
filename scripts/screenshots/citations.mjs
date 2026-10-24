// Captures a chat answer with citation chips and source cards, for the visual check
// before a ship: the Cmd+K palette at rest, with a chip hovered, with a card hovered,
// and the full Ask Skim chat (FULL=1).
//   pnpm dev; OUT=/tmp/cit WIDTHS=1440,640 node scripts/screenshots/citations.mjs
import { chromium } from "playwright";
import path from "node:path";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../..");
const OUT = process.env.OUT || "/tmp/citations";
const URL_ = process.env.SKIM_URL || "http://localhost:1420/";
const STYLES = ["chat"];
const WIDTHS = (process.env.WIDTHS || "1440").split(",").map(Number);

const PATCH = `
(() => {
  const real = window.__TAURI_INTERNALS__.invoke;
  window.__TAURI_INTERNALS__.invoke = async (cmd, args) => {
    if (cmd !== "ask_agent") return real(cmd, args);
    const all = await real("get_articles", { filter: {} });
    const list = (Array.isArray(all) ? all : all.articles || all.items || []).slice(0, 9);
    const sources = list.map((a) => ({ id: a.id, title: a.title, feed_title: a.feed_title, url: a.url, published_at: a.published_at, source_type: "article" }));
    const content = "No major model launch shows up in your feeds this week; the AI coverage is about the data and tooling around models instead. " +
      "Meta has started recording employees' mouse movements and keystrokes to train its models, the most detailed piece on the topic [6]. " +
      "CrabTrap puts a second model in front of production agents to judge each request before it goes out [3], " +
      "and Cal.diy is pitched as an open-source take on a familiar product, built largely with AI help [9][6].";
    await new Promise((r) => setTimeout(r, 200));
    return { content, provider: "anthropic", model: "claude-sonnet-5", sources, article_ids: sources.map((s) => s.id), actions: [],
      steps: [{ tool: "search_articles", label: "Searched for “model release announcement”" }] };
  };
})();`;

const main = async () => {
  await fs.mkdir(OUT, { recursive: true });
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || undefined });
  for (const width of WIDTHS) {
    const ctx = await browser.newContext({ viewport: { width, height: 900 }, deviceScaleFactor: 2, colorScheme: "dark", reducedMotion: "reduce" });
    for (const style of STYLES) {
      const p = await ctx.newPage();
      p.on("pageerror", (e) => console.warn(`! ${style}: ${e}`));
      const catalog = await fs.readFile(path.join(ROOT, "shared/feed-catalog.json"), "utf8");
      await p.addInitScript({ content: `window.__SKIM_CATALOG__ = ${catalog};` });
      await p.addInitScript({ path: path.join(HERE, "fixtures.js") });
      await p.addInitScript({ path: path.join(HERE, "mock-backend.js") });
      await p.addInitScript({ content: PATCH });
      await p.goto(URL_, { waitUntil: "networkidle" });
      await p.waitForTimeout(1200);
      const gotIt = p.getByRole("button", { name: /got it/i });
      if (await gotIt.count()) { await gotIt.first().click(); await p.waitForTimeout(300); }
      await p.keyboard.press("Meta+k");
      await p.waitForTimeout(300);
      await p.keyboard.type("any new model releases?");
      await p.keyboard.press("Shift+Enter");
      await p.waitForSelector(".source-tile", { timeout: 5000 });
      await p.waitForTimeout(300);
      // Hover the second cited item to show the hover state.
      if (process.env.FULL) {
        await p.getByRole("button", { name: /Open full chat/ }).click();
        await p.waitForSelector('[role="dialog"] .source-tile', { timeout: 5000 });
        await p.waitForTimeout(300);
      }
      if (process.env.HOVER === "chip") await p.locator(".cite-chip").nth(1).hover();
      else if (process.env.HOVER === "tile") await p.locator(".source-tile").nth(2).hover();
      else await p.mouse.move(2, 2);
      await p.waitForTimeout(200);
      const dialog = p.locator('[role="dialog"]').last();
      const box = (await dialog.count()) ? await dialog.boundingBox() : null;
      const file = path.join(OUT, `${process.env.FULL ? "full" : "palette"}-${process.env.HOVER || "rest"}-${width}.png`);
      await p.screenshot({ path: file, clip: box || undefined });
      console.log("captured", file);
      await p.close();
    }
    await ctx.close();
  }
  await browser.close();
};
main().catch((e) => { console.error(e); process.exit(1); });
