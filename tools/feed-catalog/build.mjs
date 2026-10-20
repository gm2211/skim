#!/usr/bin/env node
// Builds shared/feed-catalog.json from tools/feed-catalog/sources.json.
//
// Every candidate is fetched with Skim's own User-Agent. A feed makes the
// catalog only when it answers, parses as RSS/Atom/JSON Feed, is mostly text
// (not a podcast), and posted within the last MAX_AGE_DAYS. Hand-picked feeds
// (origin "skim") lead each topic in their listed order; the rest follow by how
// much they posted in the last 30 days. Every probe result lands in report.json.
//
//   node tools/feed-catalog/build.mjs            # probe and write both files
//   node tools/feed-catalog/build.mjs --dry-run  # probe and print the summary only

import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "../..");
const SOURCES = path.join(here, "sources.json");
const REPORT = path.join(here, "report.json");
const CATALOG = path.join(root, "shared/feed-catalog.json");

const USER_AGENT = "Skim/0.1 RSS Reader";
const MAX_AGE_DAYS = 120;
const MIN_PER_TOPIC = 6;
const CONCURRENCY = 16;
const TIMEOUT_MS = 20_000;
const DAY = 86_400_000;

const dryRun = process.argv.includes("--dry-run");
const now = Date.now();

function decode(s) {
  return s
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1")
    .replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;|&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(+n))
    .replace(/&amp;/g, "&");
}

function textOf(xml, tag) {
  const m = xml.match(new RegExp(`<${tag}(?:\\s[^>]*)?>([\\s\\S]*?)</${tag}>`, "i"));
  return m ? decode(m[1]).replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim() : "";
}

/** Item count, newest/recent post dates and audio share from an RSS, Atom or JSON feed body. */
function inspect(body) {
  const trimmed = body.trimStart();
  if (trimmed.startsWith("{")) {
    const json = JSON.parse(trimmed);
    if (!Array.isArray(json.items)) return null;
    const dates = json.items.map((i) => Date.parse(i.date_published ?? i.date_modified ?? "")).filter(Number.isFinite);
    const audio = json.items.filter((i) => (i.attachments ?? []).some((a) => /^audio\//.test(a.mime_type ?? ""))).length;
    return { kind: "json", items: json.items.length, dates, audio, description: json.description ?? "" };
  }
  if (!/<(rss|feed|rdf:RDF)[\s>]/i.test(body)) return null;
  const atom = /<feed[\s>]/i.test(body) && !/<rss[\s>]/i.test(body);
  const items = body.split(atom ? /<entry[\s>]/i : /<item[\s>]/i).slice(1);
  const dates = items
    .map((it) => {
      for (const tag of ["pubDate", "published", "updated", "dc:date", "a10:updated"]) {
        const t = Date.parse(textOf(it, tag));
        if (Number.isFinite(t)) return t;
      }
      return NaN;
    })
    .filter(Number.isFinite);
  const audio = items.filter((it) => /<enclosure[^>]+type=["']audio\//i.test(it) || /<itunes:duration>/i.test(it)).length;
  const head = body.split(atom ? /<entry[\s>]/i : /<item[\s>]/i)[0];
  const description = textOf(head, atom ? "subtitle" : "description");
  return { kind: atom ? "atom" : "rss", items: items.length, dates, audio, description };
}

async function probe(feed) {
  const started = Date.now();
  try {
    const res = await fetch(feed.url, {
      headers: { "User-Agent": USER_AGENT, Accept: "application/rss+xml, application/atom+xml, application/feed+json, application/xml;q=0.9, */*;q=0.8" },
      redirect: "follow",
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    const result = { status: res.status, finalUrl: res.url, ms: Date.now() - started };
    if (!res.ok) return { ...result, verdict: `http ${res.status}` };
    const info = inspect(await res.text());
    if (!info) return { ...result, verdict: "not a feed" };
    const newest = info.dates.length ? Math.max(...info.dates) : null;
    const last30 = info.dates.filter((d) => now - d <= 30 * DAY).length;
    const out = {
      ...result,
      kind: info.kind,
      items: info.items,
      newest: newest ? new Date(newest).toISOString() : null,
      postsLast30Days: last30,
      audioShare: info.items ? +(info.audio / info.items).toFixed(2) : 0,
      feedDescription: info.description.slice(0, 200),
    };
    if (info.items === 0) return { ...out, verdict: "empty" };
    if (out.audioShare > 0.5) return { ...out, verdict: "podcast" };
    if (!newest) return { ...out, verdict: "undated" };
    if (now - newest > MAX_AGE_DAYS * DAY) return { ...out, verdict: "stale" };
    if (newest - now > 2 * DAY) return { ...out, verdict: "future-dated" };
    return { ...out, verdict: "ok" };
  } catch (e) {
    return { status: 0, ms: Date.now() - started, verdict: e.name === "TimeoutError" ? "timeout" : `error: ${e.cause?.code ?? e.message}` };
  }
}

async function pool(items, worker) {
  const results = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: CONCURRENCY }, async () => {
    while (next < items.length) {
      const i = next++;
      results[i] = await worker(items[i]);
    }
  }));
  return results;
}

const sources = JSON.parse(await readFile(SOURCES, "utf8"));
const unique = [...new Map(sources.topics.flatMap((t) => t.feeds).map((f) => [f.url, f])).values()];
console.error(`Probing ${unique.length} feeds…`);
const probed = new Map(unique.map((f, i) => [f.url, i]));
const results = await pool(unique, probe);
const resultFor = (url) => results[probed.get(url)];

const topics = [];
const report = { generatedAt: new Date(now).toISOString(), maxAgeDays: MAX_AGE_DAYS, userAgent: USER_AGENT, topics: [] };
for (const topic of sources.topics) {
  const rows = topic.feeds.map((f) => ({ ...f, probe: resultFor(f.url) }));
  const ok = rows.filter((r) => r.probe.verdict === "ok");
  const picks = ok.filter((r) => r.origin === "skim");
  const rest = ok.filter((r) => r.origin !== "skim").sort((a, b) => b.probe.postsLast30Days - a.probe.postsLast30Days);
  const feeds = [...picks, ...rest].map(({ title, url, site, description, probe }) => ({
    title,
    url,
    site,
    description: description || probe.feedDescription || "",
  }));
  report.topics.push({ id: topic.id, candidates: rows.length, kept: feeds.length, feeds: rows.map(({ title, url, origin, probe }) => ({ title, url, origin, ...probe })) });
  if (feeds.length < MIN_PER_TOPIC) {
    console.error(`  ${topic.id}: only ${feeds.length} live feeds, topic left out`);
    continue;
  }
  topics.push({ id: topic.id, name: topic.name, feeds });
}

const verdicts = {};
for (const r of results) {
  const key = r.verdict.startsWith("error") ? "error" : r.verdict.startsWith("http") ? "http error" : r.verdict;
  verdicts[key] = (verdicts[key] ?? 0) + 1;
}
report.summary = { candidates: unique.length, verdicts, topics: topics.length, feeds: topics.reduce((n, t) => n + t.feeds.length, 0) };
console.error(JSON.stringify(report.summary));
for (const t of report.topics) console.error(`  ${t.id.padEnd(12)} ${String(t.kept).padStart(3)} / ${t.candidates}`);

if (!dryRun) {
  await writeFile(CATALOG, JSON.stringify({ version: 2, generatedAt: report.generatedAt, topics }, null, 1) + "\n");
  await writeFile(REPORT, JSON.stringify(report, null, 1) + "\n");
  console.error(`Wrote ${path.relative(root, CATALOG)} and ${path.relative(root, REPORT)}`);
}
