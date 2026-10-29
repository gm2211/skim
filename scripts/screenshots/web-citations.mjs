// Captures an article chat answer that cites web results as [wN], for the visual
// check before a ship: chips in the answer and the web source cards under it.
//   pnpm dev; OUT=/tmp/web WIDTHS=1440,900 node scripts/screenshots/web-citations.mjs
import { chromium } from "playwright";
import path from "node:path";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../..");
const OUT = process.env.OUT || "/tmp/web-citations";
const URL_ = process.env.SKIM_URL || "http://localhost:1420/";
const WIDTHS = (process.env.WIDTHS || "1440").split(",").map(Number);
const LEAD_TITLE = "Why “Just Pick AWS” Is Bad Advice in 2026";

const PATCH = `
(() => {
  const real = window.__TAURI_INTERNALS__.invoke;
  window.__TAURI_INTERNALS__.invoke = async (cmd, args) => {
    if (cmd !== "chat_with_article") return real(cmd, args);
    await new Promise((r) => setTimeout(r, 200));
    return {
      content: "Yes, quite a few people are. Hacker News commenters worked out within hours that one of the keys was literally 4 and tied it to xkcd 221 [w2]. Anchor Browser's write-up calls it the week the joke \\u201cturned into an incident report\\u201d [w2], and explain xkcd already has a talk-page note linking the new comic to 221 [w1].\\n\\nOne correction to my earlier answer: the PS3 break was a different flaw, a reused ECDSA nonce rather than a weak private key [w3].",
      provider: "anthropic", model: "claude-sonnet-5",
      web_citations: [
        { title: "3314: Vulnerability - explain xkcd", url: "https://www.explainxkcd.com/wiki/index.php/3314:_Vulnerability", snippet: "I feel like the explanation should mention 899 and 221, since it describes a procedure that could return 4 as a random integer.", query: "xkcd 221 emudhra" },
        { title: "Chosen by Fair Dice Roll: The eMudhra CA Key Was 4, and Your Agents Should Care", url: "https://anchorbrowser.io/blog/emudhra-ca-key-was-4", snippet: "For almost two decades, xkcd 221 has been the internet's favorite joke about bad randomness. This week it turned into an incident report.", query: "xkcd 221 emudhra" },
        { title: "fail0verflow: Console Hacking 2010, PS3 Epic Fail", url: "https://fail0verflow.com/media/27c3", snippet: "Sony used the same random number k for every ECDSA signature, which lets anyone recover the private key.", query: "ps3 ecdsa nonce" },
        { title: "eMudhra CA Keys Cracked: One Was the Number 4 [2026]", url: "https://securitynews.example/emudhra-keys", snippet: "eMudhra revoked eight intermediate CA certificates after researchers found private keys as guessable as the number 4.", query: "xkcd 221 emudhra" },
      ],
    };
  };
})();`;

const main = async () => {
  await fs.mkdir(OUT, { recursive: true });
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || undefined });
  for (const width of WIDTHS) {
    const ctx = await browser.newContext({ viewport: { width, height: 900 }, deviceScaleFactor: 2, colorScheme: "dark", reducedMotion: "reduce" });
    for (const hover of ["rest", "chip", "tile"]) {
      const p = await ctx.newPage();
      p.on("pageerror", (e) => console.warn(`! ${e}`));
      const catalog = await fs.readFile(path.join(ROOT, "shared/feed-catalog.json"), "utf8");
      await p.addInitScript({ content: `window.__SKIM_CATALOG__ = ${catalog};` });
      await p.addInitScript({ path: path.join(HERE, "fixtures.js") });
      await p.addInitScript({ path: path.join(HERE, "mock-backend.js") });
      await p.addInitScript({ content: PATCH });
      // On a Mac host the app leaves #root transparent for the native window's glass, which a
      // plain browser lacks; paint the opaque fallback it uses under reduced transparency.
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
      await box.fill("is anyone else making the xkcd 221 connection?");
      await box.press("Enter");
      await p.waitForSelector(".source-tile", { timeout: 5000 });
      // Pull the panel up so the answer and its cards fit, then scroll to them.
      const handle = await p.locator(".cursor-ns-resize").first().boundingBox();
      if (handle) {
        await p.mouse.move(handle.x + handle.width / 2, handle.y + handle.height / 2);
        await p.mouse.down();
        await p.mouse.move(handle.x + handle.width / 2, 120, { steps: 8 });
        await p.mouse.up();
      }
      await p.locator(".source-tile").last().scrollIntoViewIfNeeded();
      await p.waitForTimeout(300);
      if (hover === "chip") await p.locator(".cite-chip").nth(2).hover();
      else if (hover === "tile") await p.locator(".source-tile").nth(0).hover();
      else await p.mouse.move(2, 2);
      await p.waitForTimeout(200);
      const file = path.join(OUT, `article-chat-${hover}-${width}.png`);
      const panel = await p.locator(".cursor-ns-resize").first().boundingBox();
      const vp = p.viewportSize();
      await p.screenshot({ path: file, clip: panel ? { x: panel.x, y: panel.y, width: panel.width, height: vp.height - panel.y } : undefined });
      console.log("captured", file);
      await p.close();
    }
    await ctx.close();
  }
  await browser.close();
};
main().catch((e) => { console.error(e); process.exit(1); });
