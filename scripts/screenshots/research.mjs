// Captures deep research for the visual check before a ship: Cmd+K with a question
// typed (the "Research in depth" row), the research in progress, and the finished
// briefing in Ask Skim.
//   pnpm dev; OUT=/tmp/research WIDTHS=1440,640 node scripts/screenshots/research.mjs
import { chromium } from "playwright";
import path from "node:path";
import fs from "node:fs/promises";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../..");
const OUT = process.env.OUT || "/tmp/research";
const URL_ = process.env.SKIM_URL || "http://localhost:1420/";
const WIDTHS = (process.env.WIDTHS || "1440").split(",").map(Number);

// Answers research_topic the way the Rust command does: progress events, then a
// briefing citing articles as [n] and web pages as [wN].
const PATCH = `
(() => {
  const real = window.__TAURI_INTERNALS__.invoke;
  window.__TAURI_INTERNALS__.invoke = async (cmd, args) => {
    if (cmd !== "research_topic") return real(cmd, args);
    const all = await real("get_articles", { filter: {} });
    const list = (Array.isArray(all) ? all : all.articles || all.items || []).slice(0, 4);
    const steps = [
      "Planning the research",
      "Searched your feeds for \\u201cmodel training data\\u201d",
      "Searched your feeds for \\u201cAI agents\\u201d",
      "Read 4 of your articles",
      "Looked for gaps in your feeds' coverage",
      "Searched the web for \\u201cAI training data consent rules\\u201d",
      "Read 2 web pages (europa.eu, techpolicy.press)",
      "Writing the briefing",
    ];
    for (const label of steps) {
      window.__SKIM_EMIT__("research-progress", { request_id: args.requestId, label });
      await new Promise((r) => setTimeout(r, window.__RESEARCH_STEP_MS__ ?? 150));
    }
    if (window.__RESEARCH_HOLD__) await new Promise(() => {});
    const web = [
      { title: "AI Act: what providers of general-purpose models must disclose about training data", url: "https://digital-strategy.ec.europa.eu/en/policies/ai-act-gpai" },
      { title: "Workplace monitoring and model training: where consent rules stand", url: "https://techpolicy.press/workplace-monitoring-model-training" },
    ];
    const sources = list.map((a) => ({ id: a.id, title: a.title, feed_title: a.feed_title, url: a.url, published_at: a.published_at, source_type: "article" }))
      .concat(web.map((w, i) => ({ id: "web-" + i, title: w.title, feed_title: new URL(w.url).hostname.replace(/^www\\./, ""), url: w.url, published_at: null, source_type: "web" })));
    const content = "Your feeds cover the data and tooling around models more than any single launch [1][2]. The web fills in the rules that apply to training data [w1] and how consent works for workplace monitoring [w2].\\n\\n" +
      "## What's happening\\n- Meta records employees' mouse movements and keystrokes to train its models [1].\\n- CrabTrap puts a second model in front of production agents to vet each request [2].\\n- Open-source tools increasingly ship with AI-written code [3].\\n\\n" +
      "## Background\\nUnder the AI Act, general-purpose model providers must publish a summary of their training data [w1]. Workplace monitoring for training still needs a lawful basis, and consent from employees is rarely enough on its own [w2].\\n\\n" +
      "## Where sources differ\\nOne outlet frames the Meta program as productivity tooling [1], while commentators treat it as a consent problem [w2].\\n\\n" +
      "## What to watch\\nWhether regulators test the AI Act's disclosure rules this year [w1], and how agent vendors respond [4].";
    return { content, provider: "anthropic", model: "claude-sonnet-5", sources, article_ids: list.map((a) => a.id), actions: [],
      steps: steps.map((label) => ({ tool: "research", label })) };
  };
})();`;

const main = async () => {
  await fs.mkdir(OUT, { recursive: true });
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || undefined });
  try {
    for (const width of WIDTHS) {
      const ctx = await browser.newContext({ viewport: { width, height: 900 }, deviceScaleFactor: 2, colorScheme: "dark", reducedMotion: "reduce" });
      const p = await ctx.newPage();
      p.on("pageerror", (e) => console.warn(`! ${width}: ${e}`));
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
      await p.keyboard.type("how is AI training data being collected?");
      await p.waitForTimeout(500);
      await p.screenshot({ path: path.join(OUT, `desktop-${width}-1-palette-research-row.png`) });

      // Hold the research mid-way to capture the step list.
      await p.evaluate(() => { window.__RESEARCH_STEP_MS__ = 120; window.__RESEARCH_HOLD__ = true; });
      await p.keyboard.press("Alt+Enter");
      await p.waitForSelector(".research-progress", { timeout: 5000 });
      await p.waitForTimeout(1300);
      await p.screenshot({ path: path.join(OUT, `desktop-${width}-2-research-progress.png`) });

      // Run it again, from a fresh page, to the end for the briefing.
      await p.reload({ waitUntil: "networkidle" });
      await p.waitForTimeout(1200);
      if (await gotIt.count()) { await gotIt.first().click(); await p.waitForTimeout(300); }
      await p.evaluate(() => { window.__RESEARCH_STEP_MS__ = 20; });
      await p.keyboard.press("Meta+k");
      await p.waitForTimeout(300);
      await p.keyboard.type("how is AI training data being collected?");
      await p.keyboard.press("Alt+Enter");
      await p.waitForSelector(".research-kicker", { timeout: 8000 });
      await p.waitForTimeout(600);
      await p.screenshot({ path: path.join(OUT, `desktop-${width}-3-briefing.png`) });
      await p.evaluate(() => document.querySelectorAll("*").forEach((el) => { if (el.scrollHeight > el.clientHeight + 4 && /^(auto|scroll)$/.test(getComputedStyle(el).overflowY)) el.scrollTop = el.scrollHeight; }));
      await p.waitForTimeout(400);
      await p.screenshot({ path: path.join(OUT, `desktop-${width}-4-briefing-sources.png`) });
      await ctx.close();
    }
  } finally {
    await browser.close();
  }
};

main().catch((e) => { console.error(e); process.exit(1); });
