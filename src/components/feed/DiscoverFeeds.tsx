import { useEffect, useMemo, useState } from "react";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { addFeed, discoverFeeds, feedCatalog, previewFeed, searchFeeds } from "../../services/commands";
import type { DiscoveredFeed } from "../../services/types";
import { useUiStore } from "../../stores/uiStore";
import { compactCount, displayHost, looksLikeUrl, shortAge } from "../../lib/feedDiscovery";

type AddState = "adding" | "added" | { error: string };

function useDebounced<T>(value: T, ms: number): T {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const t = window.setTimeout(() => setDebounced(value), ms);
    return () => window.clearTimeout(t);
  }, [value, ms]);
  return debounced;
}

const errorText = (e: unknown) => String(e instanceof Error ? e.message : e);

/**
 * Feedly-style discovery: type a topic or site name to search, paste a website
 * to find its feeds, or browse popular feeds by topic. Each result can be
 * previewed and added in place, so several feeds can be added in one visit.
 */
export function DiscoverFeeds({ onImportOpml }: { onImportOpml: () => void }) {
  const [input, setInput] = useState("");
  const [topicId, setTopicId] = useState<string | null>(null);
  const [addStates, setAddStates] = useState<Record<string, AddState>>({});
  const qc = useQueryClient();
  const isPhone = useUiStore((s) => s.isPhone);

  const trimmed = input.trim();
  const isUrl = looksLikeUrl(trimmed);
  const debounced = useDebounced(trimmed, isUrl ? 650 : 350);
  const settled = debounced === trimmed;

  const catalog = useQuery({ queryKey: ["feedCatalog"], queryFn: feedCatalog, staleTime: 60_000 });
  const results = useQuery({
    queryKey: ["feedDiscovery", isUrl ? "site" : "search", debounced],
    queryFn: () => (looksLikeUrl(debounced) ? discoverFeeds(debounced) : searchFeeds(debounced)),
    enabled: debounced.length >= 2,
    staleTime: 5 * 60_000,
    retry: false,
  });

  const topics = catalog.data ?? [];
  const activeTopic = topics.find((t) => t.id === topicId) ?? topics[0];

  const add = async (feed: DiscoveredFeed) => {
    setAddStates((s) => ({ ...s, [feed.url]: "adding" }));
    try {
      await addFeed(feed.url);
      setAddStates((s) => ({ ...s, [feed.url]: "added" }));
      await Promise.all([
        qc.invalidateQueries({ queryKey: ["feeds"] }),
        qc.invalidateQueries({ queryKey: ["articles"] }),
        qc.invalidateQueries({ queryKey: ["articleCount"] }),
        qc.invalidateQueries({ queryKey: ["todayEdition"] }),
      ]);
    } catch (e) {
      const message = errorText(e);
      // add_feed refuses duplicates; that is a success from the reader's view.
      setAddStates((s) => ({ ...s, [feed.url]: message.startsWith("Already subscribed") ? "added" : { error: message } }));
    }
  };

  const searching = trimmed.length >= 2 && (!settled || results.isFetching);
  const list = trimmed.length >= 2 && settled ? results.data : undefined;

  return (
    <div className="flex flex-col min-h-0 h-full">
      <div className="shrink-0" style={{ padding: "14px 24px 10px" }}>
        <form
          role="search"
          onSubmit={(e) => {
            e.preventDefault();
            if (trimmed.length >= 2 && settled) void results.refetch();
          }}
          className="relative"
        >
          <svg
            className="absolute text-text-muted pointer-events-none"
            style={{ left: 14, top: "50%", transform: "translateY(-50%)" }}
            width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true"
          >
            <circle cx="11" cy="11" r="7" />
            <path d="m20 20-3.5-3.5" />
          </svg>
          <input
            type="text"
            inputMode="url"
            value={input}
            onChange={(e) => setInput(e.target.value)}
            placeholder={isPhone ? "Search, or paste a site URL" : "Search topics, or paste a website or feed URL"}
            aria-label="Search topics, or paste a website or feed URL"
            autoFocus
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            className="w-full border border-white/10 rounded-xl text-text-primary placeholder-text-muted focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/30 transition-colors"
            style={{ background: "rgba(255, 255, 255, 0.05)", padding: "11px 38px 11px 40px", fontSize: 15 }}
          />
          {input && (
            <button
              type="button"
              onClick={() => setInput("")}
              aria-label="Clear search"
              className="absolute text-text-muted hover:text-text-primary rounded-md"
              style={{ right: 6, top: "50%", transform: "translateY(-50%)", width: 30, height: 30, display: "grid", placeItems: "center" }}
            >
              <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.2" aria-hidden="true">
                <path d="M18 6 6 18M6 6l12 12" />
              </svg>
            </button>
          )}
        </form>
        {!trimmed && (
          <p className="text-text-muted" style={{ fontSize: 12, marginTop: 8, lineHeight: 1.5 }}>
            Try a site like <em>theverge.com</em>, a subreddit like <em>r/rust</em>, a YouTube channel, or a topic like <em>space</em>.
          </p>
        )}
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto" style={{ padding: "0 16px 8px" }}>
        {trimmed.length >= 2 ? (
          <>
            <p className="text-text-muted" role="status" style={{ fontSize: 12, margin: "6px 8px 8px" }}>
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
            {results.isError && settled && !results.isFetching && (
              <div
                className="rounded-xl border border-danger/30 text-danger"
                style={{ padding: "10px 14px", marginBottom: 12, fontSize: 13, background: "rgba(248, 81, 73, 0.1)" }}
              >
                {errorText(results.error)}
              </div>
            )}
            {searching && !list && <SkeletonRows />}
            {list && list.length > 0 && (
              <ul className="flex flex-col" style={{ gap: 2 }}>
                {list.map((feed) => (
                  <FeedRow key={feed.url} feed={feed} state={addStates[feed.url]} onAdd={() => void add(feed)} />
                ))}
              </ul>
            )}
          </>
        ) : (
          <>
            <div className="flex flex-wrap" style={{ gap: 6, margin: "4px 8px 12px" }} role="tablist" aria-label="Topics">
              {topics.map((t) => {
                const active = t.id === activeTopic?.id;
                return (
                  <button
                    key={t.id}
                    role="tab"
                    aria-selected={active}
                    onClick={() => setTopicId(t.id)}
                    className={`rounded-full border transition-colors ${
                      active
                        ? "border-accent/60 bg-accent/15 text-text-primary"
                        : "border-white/10 text-text-secondary hover:text-text-primary hover:bg-white/5"
                    }`}
                    style={{ padding: "5px 12px", fontSize: 12.5, fontWeight: 500 }}
                  >
                    {t.name}
                  </button>
                );
              })}
            </div>
            {catalog.isLoading && <SkeletonRows />}
            {activeTopic && (
              <>
                <p className="text-text-muted" style={{ fontSize: 11, fontWeight: 600, letterSpacing: "0.06em", textTransform: "uppercase", margin: "0 8px 6px" }}>
                  Popular in {activeTopic.name}
                </p>
                <ul className="flex flex-col" style={{ gap: 2 }}>
                  {activeTopic.feeds.map((feed) => (
                    <FeedRow key={feed.url} feed={feed} state={addStates[feed.url]} onAdd={() => void add(feed)} />
                  ))}
                </ul>
              </>
            )}
          </>
        )}
      </div>

      <div className="shrink-0 border-t border-white/5 flex items-center justify-between" style={{ padding: "10px 24px 14px" }}>
        <button
          type="button"
          onClick={onImportOpml}
          className="text-accent hover:text-accent-hover rounded-lg"
          style={{ fontSize: 13, padding: "6px 0" }}
        >
          Import OPML or Feedly
        </button>
        <AddedCount states={addStates} />
      </div>
    </div>
  );
}

function AddedCount({ states }: { states: Record<string, AddState> }) {
  const n = useMemo(() => Object.values(states).filter((s) => s === "added").length, [states]);
  if (n === 0) return null;
  return (
    <span className="text-success" style={{ fontSize: 13 }}>
      Added {n} feed{n === 1 ? "" : "s"}
    </span>
  );
}

function SkeletonRows() {
  return (
    <div aria-hidden="true" className="flex flex-col" style={{ gap: 12, paddingTop: 6 }}>
      {[0, 1, 2].map((i) => (
        <div key={i} className="flex items-center" style={{ gap: 12 }}>
          <div className="rounded-lg bg-white/5 animate-pulse" style={{ width: 32, height: 32 }} />
          <div className="flex-1">
            <div className="rounded bg-white/5 animate-pulse" style={{ height: 12, width: "45%", marginBottom: 7 }} />
            <div className="rounded bg-white/5 animate-pulse" style={{ height: 10, width: "75%" }} />
          </div>
        </div>
      ))}
    </div>
  );
}

function FeedIcon({ feed }: { feed: DiscoveredFeed }) {
  const [failed, setFailed] = useState(false);
  const letter = (feed.title.trim()[0] ?? "?").toUpperCase();
  return (
    <div
      className="shrink-0 rounded-lg overflow-hidden flex items-center justify-center bg-white/5 text-text-secondary"
      style={{ width: 32, height: 32, fontSize: 14, fontWeight: 600 }}
    >
      {feed.icon_url && !failed ? (
        <img src={feed.icon_url} alt="" width={20} height={20} style={{ width: 20, height: 20, objectFit: "contain" }} onError={() => setFailed(true)} />
      ) : (
        letter
      )}
    </div>
  );
}

function FeedRow({ feed, state, onAdd }: { feed: DiscoveredFeed; state: AddState | undefined; onAdd: () => void }) {
  const [open, setOpen] = useState(false);
  const preview = useQuery({
    queryKey: ["feedPreview", feed.url],
    queryFn: () => previewFeed(feed.url),
    enabled: open && feed.items.length === 0,
    staleTime: 10 * 60_000,
    retry: false,
  });
  const items = feed.items.length > 0 ? feed.items : preview.data?.items ?? [];
  const added = state === "added" || feed.already_subscribed;
  const meta = [
    displayHost(feed.site_url ?? feed.url),
    feed.subscribers ? `${compactCount(feed.subscribers)} followers` : null,
  ].filter(Boolean).join(" · ");
  const previewId = `preview-${feed.url}`;

  return (
    <li className="rounded-xl hover:bg-white/[0.03] transition-colors" style={{ padding: "8px 8px" }}>
      <div className="flex items-start" style={{ gap: 12 }}>
        <FeedIcon feed={feed} />
        <button
          type="button"
          onClick={() => setOpen((o) => !o)}
          aria-expanded={open}
          aria-controls={previewId}
          className="flex-1 min-w-0 text-left"
          title={feed.url}
        >
          <span className="flex items-center text-text-primary" style={{ gap: 6, fontSize: 14, fontWeight: 600 }}>
            <span className="truncate">{feed.title}</span>
            <svg
              className="shrink-0 text-text-muted transition-transform"
              style={{ transform: open ? "rotate(90deg)" : undefined }}
              width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" aria-hidden="true"
            >
              <path d="m9 6 6 6-6 6" />
            </svg>
          </span>
          <span className="block text-text-muted truncate" style={{ fontSize: 12, marginTop: 1 }}>{meta}</span>
          {feed.description && (
            <span className="block text-text-secondary" style={{ fontSize: 12.5, lineHeight: 1.4, marginTop: 3, display: "-webkit-box", WebkitLineClamp: 2, WebkitBoxOrient: "vertical", overflow: "hidden" }}>
              {feed.description}
            </span>
          )}
        </button>
        <AddButton title={feed.title} added={added} following={feed.already_subscribed} state={state} onAdd={onAdd} />
      </div>
      {typeof state === "object" && (
        <p className="text-danger" style={{ fontSize: 12, margin: "6px 0 0 44px" }}>{state.error}</p>
      )}
      {open && (
        <div id={previewId} style={{ margin: "8px 0 2px 44px" }}>
          {preview.isFetching && items.length === 0 ? (
            <p className="text-text-muted" style={{ fontSize: 12 }}>Loading latest posts…</p>
          ) : preview.isError && items.length === 0 ? (
            <p className="text-danger" style={{ fontSize: 12 }}>{errorText(preview.error)}</p>
          ) : items.length === 0 ? (
            <p className="text-text-muted" style={{ fontSize: 12 }}>No recent posts.</p>
          ) : (
            <ol className="border-l border-white/10" style={{ paddingLeft: 10 }}>
              {items.map((item, i) => (
                <li key={`${item.url ?? ""}-${i}`} className="flex items-baseline" style={{ gap: 8, padding: "3px 0" }}>
                  <span className="text-text-primary flex-1 min-w-0 truncate" style={{ fontSize: 12.5 }}>{item.title}</span>
                  {item.published_at && (
                    <span className="text-text-muted shrink-0 tabular-nums" style={{ fontSize: 11 }}>{shortAge(item.published_at)}</span>
                  )}
                </li>
              ))}
            </ol>
          )}
        </div>
      )}
    </li>
  );
}

function AddButton({ title, added, following, state, onAdd }: {
  title: string;
  added: boolean;
  following: boolean;
  state: AddState | undefined;
  onAdd: () => void;
}) {
  if (added) {
    return (
      <span
        className="shrink-0 inline-flex items-center justify-end text-success rounded-lg"
        style={{ gap: 4, padding: "6px 0", fontSize: 13, fontWeight: 500, minHeight: 32, minWidth: 64 }}
      >
        <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.6" aria-hidden="true">
          <path d="m5 12 4 4L19 6" />
        </svg>
        {following && state !== "added" ? "Following" : "Added"}
      </span>
    );
  }
  const adding = state === "adding";
  return (
    <button
      type="button"
      onClick={onAdd}
      disabled={adding}
      aria-label={`Add ${title}`}
      className="shrink-0 bg-accent text-white rounded-lg hover:bg-accent-hover disabled:opacity-60 transition-colors"
      style={{ padding: "6px 14px", fontSize: 13, fontWeight: 600, minHeight: 32, minWidth: 64 }}
    >
      {adding ? "Adding…" : "Add"}
    </button>
  );
}
