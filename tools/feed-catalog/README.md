# Discover feed catalog

`shared/feed-catalog.json` is what Discover's topics show on desktop and iOS before Feedly's
search adds more. It is generated; edit `sources.json` and rebuild.

```bash
node tools/feed-catalog/build.mjs                 # probe every candidate (needs network), write catalog + report
node tools/feed-catalog/build.mjs --reuse-report  # re-curate from report.json without probing
```

A feed is kept when it answers with Skim's User-Agent, parses as RSS, Atom or JSON Feed, is
mostly text (not a podcast) and posted within 365 days (hand picks, `origin: "skim"`) or
120 days (imports). Hand picks lead each topic in order, then imports by posts in the last
30 days, at most two per site. Topics with fewer than six live feeds are left out.
`report.json` records every probe: status, newest post, posts in the last 30 days, verdict.

Sources:
- Hand picks (`origin: "skim"`).
- [plenaryapp/awesome-rss-feeds](https://github.com/plenaryapp/awesome-rss-feeds), CC0 1.0,
  `recommended/with_category/*.opml` (`origin: "awesome-rss-feeds"`).
