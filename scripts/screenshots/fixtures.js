// Demo data for the README capture harness. Plausible-looking tech-feed
// content so the screenshots read like a real install without shipping
// anyone's actual reading list.
//
// Loaded by mock-backend.js, which is injected into the page before the app
// boots. Plain browser JS on purpose: it runs as a Playwright init script.
/* eslint-disable */
(function () {
  const now = Math.floor(Date.now() / 1000);
  const mins = (m) => now - m * 60;

  const FEEDS = [
    ["hn", "Hacker News", "https://news.ycombinator.com", "aggregators"],
    ["lobsters", "Lobsters", "https://lobste.rs", "aggregators"],
    ["pragmatic", "The Pragmatic Engineer", "https://newsletter.pragmaticengineer.com", "engineering"],
    ["fowler", "Martin Fowler", "https://martinfowler.com", "engineering"],
    ["norvig", "Peter Norvig", "https://norvig.com", "engineering"],
    ["yegge", "Stevey's Blog Rants", "https://steve-yegge.medium.com", "engineering"],
    ["brooker", "Marc Brooker's Blog", "https://brooker.co.za/blog", "distributed"],
    ["aphyr", "Aphyr — Jepsen", "https://aphyr.com", "distributed"],
    ["allthings", "All Things Distributed", "https://allthingsdistributed.com", "distributed"],
    ["highscale", "High Scalability", "https://highscalability.com", "distributed"],
    ["morningpaper", "the morning paper", "https://blog.acolyer.org", "research"],
    ["arxivml", "arXiv cs.LG", "https://arxiv.org/list/cs.LG/recent", "research"],
    ["simonw", "Simon Willison's Weblog", "https://simonwillison.net", "ai"],
    ["anthropic", "Anthropic — News", "https://www.anthropic.com/news", "ai"],
    ["ainews", "Import AI", "https://importai.substack.com", "ai"],
    ["stratechery", "Stratechery", "https://stratechery.com", "business"],
    ["economist", "The Economist — Finance", "https://economist.com", "business"],
    ["statnews", "STAT News", "https://statnews.com", "science"],
    ["quanta", "Quanta Magazine", "https://quantamagazine.org", "science"],
    ["phoronix", "Phoronix", "https://phoronix.com", "systems"],
    ["lwn", "LWN.net", "https://lwn.net", "systems"],
    ["rustblog", "Rust Blog", "https://blog.rust-lang.org", "systems"],
  ];

  const FOLDERS = [
    ["f-aggregators", "Aggregators", "aggregators"],
    ["f-engineering", "Software craft", "engineering"],
    ["f-distributed", "Distributed systems", "distributed"],
    ["f-ai", "AI & models", "ai"],
    ["f-research", "Papers", "research"],
    ["f-systems", "Systems & kernels", "systems"],
  ];

  // title, feed, minutesAgo, author, priority, reason, themeId
  const ARTICLES = [
    ["Why “Just Pick AWS” Is Bad Advice in 2026", "pragmatic", 41, "Gergely Orosz", 5,
      "Directly challenges a default you rely on, with cost numbers you can act on.", "t-cloud"],
    ["The Vercel breach: OAuth tokens lifted from platform environment variables", "hn", 62, "chrisdavies", 5,
      "Active supply-chain incident affecting a platform in your stack.", "t-security"],
    ["CrabTrap: an LLM-as-a-judge HTTP proxy for securing agents in production", "lobsters", 88, "pushcx", 4,
      "New tooling in the agent-safety space you have been tracking.", "t-agents"],
    ["Stateless AI agents are the real problem", "yegge", 115, "Steve Yegge", 4,
      "Strong architectural argument from an author you read closely.", "t-agents"],
    ["Using QUIC backscatter to infer hyperagent deployment configurations", "brooker", 133, "Marc Brooker", 4,
      "Novel measurement technique with immediate relevance to your edge work.", "t-networks"],
    ["Meta starts capturing employee mouse movements and keystrokes for AI training", "hn", 151, "tptacek", 4,
      "Workplace-surveillance story with a policy angle you follow.", "t-privacy"],
    ["25 things the Claude Code leak reveals about Anthropic's agents", "simonw", 168, "Simon Willison", 4,
      "Detailed teardown of an agent harness you work with daily.", "t-agents"],
    ["TypeScript 7.0 Beta: the native compiler lands", "lobsters", 190, "steveklabnik", 3,
      "Major version bump in a language you ship in every day.", "t-languages"],
    ["Cal.diy: an open-source community edition of cal.com", "hn", 205, "dang", 3,
      "Open-source alternative in a category you evaluated last quarter.", null],
    ["Fragments: February 19", "fowler", 233, "Martin Fowler", 3,
      "Regular column from an author on your must-read list.", null],
    ["The Pulse: Cloudflare rewrites Next.js as AI rewrites commercial open source", "pragmatic", 258, "Gergely Orosz", 3,
      "Industry analysis touching two dependencies you maintain.", "t-oss"],
    ["SysMoBench: evaluating AI on formally modeling complex real-world systems", "arxivml", 290, "Y. Chen et al.", 3,
      "Benchmark paper in the formal-methods-meets-LLM area you saved before.", "t-research"],
    ["The volunteer DDoS: why AI security tools are breaking the infrastructure they're meant to protect", "highscale", 320, "Todd Hoff", 3,
      "Infrastructure failure mode you have hit in production.", "t-security"],
    ["Insurers refuse to join Medicare pilot offering weight-loss drugs to seniors", "statnews", 352, "Elaine Chen", 2,
      "Health-policy item outside your core topics.", "t-health"],
    ["Key Republican senators push back on the plan to cut NIH and reorganize HHS", "statnews", 375, "Sarah Owermohle", 2,
      "Policy development with second-order effects on research funding.", "t-health"],
    ["I stopped trying to keep up with AI: here's what happened instead", "yegge", 402, "Steve Yegge", 2,
      "Opinion piece; interesting but not actionable this week.", null],
    ["The AI vampire", "yegge", 430, "Steve Yegge", 2, "Essay, low urgency.", null],
    ["Why 90% of CS2 players are losing money on their skins", "hn", 466, "ingve", 1,
      "Off-topic for your current reading patterns.", null],
    ["Opinion: I'm an expert on presidential health. The 25th Amendment is not an option.", "statnews", 502, "Jonathan Reiner", 1,
      "Outside every topic you engage with.", null],
    ["A new proof settles the Kakeya conjecture in three dimensions", "quanta", 540, "Jordana Cepelewicz", 3,
      "Major result in an area you follow casually.", "t-research"],
    ["Rust 1.94: trait upcasting stabilizes", "rustblog", 578, "The Rust Release Team", 3,
      "Release notes for a language in your toolchain.", "t-languages"],
    ["Linux 6.20 drops the last big-endian MIPS holdouts", "phoronix", 610, "Michael Larabel", 2,
      "Kernel churn unrelated to platforms you ship.", null],
    ["What we learned shipping a 200-node Jepsen suite", "aphyr", 655, "Kyle Kingsbury", 4,
      "Testing methodology you can lift directly into your own suite.", "t-networks"],
    ["Amazon's next-generation storage stack, explained", "allthings", 700, "Werner Vogels", 3,
      "Architecture deep dive adjacent to your storage work.", "t-cloud"],
  ];

  const THEMES = [
    ["t-agents", "AI Agents: risks & reality", "Four pieces converge on the same worry: agents that cannot hold state across a session fail in ways their benchmarks never show.", 4],
    ["t-security", "Security vulnerabilities", "A platform breach and a set of AI security tools that generate more load than they prevent.", 2],
    ["t-cloud", "Cloud & infrastructure", "Cost and lock-in arguments against defaulting to a single hyperscaler, plus a storage-stack teardown.", 2],
    ["t-languages", "Languages & compilers", "TypeScript's native compiler beta and a Rust release that stabilizes trait upcasting.", 2],
    ["t-research", "Research & papers", "A formal-modeling benchmark for LLMs and a long-open conjecture in three dimensions.", 2],
    ["t-privacy", "Surveillance & data privacy", "Employee monitoring repackaged as training-data collection.", 1],
    ["t-health", "Pharma & health policy", "Medicare drug-pilot fallout and proposed NIH restructuring.", 2],
    ["t-networks", "Networks & testing", "Measurement tricks and a very large Jepsen suite.", 2],
    ["t-oss", "Open source & business", "What happens to commercial open source when the rewrite is cheap.", 1],
  ];

  window.__SKIM_DEMO__ = { now, mins, FEEDS, FOLDERS, ARTICLES, THEMES };
})();
