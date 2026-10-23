// Design mock captures for the cited-item styles in the Cmd+K answer.
import { chromium } from "playwright";
import path from "node:path";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../..");
const OUT = process.env.OUT || "/tmp/citations";
const URL_ = process.env.SKIM_URL || "http://localhost:1420/";
const STYLES = (process.env.STYLES || "row,headline,card,gutter").split(",");
const WIDTHS = (process.env.WIDTHS || "1440").split(",").map(Number);

const PATCH = `
(() => {
  const real = window.__TAURI_INTERNALS__.invoke;
  window.__TAURI_INTERNALS__.invoke = async (cmd, args) => {
    if (cmd !== "ask_agent") return real(cmd, args);
    const all = await real("get_articles", { filter: {} });
    const list = (Array.isArray(all) ? all : all.articles || all.items || []).slice(0, 9);
    const sources = list.map((a) => ({ id: a.id, title: a.title, feed_title: a.feed_title, url: a.url, published_at: a.published_at, source_type: "article" }));
    const t = (i) => sources[i - 1].title;
    const content = "Based on your articles, here are the recent ones on AI tooling:\\n\\n" +
      "[6] **" + t(6) + "** - The most detailed piece, with benchmarks and a walkthrough (Oct 22)\\n\\n" +
      "[3] **" + t(3) + "** - Mentioned in passing; reportedly the change tried to work around its own test scores\\n\\n" +
      "[9] **" + t(9) + "** - A shorter take with enhanced control over the rollout (Oct 22)\\n\\n" +
      "The most detailed coverage is [6]. Would you like me to read any of these for more details?";
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
      await p.addInitScript({ content: `window.__SKIM_CATALOG__ = ${catalog}; try { localStorage.setItem("skim.citationStyle", ${JSON.stringify(style)}); } catch {}` });
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
      await p.waitForSelector(".cited-item", { timeout: 5000 });
      await p.waitForTimeout(300);
      // Hover the second cited item to show the hover state.
      await p.locator(".cited-item").nth(1).hover();
      await p.waitForTimeout(200);
      const dialog = p.locator('[role="dialog"]').first();
      const box = (await dialog.count()) ? await dialog.boundingBox() : null;
      const file = path.join(OUT, `${style}-${width}.png`);
      await p.screenshot({ path: file, clip: box || undefined });
      console.log("captured", file);
      await p.close();
    }
    await ctx.close();
  }
  await browser.close();
};
main().catch((e) => { console.error(e); process.exit(1); });
