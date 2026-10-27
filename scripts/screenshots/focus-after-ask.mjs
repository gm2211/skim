// Checks that Ask / Reply to selection hands focus to the chat box, and
// captures each surface for the visual check before a ship.
//   pnpm dev; OUT=/tmp/focus WIDTHS=1440,640 node scripts/screenshots/focus-after-ask.mjs
import { chromium } from "playwright";
import path from "node:path";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../..");
const OUT = process.env.OUT || "/tmp/focus-after-ask";
const URL_ = process.env.SKIM_URL || "http://localhost:1420/";
const WIDTHS = (process.env.WIDTHS || "1440").split(",").map(Number);

/** Selects the first `words` words of the first paragraph matching `selector`. */
const selectText = (p, selector) => p.evaluate((sel) => {
  const el = [...document.querySelectorAll(sel)].find((n) => n.textContent.trim().split(/\s+/).length > 8 && n.offsetParent);
  if (!el) throw new Error(`nothing to select in ${sel}`);
  const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
  const node = walker.nextNode();
  const range = document.createRange();
  range.setStart(node, 0);
  range.setEnd(node, Math.min(node.textContent.length, 40));
  const s = window.getSelection();
  s.removeAllRanges();
  s.addRange(range);
}, selector);

const focused = (p) => p.evaluate(() => {
  const a = document.activeElement;
  return a ? `${a.tagName.toLowerCase()}${a.getAttribute("placeholder") ? `[${a.getAttribute("placeholder")}]` : ""}${a.getAttribute("aria-label") ? `(${a.getAttribute("aria-label")})` : ""}` : "none";
});

const results = [];
const check = async (p, name, width) => {
  await p.waitForTimeout(400);
  const f = await focused(p);
  const ok = f.startsWith("textarea");
  results.push({ name, width, focused: f, ok });
  await p.screenshot({ path: path.join(OUT, `${name}-${width}.png`) });
  console.log(ok ? "PASS" : "FAIL", width, name, "→", f);
};

const boot = async (ctx) => {
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
};

const LEAD_TITLE = "Why “Just Pick AWS” Is Bad Advice in 2026";

const main = async () => {
  await fs.mkdir(OUT, { recursive: true });
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || undefined });
  for (const width of WIDTHS) {
    const ctx = await browser.newContext({ viewport: { width, height: 900 }, deviceScaleFactor: 2, colorScheme: "dark", reducedMotion: "reduce" });

    // Reader: highlight a passage, Ask → the article chat drawer.
    let p = await boot(ctx);
    // At phone width the app opens on the sidebar.
    if (!(await p.getByText(LEAD_TITLE).first().isVisible())) await p.getByText("All Articles", { exact: true }).first().dispatchEvent("click");
    await p.waitForTimeout(500);
    await p.getByText(LEAD_TITLE).first().dispatchEvent("click");
    await p.locator("h1", { hasText: "Bad Advice in 2026" }).first().waitFor({ state: "visible" });
    await p.waitForTimeout(500);
    await selectText(p, ".reader-content p, article p, p");
    await p.locator(".reader-selection-ask").first().click();
    await check(p, "1-reader-ask", width);

    // Article chat: send, then Reply to selection on the answer.
    await p.keyboard.type("What is the main argument?");
    await p.keyboard.press("Enter");
    await p.waitForTimeout(1500);
    await p.locator("body").click({ position: { x: 5, y: 5 } }).catch(() => {});
    await selectText(p, ".chat-markdown p, .chat-markdown li");
    await p.locator(".chat-selection-reply:not(.reader-selection-ask)").first().click();
    await check(p, "2-reader-chat-reply", width);
    await p.close();

    // Today: highlight a passage in a story, Ask → Ask Skim.
    p = await boot(ctx);
    await p.getByText("Briefing", { exact: true }).first().dispatchEvent("click");
    await p.waitForTimeout(1500);
    await selectText(p, ".dispatch-body p, .dispatch-dek, .today-story p");
    await p.locator(".reader-selection-ask").first().click();
    await check(p, "3-today-ask", width);

    // Ask Skim: send, then Reply to selection on the answer.
    await p.keyboard.type("Why does this matter?");
    await p.keyboard.press("Enter");
    await p.waitForTimeout(2000);
    await selectText(p, '[role="dialog"] .chat-markdown p, [role="dialog"] .chat-markdown li');
    await p.locator('[role="dialog"] .chat-selection-reply').first().click();
    await check(p, "4-ask-skim-reply", width);
    await p.close();
    await ctx.close();
  }
  await browser.close();
  await fs.writeFile(path.join(OUT, "results.json"), JSON.stringify(results, null, 2));
  if (results.some((r) => !r.ok)) process.exitCode = 1;
};
main().catch((e) => { console.error(e); process.exit(1); });
