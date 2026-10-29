// Captures queued chat messages for the visual check before a ship: questions
// asked while Skim is still answering, in the article chat and in Ask Skim.
//   pnpm dev; OUT=/tmp/queue WIDTHS=1440,640 node scripts/screenshots/chat-queue.mjs
import { chromium } from "playwright";
import path from "node:path";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../..");
const OUT = process.env.OUT || "/tmp/chat-queue";
const URL_ = process.env.SKIM_URL || "http://localhost:1420/";
const WIDTHS = (process.env.WIDTHS || "1440").split(",").map(Number);
const LEAD_TITLE = "Why “Just Pick AWS” Is Bad Advice in 2026";

// Answers wait until the page calls window.__answer() (or __fail()), so the
// queue can be captured while one is in flight.
const PATCH = `
(() => {
  const real = window.__TAURI_INTERNALS__.invoke;
  const pending = [];
  window.__answer = () => pending.shift()?.resolve();
  window.__fail = () => pending.shift()?.reject("The provider timed out. Try again in a moment.");
  window.__TAURI_INTERNALS__.invoke = async (cmd, args) => {
    if (cmd !== "chat_with_article" && cmd !== "chat_with_articles") return real(cmd, args);
    await new Promise((resolve, reject) => pending.push({ resolve, reject }));
    const content = "Both approaches share the host's IP and port space across VMs. The difference is how each VM's share is assigned: stateful NAT hands out ports per connection as they're needed, while the static scheme pre-assigns fixed slices to each slot.";
    return cmd === "chat_with_article"
      ? { content, provider: "anthropic", model: "claude-sonnet-5", web_citations: [] }
      : { content, provider: "anthropic", model: "claude-sonnet-5", sources: [], article_ids: [] };
  };
})();`;

async function setup(ctx) {
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
  return p;
}

async function shootPanel(p, file) {
  const panel = await p.locator(".cursor-ns-resize").first().boundingBox();
  const vp = p.viewportSize();
  await p.screenshot({ path: file, clip: panel ? { x: panel.x, y: panel.y, width: panel.width, height: vp.height - panel.y } : undefined });
  console.log("captured", file);
}

const main = async () => {
  await fs.mkdir(OUT, { recursive: true });
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || undefined });
  for (const width of WIDTHS) {
    const ctx = await browser.newContext({ viewport: { width, height: 900 }, deviceScaleFactor: 2, colorScheme: "dark", reducedMotion: "reduce" });

    // Article chat.
    const p = await setup(ctx);
    await p.getByText(LEAD_TITLE).first().click();
    await p.waitForTimeout(600);
    await p.locator('[aria-label="Chat with article"]').first().click();
    await p.waitForTimeout(400);
    const handle = await p.locator(".cursor-ns-resize").first().boundingBox();
    if (handle) {
      await p.mouse.move(handle.x + handle.width / 2, handle.y + handle.height / 2);
      await p.mouse.down();
      await p.mouse.move(handle.x + handle.width / 2, 300, { steps: 8 });
      await p.mouse.up();
    }
    const box = p.getByPlaceholder("Ask about this article...");
    await box.fill("ok so in both cases you can still share ports");
    await box.press("Enter");
    await p.waitForTimeout(200);
    const queueBox = p.getByPlaceholder("Queue a follow-up...");
    await queueBox.fill("how many VMs can one host IP support before ports run out?");
    await queueBox.press("Enter");
    await queueBox.fill("and what happens when a slot's slice is exhausted?");
    await queueBox.press("Enter");
    await queueBox.fill("is this the same trick Kubernetes uses");
    await p.waitForTimeout(300);
    await shootPanel(p, path.join(OUT, `article-queued-${width}.png`));
    await p.locator(".queued-message").nth(1).hover();
    await p.getByRole("button", { name: "Edit queued message" }).nth(1).click();
    await p.waitForTimeout(200);
    await shootPanel(p, path.join(OUT, `article-editing-${width}.png`));
    await p.keyboard.press("Escape");
    await p.evaluate(() => window.__answer());
    await p.waitForTimeout(500);
    await shootPanel(p, path.join(OUT, `article-draining-${width}.png`));
    await p.evaluate(() => window.__fail());
    await p.waitForTimeout(500);
    await shootPanel(p, path.join(OUT, `article-paused-${width}.png`));
    await p.close();

    // Ask Skim.
    const a = await setup(ctx);
    await a.keyboard.press(process.platform === "darwin" ? "Meta+Shift+K" : "Control+Shift+K").catch(() => {});
    let ask = a.getByRole("textbox", { name: "Question about your articles" });
    if (!(await ask.count())) {
      const opener = a.getByRole("button", { name: /ask skim|chat with articles/i }).first();
      if (await opener.count()) await opener.click({ timeout: 3000 }).catch(() => {});
      await a.waitForTimeout(500);
      ask = a.getByRole("textbox", { name: "Question about your articles" });
    }
    if (await ask.count()) {
      await ask.fill("what did I miss this week about cloud costs?");
      await ask.press("Enter");
      await a.waitForTimeout(200);
      await ask.fill("which of those stories had the most disagreement?");
      await a.getByRole("button", { name: "Queue" }).click();
      await ask.fill("summarize the AWS one in two lines");
      await ask.press("Enter");
      await a.waitForTimeout(300);
      const file = path.join(OUT, `ask-skim-queued-${width}.png`);
      await a.screenshot({ path: file });
      console.log("captured", file);
    } else {
      console.warn("! could not open Ask Skim");
    }
    await a.close();
    await ctx.close();
  }
  await browser.close();
};
main().catch((e) => { console.error(e); process.exit(1); });
