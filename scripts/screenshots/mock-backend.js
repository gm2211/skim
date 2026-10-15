// In-browser stand-in for the Tauri command layer, used only by the README
// screenshot harness. Injected before the app boots so `invoke` resolves
// against the demo fixtures instead of the Rust backend, which lets the
// captures run anywhere (CI, a container) at a fixed viewport and DPR.
/* eslint-disable */
(function () {
  const D = window.__SKIM_DEMO__;
  if (!D) throw new Error("fixtures.js must be injected before mock-backend.js");

  const feeds = D.FEEDS.map(([id, title, site, group], i) => ({
    id,
    title,
    url: site + "/feed",
    site_url: site,
    description: null,
    icon_url: null,
    feedly_id: null,
    created_at: D.now - 86400 * 90,
    updated_at: D.now,
    last_fetched_at: D.mins(3),
    folder_id: "f-" + group,
    opml_category: group,
    unread_count: 0,
    __group: group,
    __i: i,
  }));


  const DISCOVER_CATALOG = [{"id": "tech", "name": "Tech", "feeds": [{"title": "The Verge", "url": "https://www.theverge.com/rss/index.xml", "site": "https://www.theverge.com", "description": "Technology, science, art, and culture."}, {"title": "Ars Technica", "url": "https://feeds.arstechnica.com/arstechnica/index", "site": "https://arstechnica.com", "description": "In-depth tech news, reviews, and analysis."}, {"title": "TechCrunch", "url": "https://techcrunch.com/feed/", "site": "https://techcrunch.com", "description": "Startups, venture capital, and tech industry news."}, {"title": "Wired", "url": "https://www.wired.com/feed/rss", "site": "https://www.wired.com", "description": "How technology is changing every aspect of our lives."}, {"title": "Engadget", "url": "https://www.engadget.com/rss.xml", "site": "https://www.engadget.com", "description": "Gadgets and consumer electronics."}, {"title": "Hacker News", "url": "https://news.ycombinator.com/rss", "site": "https://news.ycombinator.com", "description": "Front page links from Y Combinator's community."}]}, {"id": "programming", "name": "Programming", "feeds": [{"title": "Lobsters", "url": "https://lobste.rs/rss", "site": "https://lobste.rs", "description": "A computing-focused link aggregator."}, {"title": "Hacker News: Best", "url": "https://hnrss.org/best", "site": "https://news.ycombinator.com/best", "description": "The highest-voted recent Hacker News stories."}, {"title": "Simon Willison", "url": "https://simonwillison.net/atom/everything/", "site": "https://simonwillison.net", "description": "Notes on LLMs, Python, Datasette, and the web."}, {"title": "Julia Evans", "url": "https://jvns.ca/atom.xml", "site": "https://jvns.ca", "description": "Friendly explanations of how computers work."}, {"title": "Martin Fowler", "url": "https://martinfowler.com/feed.atom", "site": "https://martinfowler.com", "description": "Software design, architecture, and agile delivery."}, {"title": "The GitHub Blog", "url": "https://github.blog/feed/", "site": "https://github.blog", "description": "Updates, ideas, and engineering from GitHub."}, {"title": "This Week in Rust", "url": "https://this-week-in-rust.org/rss.xml", "site": "https://this-week-in-rust.org", "description": "Weekly Rust community news."}]}, {"id": "ai", "name": "AI", "feeds": [{"title": "Hugging Face Blog", "url": "https://huggingface.co/blog/feed.xml", "site": "https://huggingface.co/blog", "description": "Open models, datasets, and machine learning tools."}, {"title": "Import AI", "url": "https://importai.substack.com/feed", "site": "https://importai.substack.com", "description": "Jack Clark's weekly newsletter on AI research and policy."}, {"title": "Google AI", "url": "https://blog.google/technology/ai/rss/", "site": "https://blog.google/technology/ai/", "description": "AI news and research from Google."}, {"title": "MIT Technology Review: AI", "url": "https://www.technologyreview.com/topic/artificial-intelligence/feed", "site": "https://www.technologyreview.com/topic/artificial-intelligence/", "description": "Reporting on artificial intelligence."}, {"title": "The Gradient", "url": "https://thegradient.pub/rss/", "site": "https://thegradient.pub", "description": "Essays and perspectives on AI research."}]}, {"id": "science", "name": "Science", "feeds": [{"title": "Quanta Magazine", "url": "https://www.quantamagazine.org/feed/", "site": "https://www.quantamagazine.org", "description": "Mathematics, physics, biology, and computer science."}, {"title": "Nature", "url": "https://www.nature.com/nature.rss", "site": "https://www.nature.com", "description": "The international journal of science."}, {"title": "ScienceDaily", "url": "https://www.sciencedaily.com/rss/all.xml", "site": "https://www.sciencedaily.com", "description": "Breaking science news from research institutions."}, {"title": "New Scientist", "url": "https://www.newscientist.com/feed/home/", "site": "https://www.newscientist.com", "description": "Science and technology news."}]}, {"id": "space", "name": "Space", "feeds": [{"title": "NASA", "url": "https://www.nasa.gov/feed/", "site": "https://www.nasa.gov", "description": "News and features from NASA."}, {"title": "Space.com", "url": "https://www.space.com/feeds/all", "site": "https://www.space.com", "description": "Space exploration, astronomy, and skywatching."}, {"title": "SpaceNews", "url": "https://spacenews.com/feed/", "site": "https://spacenews.com", "description": "The space industry and space policy."}, {"title": "The Planetary Society", "url": "https://www.planetary.org/rss/articles", "site": "https://www.planetary.org", "description": "Planetary science and space advocacy."}]}, {"id": "news", "name": "World news", "feeds": [{"title": "BBC News: World", "url": "https://feeds.bbci.co.uk/news/world/rss.xml", "site": "https://www.bbc.com/news/world", "description": "International news from the BBC."}, {"title": "NPR News", "url": "https://feeds.npr.org/1001/rss.xml", "site": "https://www.npr.org", "description": "Top stories from NPR."}, {"title": "The Guardian: World", "url": "https://www.theguardian.com/world/rss", "site": "https://www.theguardian.com/world", "description": "World news from The Guardian."}, {"title": "Al Jazeera", "url": "https://www.aljazeera.com/xml/rss/all.xml", "site": "https://www.aljazeera.com", "description": "News from around the world."}, {"title": "The New York Times", "url": "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml", "site": "https://www.nytimes.com", "description": "Top stories from the Times home page."}]}, {"id": "business", "name": "Business", "feeds": [{"title": "Stratechery", "url": "https://stratechery.com/feed/", "site": "https://stratechery.com", "description": "Ben Thompson on the strategy and business of technology."}, {"title": "The Economist: Latest", "url": "https://www.economist.com/latest/rss.xml", "site": "https://www.economist.com", "description": "The latest from The Economist."}, {"title": "Harvard Business Review", "url": "https://feeds.hbr.org/harvardbusiness", "site": "https://hbr.org", "description": "Management ideas and research."}, {"title": "Marginal Revolution", "url": "https://marginalrevolution.com/feed", "site": "https://marginalrevolution.com", "description": "Economics blog by Tyler Cowen and Alex Tabarrok."}]}, {"id": "design", "name": "Design", "feeds": [{"title": "Smashing Magazine", "url": "https://www.smashingmagazine.com/feed/", "site": "https://www.smashingmagazine.com", "description": "Web design and front-end development."}, {"title": "CSS-Tricks", "url": "https://css-tricks.com/feed/", "site": "https://css-tricks.com", "description": "Tips, tricks, and techniques on CSS."}, {"title": "A List Apart", "url": "https://alistapart.com/main/feed/", "site": "https://alistapart.com", "description": "Design, development, and meaning of web content."}, {"title": "Dezeen", "url": "https://www.dezeen.com/feed/", "site": "https://www.dezeen.com", "description": "Architecture and design magazine."}, {"title": "Nielsen Norman Group", "url": "https://www.nngroup.com/feed/rss/", "site": "https://www.nngroup.com", "description": "Evidence-based user experience research."}]}, {"id": "apple", "name": "Apple", "feeds": [{"title": "Daring Fireball", "url": "https://daringfireball.net/feeds/main", "site": "https://daringfireball.net", "description": "John Gruber on Apple, technology, and design."}, {"title": "MacRumors", "url": "https://feeds.macrumors.com/MacRumors-All", "site": "https://www.macrumors.com", "description": "Apple news and rumors."}, {"title": "9to5Mac", "url": "https://9to5mac.com/feed/", "site": "https://9to5mac.com", "description": "Apple news, reviews, and how-tos."}, {"title": "Six Colors", "url": "https://sixcolors.com/feed/", "site": "https://sixcolors.com", "description": "Jason Snell and Dan Moren on Apple and technology."}, {"title": "Apple Newsroom", "url": "https://www.apple.com/newsroom/rss-feed.rss", "site": "https://www.apple.com/newsroom/", "description": "Official news from Apple."}]}, {"id": "gaming", "name": "Gaming", "feeds": [{"title": "Polygon", "url": "https://www.polygon.com/rss/index.xml", "site": "https://www.polygon.com", "description": "Video games, entertainment, and culture."}, {"title": "Rock Paper Shotgun", "url": "https://www.rockpapershotgun.com/feed", "site": "https://www.rockpapershotgun.com", "description": "PC gaming news and reviews."}, {"title": "Kotaku", "url": "https://kotaku.com/rss", "site": "https://kotaku.com", "description": "Gaming news and culture."}, {"title": "IGN", "url": "https://feeds.ign.com/ign/all", "site": "https://www.ign.com", "description": "Games, movies, and TV."}]}];
  const discoverPic = (a, b) =>
    "data:image/svg+xml;utf8," + encodeURIComponent(`<svg xmlns='http://www.w3.org/2000/svg' width='300' height='200'><defs><linearGradient id='g' x1='0' y1='0' x2='1' y2='1'><stop offset='0' stop-color='${a}'/><stop offset='1' stop-color='${b}'/></linearGradient></defs><rect width='300' height='200' fill='url(#g)'/><circle cx='220' cy='70' r='38' fill='rgba(255,255,255,0.25)'/><path d='M0 160 L90 100 L170 150 L240 110 L300 140 L300 200 L0 200Z' fill='rgba(0,0,0,0.22)'/></svg>`);
  const DISCOVER_ITEMS = [
    { title: "The quiet return of the RSS reader", author: "Nilay Patel", image_url: discoverPic("#f97316", "#be185d"), url: "https://example.com/1", published_at: D.mins(42) },
    { title: "What we learned shipping a feed parser in Rust", author: "Emma Roth", image_url: discoverPic("#3b82f6", "#1e1b4b"), url: "https://example.com/2", published_at: D.mins(60 * 5) },
    { title: "A field guide to Atom, RSS 2.0 and JSON Feed", author: "Tom Warren", image_url: null, url: "https://example.com/3", published_at: D.mins(60 * 26) },
    { title: "Why your blog should still have a feed, even in 2026, and how to make one people actually subscribe to", author: "Dan Seifert", image_url: discoverPic("#10b981", "#064e3b"), url: "https://example.com/4", published_at: D.mins(60 * 29) },
    { title: "Notes from a week without algorithms", author: null, image_url: discoverPic("#a855f7", "#312e81"), url: "https://example.com/5", published_at: D.mins(60 * 24 * 4) },
    { title: "The best e-readers for people who mostly read the web", author: "Sean Hollister", image_url: discoverPic("#64748b", "#0f172a"), url: "https://example.com/6", published_at: D.mins(60 * 24 * 9) },
  ];
  const DISCOVER_SEARCH_EXTRA = [
    { title: "Inside Rust", url: "https://blog.rust-lang.org/inside-rust/feed.xml", site: "https://blog.rust-lang.org/inside-rust", description: "Updates from the Rust project's teams and working groups.", subscribers: 8400 },
    { title: "Rust Blog", url: "https://blog.rust-lang.org/feed.xml", site: "https://blog.rust-lang.org", description: "Empowering everyone to build reliable and efficient software.", subscribers: 52100 },
  ];
  const discoverEntry = (f) => ({
    url: f.url,
    title: f.title,
    site_url: f.site,
    description: f.description || null,
    icon_url: null,
    subscribers: f.subscribers ?? null,
    items: [],
    already_subscribed: feeds.some((x) => x.url === f.url) || f.title === "Hacker News",
  });
  const DISCOVER_SITE = (query) => {
    const host = query.replace(/^https?:\/\//, "").replace(/^www\./, "").split("/")[0];
    const site = "https://" + host;
    return [
      { ...discoverEntry({ title: "The Verge", url: site + "/rss/index.xml", site, description: "The Verge is about technology and how it makes us feel." }), items: DISCOVER_ITEMS },
      { ...discoverEntry({ title: "The Verge: Tech", url: site + "/rss/tech/index.xml", site, description: "Tech news from The Verge." }), items: DISCOVER_ITEMS.slice(1) },
      { ...discoverEntry({ title: "The Verge: Science", url: site + "/rss/science/index.xml", site, description: "Science coverage from The Verge." }), items: DISCOVER_ITEMS.slice(2) },
    ];
  };

  const articles = D.ARTICLES.map(([title, feedId, ago, author, priority, reason, themeId], i) => {
    const feed = feeds.find((f) => f.id === feedId);
    return {
      id: "a" + String(i).padStart(3, "0"),
      feed_id: feedId,
      title,
      url: feed.site_url + "/p/" + i,
      author,
      content_html: null,
      content_text: null,
      published_at: D.mins(ago),
      fetched_at: D.mins(2),
      is_read: false,
      is_starred: i === 3 || i === 6,
      feedly_entry_id: null,
      comments_url: feedId === "hn" ? "https://news.ycombinator.com/item?id=" + (40000000 + i) : null,
      feed_title: feed.title,
      feed_icon_url: null,
      priority,
      reason,
      importance: priority,
      relevance: Math.max(1, Math.min(5, priority + ((i % 3) - 1))),
      affinity: 0,
      score: 0,
      __theme: themeId,
    };
  });

  for (const f of feeds) f.unread_count = articles.filter((a) => a.feed_id === f.id).length;

  const folders = D.FOLDERS.map(([id, name, group], i) => ({
    id,
    name,
    sort_order: i,
    is_smart: false,
    rules_json: null,
    created_at: D.now - 86400 * 90,
    feed_count: feeds.filter((f) => f.__group === group).length,
  }));

  const themes = D.THEMES.map(([id, label, summary, count]) => ({
    id,
    label,
    summary,
    created_at: D.mins(9),
    expires_at: D.now + 86400,
    article_count: count,
  }));

  const ARTICLE_BODY = [
    "<p>AWS, Azure, and GCP are not interchangeable. The cloud you pick at seed shapes your hiring, your bill, your architecture, and your technical debt for the next five years. Most comparison articles are written by people with affiliate links. This one isn't. Here's what actually matters for startups.</p>",
    "<h2>The question founders keep getting wrong</h2>",
    "<p>Every few months, a founder reaches out with some version of the same question: we're spinning up our infrastructure, should we go AWS, Azure, or GCP?</p>",
    "<p>They're usually hoping for a quick answer. AWS for everything. GCP if you're doing AI. Azure if you're enterprise. Done.</p>",
    "<p>I understand the appeal of that shortcut. I also know it's how startups end up locked into the wrong provider eighteen months later, staring at a migration cost that's larger than their original infrastructure budget.</p>",
    "<p>The real question isn't “which cloud is best?” It's “which cloud is best for your specific situation, right now, given where you're going?” Those are different questions, and the second one is expensive to get wrong.</p>",
    "<p>Together, AWS, Azure, and GCP control roughly 68% of the global cloud market. Market share is the least useful thing to know when you're making this decision. What follows is what I wish someone had told me before I spent years learning the architectural way.</p>",
    "<h2>First, the landscape in 2026</h2>",
    "<p>Let's get the market context out of the way quickly, because it matters more than the headline numbers suggest. The gap between the three providers has narrowed on compute and widened on everything else.</p>",
  ].join("\n");

  const SUMMARY_BULLETS = [
    "Cloud provider choice (AWS/Azure/GCP) is startup-defining and context-dependent — not a one-size answer.",
    "AWS wins on ecosystem and hiring pool; Azure on enterprise and Microsoft integration; GCP on AI/data engineering.",
    "Migration eighteen months in costs more than the original infrastructure budget, so optimize for reversibility.",
    "Pick based on your specific stack, your team's existing skills, and your customers — not on market share.",
  ].map((s) => "- " + s).join("\n");

  const SUMMARY_PROSE =
    "Cloud choice is a five-year commitment disguised as a one-week decision. AWS still wins on ecosystem depth, Azure on enterprise agreements, GCP on data engineering \u2014 but none of that survives a bad fit with the stack you already have.";

  // A stand-in picture per article, the way the dev newsstand draws them:
  // a gradient with a couple of shapes, keyed off the article id.
  const picture = (id) => {
    let hash = 0;
    for (const ch of id) hash = (hash * 31 + ch.charCodeAt(0)) >>> 0;
    const hue = hash % 360;
    const hue2 = (hue + 40 + (hash % 80)) % 360;
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="675" viewBox="0 0 1200 675"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="hsl(${hue},55%,42%)"/><stop offset="1" stop-color="hsl(${hue2},60%,18%)"/></linearGradient></defs><rect width="1200" height="675" fill="url(#g)"/><circle cx="${300 + (hash % 600)}" cy="${200 + (hash % 250)}" r="${120 + (hash % 90)}" fill="hsla(${hue2},70%,70%,0.25)"/><rect x="${100 + (hash % 300)}" y="420" width="${500 + (hash % 300)}" height="140" rx="24" fill="hsla(${hue},40%,90%,0.12)"/></svg>`;
    return "data:image/svg+xml;utf8," + encodeURIComponent(svg);
  };


  // The Today edition: the day's stories, ordered by importance, each with
  // the articles behind it. Ledes are already written.
  const todayMember = (i, type, representative) => ({
    article_id: articles[i].id,
    feed_id: articles[i].feed_id,
    feed_title: articles[i].feed_title,
    publication: articles[i].feed_title,
    feed_icon_url: null,
    title: articles[i].title,
    url: articles[i].url,
    author: articles[i].author,
    published_at: articles[i].published_at,
    membership_type: type,
    confidence: 0.9,
    is_representative: representative,
    is_read: false,
    is_starred: false,
  });
  const todayStory = (position, title, summary, lede, members, section) => ({
    edition_id: "ed-today",
    story_id: "story-" + position,
    story_revision_number: 1,
    position,
    section,
    snapshot_title: title,
    snapshot_summary: summary,
    snapshot_delta_summary: null,
    has_material_update: false,
    snapshot_source_count: members.length,
    snapshot_reason: null,
    is_unique_find: section === "unique_finds",
    lede,
    lede_source_article_id: articles[members[0]].id,
    is_consumed: position === 2,
    consumed_at: position === 2 ? D.now - 600 : null,
    representative_article_id: articles[members[0]].id,
    member_article_ids: members.map((i) => articles[i].id),
    member_articles: members.map((i, n) => todayMember(i, n === 0 ? "coverage" : "duplicate", n === 0)),
  });
  const TODAY_ITEMS = [
    todayStory(0, "Vercel breach lifted OAuth tokens from platform environment variables",
      "Attackers pulled live OAuth tokens from Vercel's build platform.",
      "Attackers pulled live OAuth tokens from environment variables on Vercel's build platform, which puts every project that kept secrets there in scope. Vercel has rotated platform keys and says customer tokens should be rotated by hand.",
      [1, 12], "top_stories"),
    todayStory(1, "Stateless agents, not model quality, are the bottleneck",
      "Four pieces converge on the same worry about agents without state.",
      "Four pieces land on the same worry this week: agents that cannot hold state across a session fail in ways their benchmarks never show.",
      [3, 2, 6], "widely_covered"),
    todayStory(2, "TypeScript 7.0 Beta ships the native compiler",
      "The Go port reaches beta with ten-times faster builds.",
      "The Go port of the TypeScript compiler reaches beta with ten-times faster builds. The major version bump signals real breaking changes in the compiler API.",
      [7, 20], "top_stories"),
    todayStory(3, "Senators push back on the plan to cut NIH and reorganize HHS",
      "The restructuring is no longer a foregone conclusion.",
      "Key Republican senators are pushing back on the proposed NIH cuts and HHS reorganization, so the restructuring is no longer a foregone conclusion.",
      [14], "top_stories"),
    todayStory(4, "Meta records employee mouse movements and keystrokes for AI training",
      "Workplace surveillance repackaged as training-data collection.",
      "Meta is capturing employee input to train internal models, raising workplace-surveillance concerns that regulators in two countries have already noticed.",
      [5], "top_stories"),
    todayStory(5, "Cloudflare rewrites Next.js as AI makes commercial open source cheap to fork",
      "A well-funded fork of a commercial open-source project.",
      "Cloudflare's rewrite is the clearest example yet of a well-funded company forking a commercial open-source project now that the rewrite itself is cheap.",
      [10], "updates"),
    todayStory(6, "A new proof settles the Kakeya conjecture in three dimensions", "A long-open conjecture falls.", null, [19], "unique_finds"),
    todayStory(7, "Rust 1.94 stabilizes trait upcasting", "A small release with one long-awaited feature.", null, [20], "unique_finds"),
    todayStory(8, "What we learned shipping a 200-node Jepsen suite", "Testing methodology at scale.", null, [22], "unique_finds"),
    todayStory(9, "Amazon's next-generation storage stack, explained", "An architecture deep dive.", null, [23], "unique_finds"),
  ];
  // Editorial summaries: a theme, the synthesis, each report's own supporting
  // quote and, where the reports state one, a headline number.
  const TODAY_EDITORIALS = [
    ["Security", "Attackers pulled live OAuth tokens from environment variables on Vercel's build platform. Vercel has rotated its platform keys and is asking customers to rotate tokens they stored there by hand.",
      ["Every project that kept secrets in platform environment variables should treat them as exposed.", "Customers should rotate any tokens stored in project settings."], null],
    ["AI", "Four pieces land on the same worry: agents that cannot hold state across a session fail in ways benchmarks never show. The fix they converge on is memory the agent owns, not a bigger model.",
      ["The model is rarely the problem. The missing state is.", "Benchmarks reset the world between tasks; real work does not."], null],
    ["Programming", "The Go port of the TypeScript compiler reaches beta with builds about ten times faster. The major version bump signals breaking changes in the compiler API.",
      ["Builds that took a minute now finish in about six seconds."], ["10×", "faster builds in the beta"]],
    ["Policy", "Key Republican senators are pushing back on the proposed NIH cuts and the HHS reorganization, so the restructuring is no longer a foregone conclusion.",
      ["We are not going to rubber-stamp a plan that guts the institutes."], null],
    ["Privacy", "Meta is capturing employee mouse movements and keystrokes to train internal models. Regulators in two countries have asked the company to explain the program.",
      ["Employees were told the data would improve internal tools, not that it would train models."], ["2", "regulators asking questions"]],
    ["Open source", "Cloudflare's rewrite of Next.js is the clearest example yet of a well-funded company forking a commercial open-source project now that rewriting it is cheap.",
      ["When a rewrite costs weeks instead of years, the moat is the community, not the code."], null],
    ["Science", "A new proof settles the Kakeya conjecture in three dimensions, closing a problem open for decades.", ["The three-dimensional case had resisted every approach since the 1970s."], null],
    ["Programming", "Rust 1.94 stabilizes trait upcasting, a small release with one long-awaited feature.", ["Trait upcasting has been the most requested feature for years."], null],
    ["Infrastructure", "A team describes running Jepsen across 200 nodes and what broke along the way.", ["The bugs we found were all in the glue, not the database."], ["200", "nodes under test"]],
    ["Infrastructure", "Amazon walks through its next-generation storage stack and why it rebuilt the metadata layer.", ["The metadata path, not the disks, set our latency floor."], null],
  ];
  TODAY_ITEMS.forEach((item, index) => {
    const [theme, summary, quotes, figure] = TODAY_EDITORIALS[index];
    item.editorial = {
      theme, summary,
      sources: item.member_articles.filter((m) => m.membership_type !== "duplicate")
        .map((m, n) => ({ article_id: m.article_id, quote: quotes[n] ?? quotes[0] })),
      figure: figure && { value: figure[0], label: figure[1] },
    };
  });
  // Earlier pages (a week each) rotate the same stories, so turning a page
  // visibly changes the front page instead of only the dateline.
  const pageItems = (turn) => turn === 0 ? TODAY_ITEMS : TODAY_ITEMS.map((_, n, all) => {
    const item = all[(n + turn * 3) % all.length];
    return { ...item, edition_id: "ed-week-" + turn, position: n, is_consumed: false, consumed_at: null };
  });
  let todayTurn = 0;
  const todayView = (window_) => {
    if (window_?.startsAt) todayTurn = Math.max(0, Math.round((D.now - window_.startsAt) / (7 * 86400)));
    const items = pageItems(todayTurn);
    return {
      edition: {
        id: todayTurn === 0 ? "ed-today" : "ed-week-" + todayTurn, title: "Today", scope: "all", story_limit: 10, status: "completed",
        starts_at: window_?.startsAt ?? D.now - (D.now % 86400), ends_at: window_?.endsAt ?? D.now - (D.now % 86400) + 86400,
        generated_at: D.mins(5), completed_at: D.mins(4), total_source_count: 24,
      },
      items,
      consumed_count: items.filter((i) => i.is_consumed).length,
      total_count: items.length,
    };
  };

  const ASK_ANSWER =
    "Article 2 briefly reports this. The author notes that Anthropic “dropped Claude Code from the Pro tier” and that the change requires a higher-tier subscription [1]. Two other pieces mention the pricing move in passing while covering agent tooling [3][5].\n\nNo dedicated coverage of OpenAI's next model or a competing release appears in these articles. Broaden the scope to all feeds if you want that.";

  const ARTICLE_ANSWER =
    "It doesn't name one cloud for every AI startup. Its rule of thumb is GCP when the product leans on managed data and ML services, and AWS when hiring and ecosystem breadth matter more.\n\nThe bigger point is reversibility: keep the first year's architecture portable, because a migration eighteen months in can cost more than the original infrastructure budget.";

  const ASK_SOURCES = [12, 1, 10, 9, 16, 15, 17].map((i, n) => ({
    id: articles[i].id,
    title: articles[i].title,
    feed_title: articles[i].feed_title,
    url: articles[i].url,
    published_at: articles[i].published_at,
    source_type: "article",
  }));

  const ORGANIZE_PROPOSALS = D.FOLDERS.map(([id, name, group]) => ({
    name,
    feed_ids: feeds.filter((f) => f.__group === group).map((f) => f.id),
  }));

  let SETTINGS = {
    ai: {
      provider: "anthropic",
      api_key: "sk-ant-demo",
      model: "claude-sonnet-5",
      endpoint: null,
      local_model_path: null,
      local_gpu_layers: null,
      local_preload: null,
      local_idle_evict_minutes: null,
      local_power_mode: null,
      models_directory: null,
      summary_length: "medium",
      summary_tone: "neutral",
      summary_format: "bullets",
      summary_custom_prompt: null,
      summary_custom_word_count: null,
      chat_provider: "anthropic",
      chat_model: "claude-sonnet-5",
      chat_api_key: "sk-ant-demo",
      chat_endpoint: null,
      local_chat_web_search: false,
      triage_user_prompt: null,
    },
    appearance: { theme: "dark", font_size: 14, show_excerpt_in_list: true },
    sync: { refresh_interval_minutes: 30, max_articles_per_feed: 100, recent_cap: 50, today_story_limit: 10 },
  };

  function filterArticles(filter) {
    const f = filter || {};
    let out = articles.slice();
    if (f.feed_id) out = out.filter((a) => a.feed_id === f.feed_id);
    if (f.feed_ids) out = out.filter((a) => f.feed_ids.includes(a.feed_id));
    if (f.theme_id) out = out.filter((a) => a.__theme === f.theme_id);
    if (f.is_starred != null) out = out.filter((a) => a.is_starred === f.is_starred);
    if (f.is_read != null) out = out.filter((a) => a.is_read === f.is_read);
    if (f.search) {
      const q = f.search.toLowerCase();
      out = out.filter((a) => a.title.toLowerCase().includes(q));
    }
    out.sort((a, b) => (b.published_at || 0) - (a.published_at || 0));
    const off = f.offset || 0;
    return f.limit != null ? out.slice(off, off + f.limit) : out.slice(off);
  }

  // Mirrors skim_inbox_score with no learned taste: both axes weigh equally.
  for (const a of articles) a.score = ((a.importance - 1) / 4) * 50 + ((a.relevance - 1) / 4) * 50;
  const inboxOrder = articles
    .slice()
    .sort((a, b) => b.score - a.score || (b.published_at || 0) - (a.published_at || 0));

  const HANDLERS = {
    list_feeds: () => feeds,
    // Feed discovery: the built-in catalog, a canned search, and a canned site.
    feed_catalog: () => DISCOVER_CATALOG.map((t) => ({ ...t, feeds: t.feeds.map(discoverEntry) })),
    search_feeds: ({ query }) => {
      const words = query.toLowerCase().split(/\s+/).filter(Boolean);
      const hits = DISCOVER_CATALOG.flatMap((t) => t.feeds.filter((f) =>
        words.every((w) => `${f.title} ${f.description} ${t.name}`.toLowerCase().includes(w))));
      return [...hits.map(discoverEntry), ...DISCOVER_SEARCH_EXTRA.map(discoverEntry)];
    },
    discover_feeds: ({ query }) => DISCOVER_SITE(query),
    preview_feed: ({ url }) => ({ ...discoverEntry({ title: "", url, site: url, description: "" }), items: DISCOVER_ITEMS }),
    add_feed: async ({ url }) => {
      await new Promise((r) => setTimeout(r, 400));
      return { id: "new-" + url, title: url, url };
    },
    list_folders: () => folders,
    get_settings: () => SETTINGS,
    // Persist, so a picker in a popover shows what was just chosen.
    update_settings: ({ settings }) => { SETTINGS = settings; return null; },
    get_total_unread: () => articles.filter((a) => !a.is_read).length,
    refresh_all_feeds: () => 0,
    refresh_feed: () => 0,
    triage_articles: () => ({ triaged_count: articles.length, batches: 2, errors: [] }),
    get_articles: ({ filter }) => filterArticles(filter),
    count_articles: ({ filter }) => filterArticles(filter).length,
    get_article: ({ articleId }) => articles.find((a) => a.id === articleId) || articles[0],
    get_inbox_articles: ({ minPriority, limit, offset, feedIds, isRead }) => {
      let out = inboxOrder;
      if (minPriority != null) out = out.filter((a) => a.priority >= minPriority);
      if (feedIds) out = out.filter((a) => feedIds.includes(a.feed_id));
      if (isRead === false) out = out.filter((a) => !a.is_read);
      const off = offset || 0;
      return limit != null ? out.slice(off, off + limit) : out.slice(off);
    },
    get_triage_stats: () => ({
      total: articles.length,
      by_priority: articles.reduce((acc, a) => ((acc[a.priority] = (acc[a.priority] || 0) + 1), acc), {}),
    }),
    get_themes: () => themes,
    generate_themes: () => themes,
    get_article_theme_tags: () =>
      articles.filter((a) => a.__theme).map((a) => ({
        article_id: a.id,
        theme_id: a.__theme,
        theme_label: (themes.find((t) => t.id === a.__theme) || {}).label || "",
      })),
    get_recent_articles: () =>
      articles.slice(0, 8).map((a, i) => ({
        ...a,
        reading_time_sec: 120 - i * 9,
        chat_messages: i % 3,
        interaction_at: D.mins(20 + i * 30),
        engagement_score: 1 - i * 0.08,
      })),
    count_read_matches: () => 0,
    get_or_fetch_reader_content: () => ({ html: ARTICLE_BODY, raw_html: ARTICLE_BODY }),
    get_cached_reader_content: () => ({ html: ARTICLE_BODY, raw_html: ARTICLE_BODY }),
    fetch_full_article: () => ({ html: ARTICLE_BODY, raw_html: ARTICLE_BODY }),
    fetch_aggregator_details: () => null,
    summarize_article: ({ articleId }) => ({
      article_id: articleId,
      bullet_summary: SUMMARY_BULLETS,
      full_summary: SUMMARY_PROSE,
      provider: "anthropic",
      model: "claude-sonnet-5",
      created_at: D.now,
    }),
    get_or_generate_today_edition: (args) => todayView(args),
    list_today_edition_items: ({ editionId } = {}) => pageItems(editionId?.startsWith("ed-week-") ? Number(editionId.slice(8)) : 0),
    generate_today_ledes: () => todayView(),
    generate_today_editorial: () => todayView(),
    // Report images are opt-in so a run shows the no-image page by default.
    get_today_story_image: ({ articleIds }) => (window.__SKIM_TODAY_IMAGES__ || {})[articleIds[0]] ?? null,
    set_today_edition_item_consumed: ({ storyId, isConsumed }) => {
      const item = TODAY_ITEMS.find((i) => i.story_id === storyId);
      if (item) item.is_consumed = isConsumed;
      return todayView();
    },
    chat_with_articles: () => ({
      content: ASK_ANSWER,
      provider: "anthropic",
      model: "claude-sonnet-5",
      article_ids: ASK_SOURCES.map((s) => s.id),
      sources: ASK_SOURCES,
    }),
    chat_with_article: () => ({ content: ARTICLE_ANSWER, provider: "anthropic", model: "claude-sonnet-5" }),
    // The app agent: a keyword search over the fixtures, answered as a list.
    ask_agent: async ({ messages }) => {
      await new Promise((resolve) => setTimeout(resolve, 400));
      const question = messages[messages.length - 1].content;
      const stop = new Set(["where", "what", "which", "article", "articles", "about", "there", "that", "this", "with", "from", "find", "anything"]);
      const terms = question.toLowerCase().split(/[^a-z0-9]+/).filter((w) => w.length >= 4 && !stop.has(w));
      const stem = (t) => t.replace(/s$/, "");
      const hits = articles.filter((a) => terms.some((t) => a.title.toLowerCase().includes(stem(t)))).slice(0, 4);
      const sources = hits.map((a) => ({ id: a.id, title: a.title, feed_title: a.feed_title, url: a.url, published_at: a.published_at, source_type: "article" }));
      const content = hits.length
        ? `${hits.length} ${hits.length === 1 ? "article covers" : "articles cover"} this:\n\n${hits.map((a, i) => `- [${i + 1}] **${a.title}** (${a.feed_title})`).join("\n")}\n\n[1] is the most direct match.`
        : "Nothing in your articles matches that.";
      return {
        content, provider: "anthropic", model: "claude-sonnet-5", sources,
        article_ids: sources.map((s) => s.id), actions: [],
        steps: [{ tool: "search_articles", label: `Searched for “${terms.join(" ")}”` }],
      };
    },
    ai_auto_organize_feeds: () => ORGANIZE_PROPOSALS,
    apply_folder_organization: () => folders,
    list_duplicate_feeds: () => [],
    get_feedly_status: () => null,
    feedly_oauth_available: () => false,
    claude_oauth_status: () => false,
    get_preference_profile: () => ({
      top_feeds: ["hn", "pragmatic", "simonw"],
      preferred_topics: ["AI agents", "distributed systems", "security"],
      deprioritized_topics: ["gaming", "US domestic politics"],
      avg_reading_time_sec: 148,
      total_interactions: 412,
    }),
    get_article_interaction: () => null,
    get_offline_cache_stats: () => ({ extracted_articles: 42 }),
    list_local_models: () => [],
    get_system_info: () => ({ total_memory_gb: 32, available_memory_gb: 18, max_model_size_gb: 12 }),
    ds4_status: () => ({ runtime_available: false, running: false, model_path: null, error: null }),
    list_remote_models: () => [
      { id: "claude-opus-5", display_name: "Claude Opus 5" },
      { id: "claude-sonnet-5", display_name: "Claude Sonnet 5" },
    ],
    web_search: () => [],
  };

  // Commands the UI may call that need nothing more than "ok".
  const VOID_OK = new Set([
    "mark_articles_read", "mark_articles_unread", "mark_all_read",
    "record_reading_time", "set_article_feedback", "set_priority_override",
    "remove_recent_article", "cancel_summarize", "cancel_download", "assign_feed_to_folder",
    "reorder_folders", "delete_folder", "rename_folder", "remove_feed", "rename_feed",
  ]);

  const listeners = new Map();
  let callbackId = 0;
  // Delivers a backend event to every listener registered for it.
  const emit = (event, payload) => {
    for (const [handler, name] of listeners) {
      if (name === event && typeof window["_" + handler] === "function") {
        window["_" + handler]({ event, id: handler, payload });
      }
    }
  };
  window.__SKIM_EMIT__ = emit;
  window.__TAURI_EVENT_PLUGIN_INTERNALS__ = {
    unregisterListener(_event, handler) { listeners.delete(handler); },
  };

  window.__TAURI_INTERNALS__ = {
    transformCallback(cb, once) {
      const id = ++callbackId;
      window["_" + id] = (payload) => {
        if (once) delete window["_" + id];
        return cb(payload);
      };
      return id;
    },
    unregisterCallback(id) {
      delete window["_" + id];
    },
    convertFileSrc(p) {
      return p;
    },
    async invoke(cmd, args) {
      args = args || {};
      if (cmd === "plugin:event|listen") {
        listeners.set(args.handler, args.event);
        return args.handler;
      }
      if (cmd === "plugin:event|unlisten" || cmd === "plugin:event|emit") return null;
      if (cmd.startsWith("plugin:opener|")) return null;
      if (cmd.startsWith("plugin:skim-ai|")) throw new Error("command not found");
      if (VOID_OK.has(cmd)) return null;
      const h = HANDLERS[cmd];
      if (h) return h(args);
      if (window.__SKIM_MOCK_WARN__) console.warn("[mock] unhandled command:", cmd, args);
      return null;
    },
  };

  window.__SKIM_MOCK_WARN__ = true;
})();
