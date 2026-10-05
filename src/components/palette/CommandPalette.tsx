import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useQuery } from "@tanstack/react-query";
import { openUrl } from "@tauri-apps/plugin-opener";
import { useUiStore } from "../../stores/uiStore";
import { useFeeds, useRefreshAllFeeds } from "../../hooks/useFeeds";
import { useFolders } from "../../hooks/useFolders";
import { useArticle, useToggleRead, useToggleStar } from "../../hooks/useArticles";
import { useArticleInteraction, useSetPriorityOverride } from "../../hooks/useLearning";
import { useDialogFocus } from "../../hooks/useDialogFocus";
import { getArticles } from "../../services/commands";
import { runAppCommand } from "../../lib/appCommands";
import { filterCommands, formatShortcutKey, type PaletteCommand } from "../../lib/commandPalette";

const ARTICLE_RESULTS = 8;

function useDebounced<T>(value: T, ms: number): T {
  const [debounced, setDebounced] = useState(value);
  useEffect(() => {
    const id = window.setTimeout(() => setDebounced(value), ms);
    return () => window.clearTimeout(id);
  }, [value, ms]);
  return debounced;
}

/** Every command the app offers right now, in the order shown for an empty query. */
function useCommands(): PaletteCommand[] {
  const ui = useUiStore();
  const { data: feeds } = useFeeds();
  const { data: folders } = useFolders();
  const { data: article } = useArticle(ui.selectedArticleId);
  const { data: interaction } = useArticleInteraction(ui.selectedArticleId);
  const refreshAll = useRefreshAllFeeds();
  const toggleStar = useToggleStar();
  const toggleRead = useToggleRead();
  const setPriority = useSetPriorityOverride();

  const isToday = ui.sidebarView.type === "today";
  const commands: PaletteCommand[] = [];
  const add = (group: string, command: Omit<PaletteCommand, "group">) => commands.push({ group, ...command });

  if (article) {
    const g = "Article";
    add(g, { id: "article.summarize", title: "Summarize article", keywords: ["ai", "tldr"], run: () => runAppCommand("summarize") });
    add(g, { id: "article.chat", title: "Chat with article", keywords: ["ask", "question"], run: () => runAppCommand("toggle-chat") });
    add(g, {
      id: "article.star",
      title: article.is_starred ? "Unstar article" : "Star article",
      keywords: ["favorite", "save"],
      run: () => toggleStar.mutate(article.id),
    });
    add(g, {
      id: "article.read",
      title: article.is_read ? "Mark article as unread" : "Mark article as read",
      run: () => toggleRead.mutate(article.id),
    });
    const pinned = interaction?.priority_override === 5;
    add(g, {
      id: "article.pin",
      title: pinned ? "Unpin article" : "Pin article to top",
      keywords: ["priority"],
      run: () => setPriority.mutate({ articleId: article.id, priority: pinned ? 3 : 5 }),
    });
    if (article.url) {
      add(g, { id: "article.reader", title: "Reader view", shortcut: ["←"], run: () => runAppCommand("reader-view") });
      add(g, { id: "article.web", title: "Web view", keywords: ["original", "page"], shortcut: ["→"], run: () => runAppCommand("web-view") });
      const url = article.url;
      add(g, { id: "article.open", title: "Open in browser", keywords: ["external", "safari", "link"], run: () => void openUrl(url) });
    }
    add(g, { id: "article.close", title: "Close article", run: () => useUiStore.getState().closeArticleDetail() });
  }

  {
    const g = "Go to";
    add(g, { id: "go.today", title: "Today", keywords: ["edition", "front page"], run: () => ui.setSidebarView({ type: "today" }) });
    add(g, { id: "go.all", title: "All Articles", run: () => ui.setSidebarView({ type: "all" }) });
    add(g, { id: "go.starred", title: "Starred", keywords: ["favorites"], run: () => ui.setSidebarView({ type: "starred" }) });
    add(g, { id: "go.recent", title: "Recently Read", keywords: ["history"], run: () => ui.setSidebarView({ type: "recent" }) });
    add(g, { id: "go.inbox", title: "AI Inbox", keywords: ["triage", "priority"], run: () => ui.setSidebarView({ type: "inbox" }) });
  }

  {
    const g = "Actions";
    add(g, { id: "action.catchup", title: "Quick Catch-up", keywords: ["summary", "brief"], run: () => ui.setShowCatchup(true) });
    add(g, { id: "action.ask", title: "Ask Skim", keywords: ["ai", "search", "chat"], run: () => runAppCommand("ask-skim") });
    add(g, { id: "action.refresh", title: "Refresh all feeds", keywords: ["reload", "sync", "fetch"], run: () => refreshAll.mutate() });
    if (!isToday) {
      add(g, { id: "action.search", title: "Search articles", keywords: ["find", "filter"], run: () => runAppCommand("focus-search") });
      add(g, { id: "action.markAllRead", title: "Mark all as read", run: () => runAppCommand("mark-all-read") });
    }
    add(g, { id: "action.addFeed", title: "Add feed", keywords: ["subscribe", "rss", "new"], run: () => ui.setShowAddFeed(true) });
    add(g, { id: "action.feedly", title: "Import from Feedly", keywords: ["opml", "import"], run: () => ui.setShowAddFeed(true, "feedly") });
  }

  {
    const g = "View";
    if (!isToday) {
      add(g, { id: "view.unread", title: "Show unread only", keywords: ["filter"], run: () => ui.setListFilter("unread") });
      add(g, { id: "view.allItems", title: "Show all articles", keywords: ["filter", "read"], run: () => ui.setListFilter("all") });
      add(g, { id: "view.starredItems", title: "Show starred articles", keywords: ["filter"], run: () => ui.setListFilter("starred") });
    }
    add(g, {
      id: "view.sidebar",
      title: ui.sidebarCollapsed ? "Show sidebar" : "Hide sidebar",
      keywords: ["toggle", "collapse", "expand"],
      shortcut: ["mod", "["],
      run: () => ui.toggleSidebar(),
    });
    if (!isToday) {
      add(g, {
        id: "view.list",
        title: ui.listCollapsed ? "Show article list" : "Hide article list",
        keywords: ["toggle", "collapse", "expand"],
        run: () => ui.toggleList(),
      });
    }
  }

  {
    const g = "Settings";
    add(g, { id: "settings.open", title: "Open Settings", keywords: ["preferences"], shortcut: ["mod", ","], run: () => ui.setShowSettings(true) });
    add(g, { id: "settings.reading", title: "Reading settings", keywords: ["preferences", "offline"], run: () => ui.setShowSettings(true, "reading") });
    add(g, { id: "settings.ai", title: "AI Provider settings", keywords: ["preferences", "model", "api key", "local"], run: () => ui.setShowSettings(true, "ai") });
    add(g, { id: "settings.sync", title: "Sync settings", keywords: ["preferences", "feedly", "refresh interval"], run: () => ui.setShowSettings(true, "sync") });
    add(g, { id: "settings.appearance", title: "Appearance settings", keywords: ["preferences", "theme", "font"], run: () => ui.setShowSettings(true, "appearance") });
  }

  for (const folder of folders ?? []) {
    add("Folders", {
      id: `folder.${folder.id}`,
      title: folder.name,
      detail: folder.is_smart ? "Smart folder" : "Folder",
      run: () => ui.setSidebarView({ type: "folder", folderId: folder.id }),
    });
  }
  for (const feed of feeds ?? []) {
    add("Feeds", {
      id: `feed.${feed.id}`,
      title: feed.title,
      detail: feed.unread_count > 0 ? `${feed.unread_count} unread` : undefined,
      run: () => ui.setSidebarView({ type: "feed", feedId: feed.id }),
    });
  }

  return commands;
}

export function CommandPalette() {
  const setShowCommandPalette = useUiStore((s) => s.setShowCommandPalette);
  const close = () => setShowCommandPalette(false);
  const dialogRef = useRef<HTMLDivElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  useDialogFocus(dialogRef, close);

  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
  const commands = useCommands();
  const { data: feeds } = useFeeds();

  const articleQuery = useDebounced(query.trim(), 150);
  const { data: foundArticles } = useQuery({
    queryKey: ["commandPaletteArticles", articleQuery],
    queryFn: () => getArticles({ search: articleQuery, limit: ARTICLE_RESULTS }),
    enabled: articleQuery.length >= 2,
    staleTime: 30_000,
  });

  const results = useMemo(() => {
    const matched = filterCommands(commands, query);
    if (query.trim().length < 2 || !foundArticles?.length) return matched;
    const feedTitles = new Map((feeds ?? []).map((f) => [f.id, f.title]));
    const articles: PaletteCommand[] = foundArticles.slice(0, ARTICLE_RESULTS).map((a) => ({
      id: `articleResult.${a.id}`,
      group: "Articles",
      title: a.title,
      detail: feedTitles.get(a.feed_id),
      run: () => useUiStore.getState().setSelectedArticleId(a.id),
    }));
    return [...matched, ...articles];
  }, [commands, feeds, foundArticles, query]);

  useEffect(() => setActive(0), [query]);
  const activeIndex = Math.min(active, Math.max(results.length - 1, 0));

  useEffect(() => {
    listRef.current
      ?.querySelector<HTMLElement>(`[data-index="${activeIndex}"]`)
      ?.scrollIntoView?.({ block: "nearest" });
  }, [activeIndex]);

  const run = (command: PaletteCommand | undefined) => {
    if (!command) return;
    close();
    // Let the palette unmount and hand focus back before the command opens
    // its own dialog or moves focus.
    window.setTimeout(command.run, 0);
  };

  const onKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "ArrowDown" || (e.ctrlKey && e.key === "n")) {
      e.preventDefault();
      setActive((i) => (results.length ? (Math.min(i, results.length - 1) + 1) % results.length : 0));
    } else if (e.key === "ArrowUp" || (e.ctrlKey && e.key === "p")) {
      e.preventDefault();
      setActive((i) => (results.length ? (Math.min(i, results.length - 1) - 1 + results.length) % results.length : 0));
    } else if (e.key === "Enter") {
      e.preventDefault();
      run(results[activeIndex]);
    }
  };

  // Group headers only when browsing; a search shows one ranked list with
  // each row's group on the right.
  const browsing = !query.trim();

  return createPortal(
    <div className="fixed inset-0 bg-black/50 backdrop-blur-sm z-[60] dialog-fade-in flex justify-center" onClick={close}>
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-label="Command palette"
        tabIndex={-1}
        className="border border-white/10 rounded-2xl shadow-2xl flex flex-col overflow-hidden"
        style={{
          background: "var(--color-bg-secondary)",
          width: "min(640px, 92vw)",
          maxHeight: "min(560px, 70vh)",
          marginTop: "14vh",
          alignSelf: "flex-start",
        }}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center gap-3 border-b border-white/5" style={{ padding: "14px 18px" }}>
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="text-text-muted flex-shrink-0">
            <circle cx="11" cy="11" r="8" />
            <path d="M21 21l-4.35-4.35" />
          </svg>
          <input
            autoFocus
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={onKeyDown}
            placeholder="Type a command, feed or article…"
            aria-label="Search commands"
            aria-controls="command-palette-list"
            aria-activedescendant={results.length ? `command-${activeIndex}` : undefined}
            role="combobox"
            aria-expanded="true"
            className="flex-1 bg-transparent text-text-primary placeholder-text-muted focus:outline-none"
            style={{ fontSize: 16 }}
          />
          <Kbd>esc</Kbd>
        </div>

        <div ref={listRef} id="command-palette-list" role="listbox" className="flex-1 overflow-y-auto" style={{ padding: 6 }}>
          {results.length === 0 && (
            <p className="text-text-muted text-center" style={{ fontSize: 13, padding: "28px 12px" }}>
              No matching commands
            </p>
          )}
          {results.map((command, index) => {
            const header = browsing && (index === 0 || results[index - 1].group !== command.group);
            const selected = index === activeIndex;
            return (
              <div key={command.id}>
                {header && (
                  <div className="text-text-muted uppercase" style={{ fontSize: 11, fontWeight: 600, letterSpacing: "0.06em", padding: "10px 12px 4px" }}>
                    {command.group}
                  </div>
                )}
                <div
                  id={`command-${index}`}
                  data-index={index}
                  role="option"
                  aria-selected={selected}
                  onMouseMove={() => { if (!selected) setActive(index); }}
                  onClick={() => run(command)}
                  className={`flex items-center gap-3 rounded-lg cursor-pointer ${selected ? "bg-white/10 text-text-primary" : "text-text-secondary"}`}
                  style={{ padding: "8px 12px", fontSize: 14 }}
                >
                  <span className="truncate min-w-0">{command.title}</span>
                  {command.detail && (
                    <span className="text-text-muted truncate min-w-0 flex-shrink" style={{ fontSize: 12 }}>{command.detail}</span>
                  )}
                  <span className="flex-1" />
                  {!browsing && (
                    <span className="text-text-muted flex-shrink-0" style={{ fontSize: 11 }}>{command.group}</span>
                  )}
                  {command.shortcut && (
                    <span className="flex items-center gap-1 flex-shrink-0">
                      {command.shortcut.map((key) => <Kbd key={key}>{formatShortcutKey(key)}</Kbd>)}
                    </span>
                  )}
                </div>
              </div>
            );
          })}
        </div>

        <div className="flex items-center gap-4 border-t border-white/5 text-text-muted" style={{ padding: "8px 16px", fontSize: 11 }}>
          <span className="flex items-center gap-1"><Kbd>↑</Kbd><Kbd>↓</Kbd> navigate</span>
          <span className="flex items-center gap-1"><Kbd>↵</Kbd> run</span>
          <span className="flex-1" />
          <span className="flex items-center gap-1"><Kbd>{formatShortcutKey("mod")}</Kbd><Kbd>K</Kbd> toggle</span>
        </div>
      </div>
    </div>,
    document.body,
  );
}

function Kbd({ children }: { children: React.ReactNode }) {
  return (
    <kbd
      className="border border-white/10 rounded text-text-muted"
      style={{ fontSize: 11, fontFamily: "inherit", padding: "1px 6px", minWidth: 20, textAlign: "center", background: "rgba(255,255,255,0.04)" }}
    >
      {children}
    </kbd>
  );
}
