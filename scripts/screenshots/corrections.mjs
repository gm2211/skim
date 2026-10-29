// Captures an article chat where the second answer corrects the first in place:
// the wrong words struck through in the first reply with "[updated]: ..." beside them.
//   pnpm dev; OUT=/tmp/corrections WIDTHS=1440,390 node scripts/screenshots/corrections.mjs
import { chromium } from "playwright";
import path from "node:path";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../..");
const OUT = process.env.OUT || "/tmp/corrections";
const URL_ = process.env.SKIM_URL || "http://localhost:1420/";
const WIDTHS = (process.env.WIDTHS || "1440").split(",").map(Number);
const LEAD_TITLE = "Why “Just Pick AWS” Is Bad Advice in 2026";

const PATCH = `
(() => {
  const real = window.__TAURI_INTERNALS__.invoke;
  const answers = [
    "The excerpt covers SnapStart and Aurora DSQL, and argues that the double NAT setup is what makes egress costs climb about 100x for small teams.",
    "The 100x figure comes from the passage you quoted, so the article does make that claim.\\n\\n<correction><was>covers SnapStart and Aurora DSQL, and argues</was><now>does not mention SnapStart or Aurora DSQL; it argues</now></correction>",
  ];
  let turn = 0;
  window.__TAURI_INTERNALS__.invoke = async (cmd, args) => {
    if (cmd !== "chat_with_article") return real(cmd, args);
    await new Promise((r) => setTimeout(r, 150));
    return { content: answers[Math.min(turn++, answers.length - 1)], provider: "anthropic", model: "claude-sonnet-5", web_citations: [] };
  };
})();`;

const main = async () => {
  await fs.mkdir(OUT, { recursive: true });
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || undefined });
  for (const width of WIDTHS) {
    const ctx = await browser.newContext({ viewport: { width, height: 900 }, deviceScaleFactor: 2, colorScheme: "dark", reducedMotion: "reduce" });
    const p = await ctx.newPage();
    p.on("pageerror", (e) => console.warn(`! ${e}`));
    const catalog = await fs.readFile(path.join(ROOT, "shared/feed-catalog.json"), "utf8");
    await p.addInitScript({ content: `window.__SKIM_CATALOG__ = ${catalog};` });
    await p.addInitScript({ path: path.join(HERE, "fixtures.js") });
    await p.addInitScript({ path: path.join(HERE, "mock-backend.js") });
    await p.addInitScript({ content: PATCH });
    await p.addInitScript({ content: `document.addEventListener("DOMContentLoaded", () => { const s = document.createElement("style"); s.textContent = "html.macos #root { background: var(--color-bg-primary) !important; }"; document.head.appendChild(s); });` });
    await p.goto(URL_, { waitUntil: "networkidle" });
    await p.waitForTimeout(1200);
    const gotIt = p.getByRole("button", { name: /got it/i });
    if (await gotIt.count()) { await gotIt.first().click(); await p.waitForTimeout(300); }
    await p.getByText(LEAD_TITLE).first().click();
    await p.waitForTimeout(600);
    await p.locator('[aria-label="Chat with article"]').first().click();
    await p.waitForTimeout(400);
    const box = p.getByPlaceholder("Ask about this article...");
    await box.fill("what does the excerpt cover?");
    await box.press("Enter");
    await p.waitForTimeout(600);
    await box.fill("where does the 100x figure come from?");
    await box.press("Enter");
    await p.waitForSelector("del", { timeout: 5000 });
    const handle = await p.locator(".cursor-ns-resize").first().boundingBox();
    if (handle) {
      await p.mouse.move(handle.x + handle.width / 2, handle.y + handle.height / 2);
      await p.mouse.down();
      await p.mouse.move(handle.x + handle.width / 2, 160, { steps: 8 });
      await p.mouse.up();
    }
    await p.mouse.move(2, 2);
    await p.waitForTimeout(300);
    const file = path.join(OUT, `article-chat-correction-${width}.png`);
    const panel = await p.locator(".cursor-ns-resize").first().boundingBox();
    const vp = p.viewportSize();
    await p.screenshot({ path: file, clip: panel ? { x: panel.x, y: panel.y, width: panel.width, height: vp.height - panel.y } : undefined });
    console.log("captured", file);
    await ctx.close();
  }
  await browser.close();
};
main().catch((e) => { console.error(e); process.exit(1); });
