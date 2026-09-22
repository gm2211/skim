#!/usr/bin/env node
// A local newsstand: RSS/Atom feeds plus full article pages, served from
// 127.0.0.1. Sandboxes and CI have no route to the real web, and the public
// feeds churn anyway, so this gives the feed fetcher, the reader extractor and
// the AI pipeline something stable and realistic to chew on.
//
//   node scripts/dev-newsstand.mjs          # http://127.0.0.1:4545
//
// Feeds: /feed/<slug>.xml   Articles: /article/<id>
import { createServer } from "node:http";

const PORT = Number(process.env.NEWSSTAND_PORT ?? 4545);
const ORIGIN = `http://127.0.0.1:${PORT}`;

const hoursAgo = (h) => new Date(Date.now() - h * 3600_000);

/** @type {{slug:string,title:string,desc:string,items:any[]}[]} */
const FEEDS = [
  {
    slug: "ars-technica",
    title: "Ars Technica",
    desc: "Serving the technologist for over a decade",
    items: [
      {
        id: "at-1",
        title: "EU regulators open formal probe into cloud egress fees",
        author: "Dana Whitfield",
        hours: 2,
        summary:
          "The European Commission has opened a formal investigation into the data transfer fees charged by the three largest cloud providers.",
        body: [
          "The European Commission opened a formal investigation on Tuesday into the data egress fees charged by Amazon Web Services, Microsoft Azure and Google Cloud, a practice regulators say may lock customers into a single vendor.",
          "Egress fees are charged when a customer moves data out of a provider's network. Storing a terabyte costs a few dollars a month; moving that same terabyte out can cost fifty times as much. Competitors have argued for years that the asymmetry is deliberate.",
          "\"The question is not whether the fee reflects a cost,\" said one official familiar with the case. \"It is whether the fee is set at a level designed to make switching irrational.\"",
          "All three providers have trimmed egress pricing over the last eighteen months, and each now waives the fee outright for customers who leave entirely. Regulators are looking at the narrower case: a customer who wants to keep one workload in place and move another.",
          "A finding against the providers could force per-gigabyte pricing to be published in a comparable format, a remedy the Commission has used before in telecoms roaming.",
        ],
      },
      {
        id: "at-2",
        title: "Rust 1.94 lands with a faster trait solver",
        author: "Priya Raghunathan",
        hours: 9,
        summary:
          "The new solver cuts compile times on trait-heavy crates by a third in the project's own benchmarks.",
        body: [
          "Rust 1.94 shipped this week with the next-generation trait solver enabled by default for coherence checking, the culmination of a multi-year effort to replace a component that had grown difficult to reason about.",
          "The practical effect is on compile time. On the compiler team's benchmark suite, crates that lean heavily on generic traits build between 20 and 35 percent faster. Crates that do not use traits much see no change.",
          "The release also stabilises `let` chains in 2024-edition code, a small syntactic change that removes a common source of nesting in parsing code.",
        ],
      },
      {
        id: "at-3",
        title: "Passkey adoption crosses 30 percent at major retailers",
        author: "Marcus Bell",
        hours: 20,
        summary:
          "Retailers report fewer support tickets after moving sign-in defaults to passkeys.",
        body: [
          "Roughly a third of sign-ins at large online retailers now use passkeys rather than passwords, according to figures shared at an identity conference this week.",
          "The interesting number is not the adoption rate but the support load: one retailer reported account-recovery tickets down 41 percent year over year, which it attributed almost entirely to the shift.",
          "The remaining friction is cross-ecosystem. A passkey created on an Apple device and synced through iCloud Keychain is awkward to use on a Windows desktop, and the fallback is still a password.",
        ],
      },
    ],
  },
  {
    slug: "the-verge",
    title: "The Verge",
    desc: "Technology, science, art, and culture",
    items: [
      {
        id: "tv-1",
        title: "Cloud providers race to publish egress fee schedules",
        author: "Jules Ortiz",
        hours: 3,
        summary:
          "Hours after the EU probe was announced, two of the three providers put updated pricing pages online.",
        body: [
          "Within hours of the European Commission confirming its investigation into cloud egress fees, two of the three named providers published revised pricing pages with per-region transfer costs laid out in a single table.",
          "Neither company framed the change as a response to the probe. Both had been working on the pages \"for some time,\" spokespeople said.",
          "Analysts were unimpressed. \"Publishing the number was never the hard part,\" one wrote. \"Making the number comparable across providers is the hard part, and none of these tables do that.\"",
        ],
      },
      {
        id: "tv-2",
        title: "A small laptop with a very good keyboard",
        author: "Renee Dubois",
        hours: 14,
        summary:
          "Thirteen inches, 1.1kg, and the best key travel on anything this size.",
        body: [
          "There is a category of laptop that exists to be carried, and most of them are bad to type on. This one is not.",
          "The key travel is 1.5mm, which is more than almost anything else at this thickness, and the stabilisers under the wider keys are good enough that the spacebar does not rattle.",
          "Battery life is the compromise: nine hours of real work, not the fourteen on the box. The screen is bright enough outdoors and the hinge opens with one finger.",
        ],
      },
    ],
  },
  {
    slug: "hacker-news",
    title: "Hacker News",
    desc: "Links for the intellectually curious",
    items: [
      {
        id: "hn-1",
        title: "Show HN: I mapped every undersea cable outage since 2010",
        author: "cableplotter",
        hours: 1,
        summary:
          "An interactive map of 1,400 submarine cable faults, with repair times.",
        body: [
          "I spent the last year pulling submarine cable fault reports out of regulatory filings, maintenance-ship logs and a handful of national telecom regulators, and put them on a map.",
          "The headline finding is that repair time correlates far more strongly with distance from the nearest cable-repair ship than with the depth or severity of the break. There are about sixty such ships in the world.",
          "The dataset is CSV, the map is a static site, and both are public domain.",
        ],
      },
      {
        id: "hn-2",
        title: "The cost of a single dropped database index",
        author: "pgnerd",
        hours: 6,
        summary:
          "A post-mortem of an outage caused by a migration that dropped an index nobody thought was used.",
        body: [
          "The migration removed an index on a column we had stopped reading from in application code eight months earlier. What we had not noticed was that a nightly reconciliation job still filtered on it.",
          "The job went from four minutes to eleven hours. It held a long-lived transaction, which stopped autovacuum from reclaiming tuples on the same table, which turned an eleven-hour job into a table that grew 400GB overnight.",
          "The lesson we took is not \"never drop indexes.\" It is that our query-log sampling rate was too low to see a query that runs once a day.",
        ],
      },
      {
        id: "hn-3",
        title: "Why your on-call rotation is too small",
        author: "sredebt",
        hours: 26,
        summary:
          "Below about eight people, the rotation stops being sustainable regardless of alert volume.",
        body: [
          "A rotation of four engineers means every fourth week is yours. That is thirteen weeks a year of interrupted sleep, and it does not matter how quiet the pager is, because the anticipation is the cost, not the alerts.",
          "The arithmetic changes at eight. One week in eight is six weeks a year, which most people can absorb.",
          "If you cannot staff eight, the answer is not a bigger rotation across teams that do not share context. It is fewer things that can page.",
        ],
      },
    ],
  },
  {
    slug: "stratechery",
    title: "Stratechery",
    desc: "Analysis of the strategy and business of technology",
    items: [
      {
        id: "st-1",
        title: "Egress fees and the shape of lock-in",
        author: "Ben Ashford",
        hours: 4,
        summary:
          "The probe matters less for the fines than for what it forces into the open.",
        body: [
          "The European investigation into cloud egress pricing is being read as an antitrust story. It is more usefully read as a disclosure story.",
          "Lock-in in cloud is rarely a single fee. It is the accumulated cost of a managed database with no exact equivalent elsewhere, an IAM model your entire org chart is encoded in, and a network bill that only appears when you try to leave.",
          "Egress is the only one of those three that is a line item. That is why it is the one being regulated, and also why regulating it may not move very much.",
          "The counter-argument is that a published, comparable egress schedule makes the other two forms of lock-in easier to price. If you know exactly what leaving costs in bandwidth, the rest of the migration estimate becomes tractable.",
        ],
      },
      {
        id: "st-2",
        title: "Small models, big deployments",
        author: "Ben Ashford",
        hours: 30,
        summary:
          "The interesting frontier is not capability but where inference happens.",
        body: [
          "For two years the story was capability: each model could do things the last one could not. That story has not ended, but a second one has started, and it is about placement.",
          "A model small enough to run on a laptop changes the product surface, because latency goes to zero and the marginal cost of a request goes to zero with it. Features that were too expensive to offer speculatively become free to offer constantly.",
          "The reader app that summarises every article as it arrives, rather than when you ask, is only possible on the second curve.",
        ],
      },
    ],
  },
];

const escape = (s) =>
  s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

function rss(feed) {
  const items = feed.items
    .map(
      (item) => `    <item>
      <title>${escape(item.title)}</title>
      <link>${ORIGIN}/article/${item.id}</link>
      <guid isPermaLink="false">${ORIGIN}/article/${item.id}</guid>
      <dc:creator>${escape(item.author)}</dc:creator>
      <pubDate>${hoursAgo(item.hours).toUTCString()}</pubDate>
      <description>${escape(item.summary)}</description>
    </item>`,
    )
    .join("\n");
  return `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>${escape(feed.title)}</title>
    <link>${ORIGIN}/feed/${feed.slug}.xml</link>
    <description>${escape(feed.desc)}</description>
    <language>en-us</language>
${items}
  </channel>
</rss>`;
}

function articlePage(item) {
  const paragraphs = item.body.map((p) => `      <p>${escape(p)}</p>`).join("\n");
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>${escape(item.title)}</title>
  <meta name="author" content="${escape(item.author)}" />
  <meta name="description" content="${escape(item.summary)}" />
</head>
<body>
  <nav><a href="/">Home</a> · <a href="/">Sections</a></nav>
  <article>
    <h1>${escape(item.title)}</h1>
    <p class="byline">By ${escape(item.author)}</p>
    <div class="article-body">
${paragraphs}
    </div>
  </article>
  <aside><h2>Related</h2><ul><li><a href="/">More stories</a></li></ul></aside>
</body>
</html>`;
}

const byId = new Map(FEEDS.flatMap((f) => f.items.map((i) => [i.id, i])));

createServer((req, res) => {
  const url = new URL(req.url, ORIGIN);
  const send = (status, type, body) => {
    res.writeHead(status, {
      "Content-Type": type,
      "Access-Control-Allow-Origin": "*",
    });
    res.end(body);
  };

  if (url.pathname === "/") {
    const list = FEEDS.map(
      (f) => `<li><a href="/feed/${f.slug}.xml">${f.title}</a></li>`,
    ).join("");
    return send(200, "text/html; charset=utf-8", `<ul>${list}</ul>`);
  }
  if (url.pathname === "/feeds.json") {
    return send(
      200,
      "application/json",
      JSON.stringify(
        FEEDS.map((f) => ({ title: f.title, url: `${ORIGIN}/feed/${f.slug}.xml` })),
        null,
        2,
      ),
    );
  }
  const feedMatch = url.pathname.match(/^\/feed\/([\w-]+)\.xml$/);
  if (feedMatch) {
    const feed = FEEDS.find((f) => f.slug === feedMatch[1]);
    if (!feed) return send(404, "text/plain", "no such feed");
    return send(200, "application/rss+xml; charset=utf-8", rss(feed));
  }
  const articleMatch = url.pathname.match(/^\/article\/([\w-]+)$/);
  if (articleMatch) {
    const item = byId.get(articleMatch[1]);
    if (!item) return send(404, "text/plain", "no such article");
    return send(200, "text/html; charset=utf-8", articlePage(item));
  }
  send(404, "text/plain", "not found");
}).listen(PORT, "127.0.0.1", () => {
  console.log(`newsstand on ${ORIGIN} (${FEEDS.length} feeds)`);
});
