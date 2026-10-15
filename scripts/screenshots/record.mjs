#!/usr/bin/env node
// Records the README walkthrough: one continuous session through the app,
// with a visible pointer and a caption that says what each part is for.
//
// Like capture.mjs it drives the real frontend against the demo fixtures in
// headless Chromium, so the run needs no feeds, key or model and comes out the
// same every time. Frames come from Chromium's screencast, stamped with the
// time they were painted; build-video.mjs turns them into a constant-rate MP4
// and the README GIF.
//
// Usage:
//   pnpm dev                                  # in another shell
//   node scripts/screenshots/record.mjs       # writes .walkthrough/frames
//   node scripts/screenshots/build-video.mjs  # encodes docs/skim-walkthrough.*
//
// Env: SKIM_URL (default http://localhost:1420/), CHROME_PATH, CHAPTERS (a
// comma-separated subset of the chapter ids below, for iterating on one).
import { chromium } from "playwright";
import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs/promises";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, "../..");
const OUT = path.join(ROOT, ".walkthrough");
const FRAMES = path.join(OUT, "frames");
const URL_ = process.env.SKIM_URL || "http://localhost:1420/";
const ONLY = process.env.CHAPTERS ? new Set(process.env.CHAPTERS.split(",")) : null;

export const VIEWPORT = { width: 1440, height: 900 };
export const SCALE = 1.5;

// The pointer and the caption live in the page, so they are painted into the
// same frames as the app and need no compositing step afterwards.
const OVERLAY = () => {
  const style = document.createElement("style");
  style.textContent = `
    ::-webkit-scrollbar { width: 0 !important; height: 0 !important; }
    #wt-cursor { position: fixed; left: 0; top: 0; z-index: 2147483647; pointer-events: none;
      width: 22px; height: 22px; transform: translate(-3px, -2px);
      filter: drop-shadow(0 1px 2px rgba(0,0,0,.6)); transition: none; }
    #wt-cursor.down::after { content: ""; position: absolute; left: -11px; top: -11px; width: 30px; height: 30px;
      border-radius: 50%; background: rgba(120,170,255,.35); }
    #wt-cap { position: fixed; left: 50%; bottom: 66px; z-index: 2147483646; pointer-events: none;
      transform: translateX(-50%) translateY(8px); opacity: 0; transition: opacity .35s, transform .35s;
      max-width: 1040px; text-wrap: balance; padding: 11px 24px 12px; border-radius: 14px;
      background: rgba(10,13,19,.92); border: 1px solid rgba(255,255,255,.12);
      box-shadow: 0 10px 40px rgba(0,0,0,.55); text-align: center;
      font: 400 17px/1.4 Inter, -apple-system, "Segoe UI", Roboto, sans-serif; color: #d9dfe9; }
    #wt-cap.on { opacity: 1; transform: translateX(-50%) translateY(0); }
    #wt-cap.top { bottom: auto; top: 70px; }
    #wt-cap.left { left: 24px; max-width: 330px; transform: none; text-align: left; }
    #wt-cap b { display: block; font-weight: 600; font-size: 13px; letter-spacing: 1.6px;
      text-transform: uppercase; color: #7fb0ff; margin-bottom: 4px; }
    #wt-card { position: fixed; inset: 0; z-index: 2147483645; pointer-events: none; display: flex;
      flex-direction: column; align-items: center; justify-content: center; gap: 18px;
      background: radial-gradient(ellipse at center, rgba(16,20,28,.97), rgba(6,8,12,.99));
      opacity: 0; transition: opacity .5s; color: #e7ecf3; text-align: center;
      font-family: Inter, -apple-system, "Segoe UI", Roboto, sans-serif; }
    #wt-card.on { opacity: 1; }
    #wt-card h1 { margin: 0; font: 700 84px/1 Georgia, "Times New Roman", serif; letter-spacing: 10px; }
    #wt-card p { margin: 0; font-size: 26px; color: #aab4c3; }
  `;
  const cursor = document.createElement("div");
  cursor.id = "wt-cursor";
  cursor.innerHTML = `<svg viewBox="0 0 22 22" width="22" height="22"><path d="M3 2 L3 18 L7.5 13.8 L10.6 20.4 L13.4 19.1 L10.4 12.6 L16.4 12.6 Z" fill="#fff" stroke="#111" stroke-width="1.3" stroke-linejoin="round"/></svg>`;
  const cap = document.createElement("div");
  cap.id = "wt-cap";
  const card = document.createElement("div");
  card.id = "wt-card";
  const mount = () => { document.head.appendChild(style); document.body.append(card, cap, cursor); };
  if (document.body) mount(); else addEventListener("DOMContentLoaded", mount);
  addEventListener("mousemove", (e) => { cursor.style.left = e.clientX + "px"; cursor.style.top = e.clientY + "px"; }, true);
  addEventListener("mousedown", () => cursor.classList.add("down"), true);
  addEventListener("mouseup", () => setTimeout(() => cursor.classList.remove("down"), 160), true);
  const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;");
  window.__wt = {
    caption(label, text, where) {
      if (!label) { cap.classList.remove("on"); return; }
      cap.classList.toggle("top", where === "top");
      cap.classList.toggle("left", where === "left");
      cap.innerHTML = `<b>${esc(label)}</b>${esc(text)}`;
      cap.classList.add("on");
    },
    card(title, text) {
      if (!title) { card.classList.remove("on"); return; }
      card.innerHTML = `<h1>${esc(title)}</h1><p>${esc(text)}</p>`;
      card.classList.add("on");
    },
  };
};

/** The pointer glides to an element's centre (or a point), then clicks. */
let pointer = { x: VIEWPORT.width * 0.6, y: VIEWPORT.height * 0.55 };
async function glide(p, target, { click = true, steps = 28, dx = 0, dy = 0 } = {}) {
  let x, y;
  if (typeof target === "object" && "x" in target) ({ x, y } = target);
  else {
    const loc = typeof target === "string" ? p.locator(target).first() : target;
    await loc.waitFor({ state: "visible" });
    await loc.scrollIntoViewIfNeeded();
    const b = await loc.boundingBox();
    x = b.x + b.width / 2;
    y = b.y + b.height / 2;
  }
  x += dx;
  y += dy;
  // Ease in and out, so the pointer reads as a hand rather than a teleport.
  for (let i = 1; i <= steps; i++) {
    const t = i / steps;
    const e = t < 0.5 ? 2 * t * t : 1 - (-2 * t + 2) ** 2 / 2;
    await p.mouse.move(pointer.x + (x - pointer.x) * e, pointer.y + (y - pointer.y) * e);
    await p.waitForTimeout(12);
  }
  pointer = { x, y };
  if (click) {
    await p.waitForTimeout(120);
    await p.mouse.down();
    await p.waitForTimeout(90);
    await p.mouse.up();
  }
}

/**
 * Shows a caption. `where` moves it out of the way of the chapter's action:
 * "top" when that is at the bottom, "left" beside a tall centred dialog.
 */
const caption = (p, label, text, where = "bottom") => p.evaluate(([l, t, w]) => window.__wt.caption(l, t, w), [label, text, where]);
const card = (p, title, text) => p.evaluate(([l, t]) => window.__wt.card(l, t), [title, text]);
const hold = (p, s) => p.waitForTimeout(s * 1000);

/** Scrolls the element under the pointer smoothly, a wheel notch at a time. */
async function wheel(p, total, notches = 14) {
  for (let i = 0; i < notches; i++) {
    await p.mouse.wheel(0, total / notches);
    await p.waitForTimeout(40);
  }
}

const LEAD = "Why “Just Pick AWS” Is Bad Advice in 2026";

// Each chapter picks up where the previous one left the app. Keep a chapter's
// caption on screen for at least ~3s: that is about what a reader needs.
const CHAPTERS = [
  {
    id: "intro",
    async run(p) {
      await card(p, "SKIM", "An RSS reader for the age of AI");
      await hold(p, 2.4);
      await card(p, null);
      await hold(p, 0.6);
    },
  },
  {
    id: "today",
    async run(p) {
      await caption(p, "Today", "Your feeds, laid out as one front page. Stories reported by several sources are merged into one.");
      await glide(p, p.getByText("Today", { exact: true }).first());
      await hold(p, 1.6);
      await glide(p, p.getByRole("tab", { name: "Security" }).or(p.getByText("Security", { exact: true })).first());
      await hold(p, 1.4);
      await glide(p, p.getByText("All stories", { exact: true }).first());
      await hold(p, 0.6);
      await glide(p, { x: 960, y: 560 }, { click: false });
      await wheel(p, 520);
      await hold(p, 1.2);
      await wheel(p, -520);
      await hold(p, 0.8);
    },
  },
  {
    id: "pages",
    async run(p) {
      await caption(p, "Last week", "Turn the page to go back a week at a time: the buttons at the foot, or \u2190 and \u2192.");
      await glide(p, p.getByRole("button", { name: "Last week" }).first());
      await hold(p, 3.2);
      await glide(p, p.getByRole("button", { name: "Today" }).first());
      await hold(p, 1.0);
    },
  },
  {
    id: "reader",
    async run(p) {
      await caption(p, "Reader", "Every article in a clean reader, next to the list and your folders.");
      await glide(p, p.getByText("All Articles", { exact: true }).first());
      await hold(p, 0.7);
      await glide(p, p.getByText(LEAD).first());
      await hold(p, 1.0);
      await glide(p, { x: 1180, y: 600 }, { click: false });
      await wheel(p, 360);
      await hold(p, 0.8);
      await wheel(p, -360);
      await hold(p, 0.6);
    },
  },
  {
    id: "summarize",
    async run(p) {
      await caption(p, "Summarize", "One click for a summary of the article you are reading.");
      await glide(p, '[aria-label="Summarize"]');
      await hold(p, 3.2);
    },
  },
  {
    id: "chat",
    async run(p) {
      await caption(p, "Chat", "Ask follow-up questions about the article you are reading.", "top");
      await glide(p, '[aria-label="Chat with article"]');
      await hold(p, 0.8);
      const box = p.locator("textarea").last();
      await glide(p, box);
      await box.pressSequentially("Which cloud does it recommend for an AI startup?", { delay: 28 });
      await hold(p, 0.3);
      await box.press("Enter");
      await hold(p, 3.2);
      await glide(p, '[aria-label="Chat with article"]');
      await hold(p, 0.4);
    },
  },
  {
    id: "inbox",
    async run(p) {
      await caption(p, "For you", "Sort any list For you: a model scores every unread article from 1 to 5, so the important ones rise to the top.");
      await glide(p, p.getByRole("button", { name: "For you", exact: true }).first());
      await hold(p, 3.4);
    },
  },
  {
    id: "palette",
    async run(p) {
      await caption(p, "⌘K", "Jump anywhere from the keyboard. If no command matches, Skim's assistant answers instead.");
      await p.keyboard.press("Meta+k");
      await hold(p, 0.9);
      await p.keyboard.type("Anything new on AI agents?", { delay: 30 });
      await hold(p, 0.5);
      await p.keyboard.press("Enter");
      await hold(p, 3.6);
      await p.keyboard.press("Escape");
      await hold(p, 0.4);
    },
  },
  {
    id: "organize",
    async run(p) {
      await caption(p, "Auto-organize", "Let the model file your feeds into folders. You review them before anything changes.", "left");
      await glide(p, '[title="Add folder or smart folder"]');
      await hold(p, 0.5);
      await glide(p, p.getByText("Auto-organize with AI").first());
      await hold(p, 0.8);
      await glide(p, p.getByRole("button", { name: /Run$/ }).first());
      await hold(p, 2.6);
      await glide(p, p.getByRole("button", { name: "Cancel" }).first());
      await hold(p, 0.5);
    },
  },
  {
    id: "settings",
    async run(p) {
      await caption(p, "Your model", "Bring your own model: Claude, OpenAI, Grok, OpenRouter, or any compatible endpoint.", "left");
      await glide(p, p.getByText("Settings", { exact: true }).first());
      await hold(p, 1.2);
      await glide(p, p.getByRole("button", { name: "Change AI service" }).first());
      await glide(p, { x: 1180, y: 600 }, { click: false });
      await hold(p, 3.0);
      await p.keyboard.press("Escape");
      await hold(p, 0.3);
    },
  },
  {
    id: "outro",
    async run(p) {
      await caption(p, null);
      await card(p, "SKIM", "github.com/gm2211/skim");
      await hold(p, 2.6);
    },
  },
];

const main = async () => {
  await fs.rm(FRAMES, { recursive: true, force: true });
  await fs.mkdir(FRAMES, { recursive: true });
  const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || undefined });
  const ctx = await browser.newContext({ viewport: VIEWPORT, deviceScaleFactor: SCALE, colorScheme: "dark" });
  const p = await ctx.newPage();
  p.on("pageerror", (e) => console.warn(`  ! ${e}`));
  if (process.env.DEBUG) p.on("framenavigated", (f) => console.log("nav", f.url()));
  await p.addInitScript({ path: path.join(HERE, "fixtures.js") });
  await p.addInitScript({ path: path.join(HERE, "mock-backend.js") });
  await p.addInitScript(OVERLAY);
  await p.goto(URL_, { waitUntil: "networkidle" });
  await p.waitForTimeout(1200);
  const gotIt = p.getByRole("button", { name: /got it/i });
  if (await gotIt.count()) await gotIt.first().click();
  await p.mouse.move(pointer.x, pointer.y);
  await p.waitForTimeout(400);

  // Screencast frames arrive only when something repaints; each carries its
  // paint time, which build-video.mjs uses as that frame's duration.
  const cdp = await ctx.newCDPSession(p);
  const stamps = [];
  let n = 0;
  const writes = [];
  cdp.on("Page.screencastFrame", ({ data, metadata, sessionId }) => {
    const file = `f${String(n++).padStart(5, "0")}.jpg`;
    stamps.push({ file, t: metadata.timestamp });
    writes.push(fs.writeFile(path.join(FRAMES, file), Buffer.from(data, "base64")));
    cdp.send("Page.screencastFrameAck", { sessionId }).catch(() => {});
  });
  await cdp.send("Page.startScreencast", {
    format: "jpeg",
    quality: 92,
    maxWidth: VIEWPORT.width * SCALE,
    maxHeight: VIEWPORT.height * SCALE,
  });

  const chapters = [];
  for (const ch of CHAPTERS) {
    if (ONLY && !ONLY.has(ch.id)) continue;
    const start = Date.now() / 1000;
    try {
      await ch.run(p);
    } catch (e) {
      console.warn(`  ! ${ch.id} failed: ${e.message.split("\n")[0]}`);
    }
    chapters.push({ id: ch.id, start, end: Date.now() / 1000 });
    console.log(`  ${ch.id}`);
  }
  await p.waitForTimeout(300);
  await cdp.send("Page.stopScreencast");
  await Promise.all(writes);
  await fs.writeFile(path.join(OUT, "frames.json"), JSON.stringify({ viewport: VIEWPORT, scale: SCALE, stamps, chapters }, null, 2));
  console.log(`${stamps.length} frames`);
  await browser.close();
};

main().catch((e) => { console.error(e); process.exit(1); });
