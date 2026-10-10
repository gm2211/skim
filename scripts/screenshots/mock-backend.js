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

  // The Quick Catch-up front page: a handful of stories, biggest first, each
  // backed by the articles behind it, then one-line briefs below the fold.
  const catchupSource = (i, withPicture) => ({
    id: articles[i].id,
    title: articles[i].title,
    publication: articles[i].feed_title,
    url: articles[i].url,
    published_at: articles[i].published_at,
    image_url: withPicture ? picture(articles[i].id) : null,
    icon_url: null,
  });
  const CATCHUP = {
    stories: [
      {
        headline: "Vercel breach lifted OAuth tokens straight out of platform environment variables",
        lede: "Attackers pulled live OAuth tokens from environment variables on Vercel's build platform, which puts every project that kept secrets there in scope. Vercel has rotated platform keys and says customer tokens should be rotated by hand; two large customers have already reported downstream access.",
        article_ids: ["a001", "a012"],
        image_url: picture("a001"),
      },
      {
        headline: "Stateless agents, not model quality, are the bottleneck",
        lede: "Four pieces land on the same worry this week: agents that cannot hold state across a session fail in ways their benchmarks never show, and the fixes being proposed are harnesses and proxies rather than bigger models.",
        article_ids: ["a003", "a002", "a006"],
        image_url: picture("a003"),
      },
      {
        headline: "TypeScript 7.0 Beta ships the native compiler",
        lede: "The Go port of the TypeScript compiler reaches beta with ten-times faster builds. The major version bump signals real breaking changes in the compiler API rather than a routine release.",
        article_ids: ["a007", "a020"],
        image_url: picture("a007"),
      },
      {
        headline: "Senators push back on the plan to cut NIH and reorganize HHS",
        lede: "Key Republican senators are pushing back on the proposed NIH cuts and HHS reorganization, so the restructuring is no longer a foregone conclusion.",
        article_ids: ["a014"],
        image_url: picture("a014"),
      },
      {
        headline: "Meta records employee mouse movements and keystrokes for AI training",
        lede: "Meta is capturing employee input to train internal models, raising workplace-surveillance concerns that regulators in two countries have already noticed.",
        article_ids: ["a005"],
        image_url: null,
      },
      {
        headline: "Cloudflare rewrites Next.js as AI makes commercial open source cheap to fork",
        lede: "Cloudflare's rewrite is the clearest example yet of a well-funded company forking a commercial open-source project now that the rewrite itself is cheap.",
        article_ids: ["a010"],
        image_url: picture("a010"),
      },
    ],
    briefs: [
      { text: "A new proof settles the Kakeya conjecture in three dimensions.", article_ids: ["a019"] },
      { text: "Rust 1.94 stabilizes trait upcasting.", article_ids: ["a020"] },
      { text: "Aphyr wrote up what they learned running a 200-node Jepsen suite.", article_ids: ["a022"] },
      { text: "Amazon explains its next-generation storage stack.", article_ids: ["a023"] },
    ],
    sources: [
      catchupSource(1, true), catchupSource(12, true), catchupSource(3, true), catchupSource(2, true),
      catchupSource(6, false), catchupSource(7, true), catchupSource(20, false), catchupSource(14, true),
      catchupSource(5, false), catchupSource(10, true), catchupSource(19, false), catchupSource(22, false),
      catchupSource(23, true),
    ],
    article_count: 24,
  };
  window.__SKIM_CATCHUP__ = CATCHUP;

  const ASK_ANSWER =
    "Article 2 briefly reports this. The author notes that Anthropic “dropped Claude Code from the Pro tier” and that the change requires a higher-tier subscription [1]. Two other pieces mention the pricing move in passing while covering agent tooling [3][5].\n\nNo dedicated coverage of OpenAI's next model or a competing release appears in these articles. Broaden the scope to all feeds if you want that.";

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

  const SETTINGS = {
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

  const inboxOrder = articles
    .slice()
    .sort((a, b) => b.priority - a.priority || (b.published_at || 0) - (a.published_at || 0));

  const HANDLERS = {
    list_feeds: () => feeds,
    list_folders: () => folders,
    get_settings: () => SETTINGS,
    get_total_unread: () => articles.filter((a) => !a.is_read).length,
    refresh_all_feeds: () => 0,
    refresh_feed: () => 0,
    triage_articles: () => ({ triaged_count: articles.length, batches: 2, errors: [] }),
    get_articles: ({ filter }) => filterArticles(filter),
    count_articles: ({ filter }) => filterArticles(filter).length,
    get_article: ({ articleId }) => articles.find((a) => a.id === articleId) || articles[0],
    get_inbox_articles: ({ minPriority, limit, offset }) => {
      let out = inboxOrder;
      if (minPriority != null) out = out.filter((a) => a.priority >= minPriority);
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
    // With `window.__SKIM_CATCHUP_WRITTEN__` set, the page is shown mid-run:
    // that many stories have their lede, the next is being written, and the
    // run never finishes, so a capture can show the page filling in.
    generate_catchup_report: ({ runId }) => {
      const written = window.__SKIM_CATCHUP_WRITTEN__;
      if (written == null) return CATCHUP;
      // A negative count is the first pass, still reading: no page yet.
      const stories = written < 0 ? [] : CATCHUP.stories.map((story, i) => (i < written ? story : { ...story, lede: "" }));
      setTimeout(() => {
        emit("catchup_progress", {
          stage: written < 0 ? "reading" : "writing",
          completed: Math.max(0, written),
          total: CATCHUP.stories.length,
          message: written < 0 ? "Reading 24 articles…" : `Writing story ${written + 1} of ${CATCHUP.stories.length}…`,
          report: { ...CATCHUP, stories, briefs: [] },
          run_id: runId,
        });
      }, 50);
      return new Promise(() => {});
    },
    cancel_catchup_report: () => null,
    chat_with_articles: () => ({
      content: ASK_ANSWER,
      provider: "anthropic",
      model: "claude-sonnet-5",
      article_ids: ASK_SOURCES.map((s) => s.id),
      sources: ASK_SOURCES,
    }),
    chat_with_article: () => ({ content: ASK_ANSWER, provider: "anthropic", model: "claude-sonnet-5" }),
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
    "mark_articles_read", "mark_articles_unread", "mark_all_read", "update_settings",
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
