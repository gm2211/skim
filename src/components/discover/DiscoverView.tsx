import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { openUrl } from "@tauri-apps/plugin-opener";
import { addFeed, discoverFeeds, feedCatalog, previewFeed, searchFeeds } from "../../services/commands";
import type { DiscoveredFeed, FeedCatalogTopic, FeedPreviewItem } from "../../services/types";
import { useUiStore } from "../../stores/uiStore";
import { CollapsedSidebarTitlebar } from "../layout/CollapsedSidebarTitlebar";
import { compactCount, dayLabel, displayHost, looksLikeUrl, shortAge } from "../../lib/feedDiscovery";
import { topicStyle, TopicGlyph } from "./topicStyle";
import "./DiscoverView.css";

/** Where the reader is inside Discover. Each push keeps the page it came from. */
type Page =
  | { kind: "home" }
  | { kind: "topic"; topicId: string }
  | { kind: "feed"; feed: DiscoveredFeed; from: string };

type FollowState = "following" | "adding" | { error: string };

const errorText = (e: unknown) => String(e instanceof Error ? e.message : e);

function useDebounced<T>(value: T, ms: number): T {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const t = window.setTimeout(() => setDebounced(value), ms);
    return () => window.clearTimeout(t);
  }, [value, ms]);
  return debounced;
}

/**
 * A Feedly-style place to find feeds: browse topics, open a feed to read its
 * latest posts, and follow it. Pasting a site lists the feeds found on it;
 * typing words searches feeds by topic or name.
 */
export function DiscoverView() {
  const [stack, setStack] = useState<Page[]>([{ kind: "home" }]);
  const [follow, setFollow] = useState<Record<string, FollowState>>({});
  const isPhone = useUiStore((s) => s.isPhone);
  const sidebarCollapsed = useUiStore((s) => s.sidebarCollapsed);
  const scrollRef = useRef<HTMLDivElement>(null);
  const qc = useQueryClient();
  const catalog = useQuery({ queryKey: ["feedCatalog"], queryFn: feedCatalog, staleTime: 60_000 });
  const topics = catalog.data ?? [];
  const page = stack[stack.length - 1];

  const push = (next: Page) => {
    setStack((s) => [...s, next]);
    if (scrollRef.current) scrollRef.current.scrollTop = 0;
  };
  const pop = () => setStack((s) => (s.length > 1 ? s.slice(0, -1) : s));

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape" && stack.length > 1 && !(e.target instanceof HTMLInputElement)) {
        e.preventDefault();
        pop();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [stack.length]);

  const isFollowing = (feed: DiscoveredFeed) => feed.already_subscribed || follow[feed.url] === "following";

  const followFeed = async (feed: DiscoveredFeed) => {
    setFollow((s) => ({ ...s, [feed.url]: "adding" }));
    try {
      await addFeed(feed.url);
      setFollow((s) => ({ ...s, [feed.url]: "following" }));
    } catch (e) {
      const message = errorText(e);
      // add_feed refuses duplicates; to the reader that is already following.
      setFollow((s) => ({ ...s, [feed.url]: message.startsWith("Already subscribed") ? "following" : { error: message } }));
      if (!message.startsWith("Already subscribed")) return;
    }
    await Promise.all(
      ["feeds", "articles", "articleCount", "todayEdition", "feedCatalog"].map((key) =>
        qc.invalidateQueries({ queryKey: [key] }),
      ),
    );
  };

  const followProps = (feed: DiscoveredFeed) => ({
    following: isFollowing(feed),
    state: follow[feed.url],
    onFollow: () => void followFeed(feed),
  });

  const openFeed = (feed: DiscoveredFeed, from: string) => push({ kind: "feed", feed, from });

  return (
    <div className="discover-page bg-bg-secondary/70 flex flex-col h-full overflow-hidden" style={{ flex: 1, minWidth: 0 }}>
      {sidebarCollapsed && !isPhone && <CollapsedSidebarTitlebar />}
      <div className="discover-topbar flex flex-shrink-0 items-center gap-1 relative z-20" data-tauri-drag-region>
        {isPhone && stack.length === 1 && (
          <button
            onClick={() => useUiStore.getState().setPhonePane("sidebar")}
            className="tap-target text-text-muted hover:text-text-primary transition-colors rounded-lg hover:bg-white/10"
            aria-label="Open sidebar"
          >
            <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" aria-hidden="true">
              <path d="M3 6h18M3 12h18M3 18h18" />
            </svg>
          </button>
        )}
        {stack.length > 1 && (
          <button onClick={pop} className="discover-back text-text-secondary hover:text-text-primary rounded-lg hover:bg-white/10">
            <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" strokeLinecap="round" aria-hidden="true">
              <path d="m15 6-6 6 6 6" />
            </svg>
            {backLabel(stack[stack.length - 2], topics)}
          </button>
        )}
        <div className="flex-1" />
        <button
          onClick={() => useUiStore.getState().setShowAddFeed(true, "feedly")}
          className="text-text-secondary hover:text-text-primary rounded-lg hover:bg-white/10"
          style={{ fontSize: 13, padding: "6px 10px" }}
        >
          Import OPML
        </button>
      </div>

      <div ref={scrollRef} className="flex-1 overflow-y-auto">
        <div className="discover-content">
          {page.kind === "home" && (
            <HomePage
              topics={topics}
              loading={catalog.isLoading}
              onTopic={(id) => push({ kind: "topic", topicId: id })}
              onFeed={(feed) => openFeed(feed, "Discover")}
              followProps={followProps}
            />
          )}
          {page.kind === "topic" && (
            <TopicPage
              topic={topics.find((t) => t.id === page.topicId)}
              topics={topics}
              onTopic={(id) => setStack((s) => [...s.slice(0, -1), { kind: "topic", topicId: id }])}
              onFeed={(feed, from) => openFeed(feed, from)}
              followProps={followProps}
            />
          )}
          {page.kind === "feed" && <FeedPage feed={page.feed} {...followProps(page.feed)} />}
        </div>
      </div>
    </div>
  );
}

function backLabel(page: Page, topics: FeedCatalogTopic[]): string {
  if (page.kind === "home") return "Discover";
  if (page.kind === "topic") return topics.find((t) => t.id === page.topicId)?.name ?? "Back";
  return page.feed.title;
}

type FollowProps = (feed: DiscoveredFeed) => { following: boolean; state: FollowState | undefined; onFollow: () => void };

// MARK: Home

function HomePage({ topics, loading, onTopic, onFeed, followProps }: {
  topics: FeedCatalogTopic[];
  loading: boolean;
  onTopic: (id: string) => void;
  onFeed: (feed: DiscoveredFeed) => void;
  followProps: FollowProps;
}) {
  const [input, setInput] = useState("");
  const trimmed = input.trim();
  const isUrl = looksLikeUrl(trimmed);
  const debounced = useDebounced(trimmed, isUrl ? 650 : 350);
  const settled = debounced === trimmed;
  const results = useQuery({
    queryKey: ["feedDiscovery", isUrl ? "site" : "search", debounced],
    queryFn: () => (looksLikeUrl(debounced) ? discoverFeeds(debounced) : searchFeeds(debounced)),
    enabled: debounced.length >= 2,
    staleTime: 5 * 60_000,
    retry: false,
  });
  const searching = trimmed.length >= 2 && (!settled || results.isFetching);
  const list = trimmed.length >= 2 && settled ? results.data : undefined;
  const featured = topics.slice(0, 3);

  return (
    <>
      <header className="discover-hero">
        <h1 className="text-text-primary">Discover</h1>
        <p className="text-text-secondary">Follow sites, blogs, subreddits and channels.</p>
        <SearchBox value={input} onChange={setInput} />
      </header>

      {trimmed.length >= 2 ? (
        <section aria-label="Search results">
          <p className="discover-status text-text-muted" role="status">
            {searching
              ? isUrl
                ? `Looking for feeds on ${displayHost(trimmed.includes("://") ? trimmed : `https://${trimmed}`)}…`
                : `Searching for “${trimmed}”…`
              : results.isError
                ? ""
                : list
                  ? list.length === 0
                    ? `No feeds found for “${trimmed}”.`
                    : isUrl
                      ? `${list.length} feed${list.length === 1 ? "" : "s"} found`
                      : `Feeds matching “${trimmed}”`
                  : ""}
          </p>
          {results.isError && settled && !results.isFetching && <ErrorBox>{errorText(results.error)}</ErrorBox>}
          {searching && !list && <SkeletonRows />}
          {list && list.length > 0 && <FeedList feeds={list} onOpen={onFeed} followProps={followProps} />}
        </section>
      ) : (
        <>
          <h2 className="discover-label">Featured</h2>
          <div className="discover-featured">
            {loading
              ? [0, 1, 2].map((i) => <div key={i} className="discover-card discover-card--loading" />)
              : featured.map((t) => (
                  <button key={t.id} className="discover-card" style={{ background: topicStyle(t.id).gradient }} onClick={() => onTopic(t.id)}>
                    <span className="discover-card-name">{t.name}</span>
                    <span className="discover-card-count">{t.feeds.length} feeds</span>
                    <TopicGlyph id={t.id} size={84} className="discover-card-glyph" />
                  </button>
                ))}
          </div>

          <h2 className="discover-label">Topics</h2>
          <div className="discover-topics">
            {topics.map((t) => (
              <button key={t.id} className="discover-topic" onClick={() => onTopic(t.id)}>
                <span className="discover-topic-tile" style={{ background: topicStyle(t.id).gradient }}>
                  <TopicGlyph id={t.id} size={22} />
                </span>
                <span className="flex-1 min-w-0 text-left">
                  <span className="block text-text-primary truncate" style={{ fontSize: 15, fontWeight: 600 }}>{t.name}</span>
                  <span className="block text-text-muted truncate" style={{ fontSize: 12.5 }}>
                    {t.feeds.slice(0, 3).map((f) => f.title).join(", ")}
                  </span>
                </span>
                <Chevron />
              </button>
            ))}
          </div>
        </>
      )}
    </>
  );
}

function SearchBox({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const isPhone = useUiStore((s) => s.isPhone);
  return (
    <form role="search" onSubmit={(e) => e.preventDefault()} className="discover-search">
      <svg className="discover-search-icon text-text-muted" width="17" height="17" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
        <circle cx="11" cy="11" r="7" />
        <path d="m20 20-3.5-3.5" />
      </svg>
      <input
        type="text"
        inputMode="url"
        value={value}
        onChange={(e) => onChange(e.target.value)}
        placeholder={isPhone ? "Search, or paste a site URL" : "Type a name or topic, or paste a website URL"}
        aria-label="Search feeds, or paste a website URL"
        autoFocus={!isPhone}
        autoCapitalize="none"
        autoCorrect="off"
        spellCheck={false}
        className="text-text-primary placeholder-text-muted"
      />
      {value && (
        <button type="button" onClick={() => onChange("")} aria-label="Clear search" className="discover-search-clear text-text-muted hover:text-text-primary">
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" aria-hidden="true">
            <path d="M18 6 6 18M6 6l12 12" />
          </svg>
        </button>
      )}
    </form>
  );
}

// MARK: Topic

function TopicPage({ topic, topics, onTopic, onFeed, followProps }: {
  topic: FeedCatalogTopic | undefined;
  topics: FeedCatalogTopic[];
  onTopic: (id: string) => void;
  onFeed: (feed: DiscoveredFeed, from: string) => void;
  followProps: FollowProps;
}) {
  // Feedly's index adds more feeds on the topic beyond the curated few.
  const more = useQuery({
    queryKey: ["feedDiscovery", "topic", topic?.name],
    queryFn: () => searchFeeds(topic!.name),
    enabled: !!topic,
    staleTime: 10 * 60_000,
    retry: false,
  });
  const feeds = useMemo(() => {
    if (!topic) return [];
    const seen = new Set(topic.feeds.map((f) => f.url.replace(/\/$/, "")));
    const extra = (more.data ?? []).filter((f) => !seen.has(f.url.replace(/\/$/, "")) && seen.add(f.url.replace(/\/$/, "")));
    return [...topic.feeds, ...extra];
  }, [topic, more.data]);
  if (!topic) return <SkeletonRows />;

  return (
    <>
      <header className="discover-topic-header">
        <span className="discover-topic-tile discover-topic-tile--large" style={{ background: topicStyle(topic.id).gradient }}>
          <TopicGlyph id={topic.id} size={34} />
        </span>
        <div className="min-w-0">
          <h1 className="text-text-primary">{topic.name}</h1>
          <p className="text-text-secondary">{feeds.length} feeds to follow</p>
        </div>
      </header>
      <div className="discover-chips" role="list" aria-label="Other topics">
        {topics.filter((t) => t.id !== topic.id).map((t) => (
          <button key={t.id} role="listitem" className="discover-chip text-text-secondary hover:text-text-primary" onClick={() => onTopic(t.id)}>
            <span aria-hidden="true">#</span> {t.name.toLowerCase()}
          </button>
        ))}
      </div>
      <h2 className="discover-label">Top feeds</h2>
      <FeedList feeds={feeds} onOpen={(f) => onFeed(f, topic.name)} followProps={followProps} />
      {more.isFetching && <SkeletonRows count={2} />}
    </>
  );
}

// MARK: Feed

function FeedPage({ feed, following, state, onFollow }: {
  feed: DiscoveredFeed;
  following: boolean;
  state: FollowState | undefined;
  onFollow: () => void;
}) {
  const preview = useQuery({
    queryKey: ["feedPreview", feed.url],
    queryFn: () => previewFeed(feed.url),
    // Discovered feeds arrive with a few headlines; fetch for the full page.
    staleTime: 10 * 60_000,
    retry: false,
  });
  const full = preview.data;
  const items = full?.items.length ? full.items : feed.items;
  const description = feed.description ?? full?.description;
  const groups = useMemo(() => groupByDay(items), [items]);

  return (
    <>
      <header className="discover-feed-header">
        <FeedIcon feed={feed} size={56} />
        <div className="flex-1 min-w-0">
          <h1 className="text-text-primary">{feed.title}</h1>
          <p className="text-text-muted" style={{ fontSize: 13 }}>
            {[displayHost(feed.site_url ?? full?.site_url ?? feed.url), feed.subscribers ? `${compactCount(feed.subscribers)} followers` : null]
              .filter(Boolean)
              .join(" · ")}
          </p>
          {description && <p className="text-text-secondary discover-feed-description">{description}</p>}
        </div>
        <FollowButton title={feed.title} following={following} state={state} onFollow={onFollow} large />
      </header>
      {typeof state === "object" && <ErrorBox>{state.error}</ErrorBox>}

      {preview.isLoading && items.length === 0 && <SkeletonPosts />}
      {preview.isError && items.length === 0 && <ErrorBox>{errorText(preview.error)}</ErrorBox>}
      {!preview.isLoading && !preview.isError && items.length === 0 && (
        <p className="text-text-muted" style={{ fontSize: 14 }}>No recent posts.</p>
      )}
      {groups.map(([label, posts]) => (
        <section key={label} aria-label={label}>
          <h2 className="discover-label">{label}</h2>
          <ul className="discover-posts">
            {posts.map((item, i) => <PostRow key={`${item.url ?? ""}-${i}`} item={item} />)}
          </ul>
        </section>
      ))}
    </>
  );
}

function groupByDay(items: FeedPreviewItem[]): [string, FeedPreviewItem[]][] {
  const groups: [string, FeedPreviewItem[]][] = [];
  for (const item of items) {
    const label = dayLabel(item.published_at);
    const last = groups[groups.length - 1];
    if (last && last[0] === label) last[1].push(item);
    else groups.push([label, [item]]);
  }
  return groups;
}

function PostRow({ item }: { item: FeedPreviewItem }) {
  const [imageFailed, setImageFailed] = useState(false);
  const meta = [item.author ? `by ${item.author}` : null, shortAge(item.published_at) || null].filter(Boolean).join(" / ");
  const body = (
    <>
      <span className="flex-1 min-w-0">
        <span className="discover-post-title text-text-primary">{item.title}</span>
        {meta && <span className="block text-text-muted" style={{ fontSize: 13, marginTop: 4 }}>{meta}</span>}
      </span>
      {item.image_url && !imageFailed && (
        <img className="discover-post-image" src={item.image_url} alt="" loading="lazy" onError={() => setImageFailed(true)} />
      )}
    </>
  );
  return (
    <li>
      {item.url ? (
        <button className="discover-post" onClick={() => void openUrl(item.url!)} title="Open in browser">
          {body}
        </button>
      ) : (
        <div className="discover-post">{body}</div>
      )}
    </li>
  );
}

// MARK: Shared pieces

function FeedList({ feeds, onOpen, followProps }: {
  feeds: DiscoveredFeed[];
  onOpen: (feed: DiscoveredFeed) => void;
  followProps: FollowProps;
}) {
  return (
    <ul className="discover-feeds">
      {feeds.map((feed) => {
        const f = followProps(feed);
        const meta = [displayHost(feed.site_url ?? feed.url), feed.subscribers ? `${compactCount(feed.subscribers)} followers` : null]
          .filter(Boolean)
          .join(" · ");
        return (
          <li key={feed.url} className="discover-feed">
            <button className="discover-feed-open" onClick={() => onOpen(feed)} aria-label={`${feed.title}, ${meta}`}>
              <FeedIcon feed={feed} size={40} />
              <span className="flex-1 min-w-0 text-left">
                <span className="block text-text-primary truncate" style={{ fontSize: 15, fontWeight: 600 }}>{feed.title}</span>
                <span className="block text-text-muted truncate" style={{ fontSize: 12.5 }}>{meta}</span>
                {feed.description && (
                  <span className="block text-text-secondary truncate" style={{ fontSize: 13, marginTop: 2 }}>{feed.description}</span>
                )}
              </span>
            </button>
            <FollowButton title={feed.title} {...f} />
            {typeof f.state === "object" && <p className="discover-feed-error text-danger">{f.state.error}</p>}
          </li>
        );
      })}
    </ul>
  );
}

function FollowButton({ title, following, state, onFollow, large = false }: {
  title: string;
  following: boolean;
  state: FollowState | undefined;
  onFollow: () => void;
  large?: boolean;
}) {
  if (following) {
    return (
      <span className={`discover-follow discover-follow--on ${large ? "discover-follow--large" : ""}`} aria-label={`Following ${title}`}>
        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.6" aria-hidden="true">
          <path d="m5 12 4 4L19 6" />
        </svg>
        Following
      </span>
    );
  }
  const adding = state === "adding";
  return (
    <button
      type="button"
      onClick={onFollow}
      disabled={adding}
      aria-label={`Follow ${title}`}
      className={`discover-follow ${large ? "discover-follow--large" : ""}`}
    >
      {!adding && (
        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.6" aria-hidden="true">
          <path d="M12 5v14M5 12h14" />
        </svg>
      )}
      {adding ? "Following…" : "Follow"}
    </button>
  );
}

function FeedIcon({ feed, size }: { feed: DiscoveredFeed; size: number }) {
  const [failed, setFailed] = useState(false);
  const letter = (feed.title.trim()[0] ?? "?").toUpperCase();
  return (
    <span
      className="discover-feed-icon text-text-secondary"
      style={{ width: size, height: size, fontSize: size * 0.42, borderRadius: size * 0.24 }}
      aria-hidden="true"
    >
      {feed.icon_url && !failed ? (
        <img src={feed.icon_url} alt="" style={{ width: size * 0.6, height: size * 0.6 }} onError={() => setFailed(true)} />
      ) : (
        letter
      )}
    </span>
  );
}

function Chevron() {
  return (
    <svg className="text-text-muted shrink-0" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" aria-hidden="true">
      <path d="m9 6 6 6-6 6" />
    </svg>
  );
}

function ErrorBox({ children }: { children: ReactNode }) {
  return (
    <div className="rounded-xl border border-danger/30 text-danger" style={{ padding: "10px 14px", margin: "8px 0 12px", fontSize: 13, background: "rgba(248, 81, 73, 0.1)" }}>
      {children}
    </div>
  );
}

function SkeletonRows({ count = 4 }: { count?: number }) {
  return (
    <div aria-hidden="true" className="flex flex-col" style={{ gap: 18, padding: "10px 0" }}>
      {Array.from({ length: count }, (_, i) => (
        <div key={i} className="flex items-center" style={{ gap: 14 }}>
          <div className="rounded-lg bg-white/5 animate-pulse" style={{ width: 40, height: 40 }} />
          <div className="flex-1">
            <div className="rounded bg-white/5 animate-pulse" style={{ height: 12, width: "40%", marginBottom: 8 }} />
            <div className="rounded bg-white/5 animate-pulse" style={{ height: 10, width: "70%" }} />
          </div>
        </div>
      ))}
    </div>
  );
}

function SkeletonPosts() {
  return (
    <div aria-hidden="true" className="flex flex-col" style={{ gap: 22, paddingTop: 20 }}>
      {[0, 1, 2, 3].map((i) => (
        <div key={i} className="flex" style={{ gap: 16 }}>
          <div className="flex-1">
            <div className="rounded bg-white/5 animate-pulse" style={{ height: 14, width: "85%", marginBottom: 8 }} />
            <div className="rounded bg-white/5 animate-pulse" style={{ height: 14, width: "60%", marginBottom: 10 }} />
            <div className="rounded bg-white/5 animate-pulse" style={{ height: 10, width: "30%" }} />
          </div>
          <div className="rounded-lg bg-white/5 animate-pulse" style={{ width: 132, height: 88 }} />
        </div>
      ))}
    </div>
  );
}
