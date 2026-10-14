import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { useQuery } from "@tanstack/react-query";
import { openUrl } from "@tauri-apps/plugin-opener";
import { canGoBackArticle, canGoForwardArticle, useUiStore } from "../../stores/uiStore";
import { useFeeds, useRefreshAllFeeds } from "../../hooks/useFeeds";
import { useFolders } from "../../hooks/useFolders";
import { useArticle, useToggleRead, useToggleStar } from "../../hooks/useArticles";
import { useArticleInteraction, useSetPriorityOverride } from "../../hooks/useLearning";
import { useDialogFocus } from "../../hooks/useDialogFocus";
import { askAgent, getArticles, type AgentContext } from "../../services/commands";
import { runAppCommand } from "../../lib/appCommands";
import { askFirst, filterCommands, formatShortcutKey, type PaletteCommand } from "../../lib/commandPalette";
import { agentContextLabel, type AgentMessage } from "../../lib/agentContext";
import { partitionSources } from "../../lib/chatCitations";
import { useAgentContext } from "../../hooks/useAgentContext";
import { openAgentChat } from "../../stores/agentChatStore";
import { AgentAnswer, AgentSteps } from "../chat/AgentAnswer";
import { AiSetupNotice, isAiSetupError } from "../common/AiSetupNotice";
import { PALETTE_ICONS } from "../ui/icons";

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

  // Today is a page, not a list: the list-only commands (search, filters,
  // mark all read) have nothing to act on there.
  const isToday = ui.sidebarView.type === "today";
  const commands: PaletteCommand[] = [];
  const add = (group: string, command: Omit<PaletteCommand, "group">) => commands.push({ group, ...command });

  if (article) {
    const g = "Article";
    add(g, { id: "article.summarize", icon: "sparkle", title: "Summarize article", keywords: ["ai", "tldr"], run: () => runAppCommand("summarize") });
    add(g, { id: "article.chat", icon: "chat", title: "Chat with article", keywords: ["ask", "question"], run: () => runAppCommand("toggle-chat") });
    add(g, {
      id: "article.star", icon: "star",
      title: article.is_starred ? "Unstar article" : "Star article",
      keywords: ["favorite", "save"],
      run: () => toggleStar.mutate(article.id),
    });
    add(g, {
      id: "article.read", icon: "check",
      title: article.is_read ? "Mark article as unread" : "Mark article as read",
      run: () => toggleRead.mutate(article.id),
    });
    const pinned = interaction?.priority_override === 5;
    add(g, {
      id: "article.pin", icon: "pin",
      title: pinned ? "Unpin article" : "Pin article to top",
      keywords: ["priority"],
      run: () => setPriority.mutate({ articleId: article.id, priority: pinned ? 3 : 5 }),
    });
    if (article.url) {
      add(g, { id: "article.reader", icon: "book", title: "Reader view", shortcut: ["←"], run: () => runAppCommand("reader-view") });
      add(g, { id: "article.web", icon: "globe", title: "Web view", keywords: ["original", "page"], shortcut: ["→"], run: () => runAppCommand("web-view") });
      const url = article.url;
      add(g, { id: "article.open", icon: "external", title: "Open in browser", keywords: ["external", "safari", "link"], run: () => void openUrl(url) });
    }
    add(g, { id: "article.close", icon: "close", title: "Close article", run: () => useUiStore.getState().closeArticleDetail() });
  }

  {
    const g = "Go to";
    if (canGoBackArticle(ui)) {
      add(g, { id: "go.back", icon: "back", title: "Back to previous article", keywords: ["history"], shortcut: ["mod", "["], run: () => useUiStore.getState().goBackArticle() });
    }
    if (canGoForwardArticle(ui)) {
      add(g, { id: "go.forward", icon: "forward", title: "Forward to next article", keywords: ["history"], shortcut: ["mod", "]"], run: () => useUiStore.getState().goForwardArticle() });
    }
    add(g, { id: "go.today", icon: "newspaper", title: "Today", keywords: ["edition", "front page"], run: () => ui.setSidebarView({ type: "today" }) });
    add(g, { id: "go.all", icon: "list", title: "All Articles", run: () => ui.setSidebarView({ type: "all" }) });
    add(g, { id: "go.starred", icon: "star", title: "Starred", keywords: ["favorites"], run: () => ui.setSidebarView({ type: "starred" }) });
    add(g, { id: "go.recent", icon: "clock", title: "Recently Read", keywords: ["history"], run: () => ui.setSidebarView({ type: "recent" }) });
    add(g, { id: "go.inbox", icon: "inbox", title: "For you", keywords: ["ai inbox", "triage", "priority", "ranked", "sort"], run: () => { ui.setSidebarView({ type: "all" }); ui.setListSort("forYou"); } });
  }

  {
    const g = "Actions";
    add(g, { id: "action.ask", icon: "chat", title: "Ask Skim", keywords: ["ai", "search", "chat"], run: () => runAppCommand("ask-skim") });
    add(g, { id: "action.refresh", icon: "refresh", title: "Refresh all feeds", keywords: ["reload", "sync", "fetch"], run: () => refreshAll.mutate() });
    if (!isToday) {
      add(g, { id: "action.search", icon: "search", title: "Search articles", keywords: ["find", "filter"], run: () => runAppCommand("focus-search") });
      add(g, { id: "action.markAllRead", icon: "check", title: "Mark all as read", run: () => runAppCommand("mark-all-read") });
    }
    add(g, { id: "action.addFeed", icon: "plus", title: "Add feed", keywords: ["subscribe", "rss", "new"], run: () => ui.setShowAddFeed(true) });
    add(g, { id: "action.feedly", icon: "import", title: "Import from Feedly", keywords: ["opml", "import"], run: () => ui.setShowAddFeed(true, "feedly") });
  }

  {
    const g = "View";
    if (!isToday) {
      add(g, { id: "view.unread", icon: "eye", title: "Show unread only", keywords: ["filter"], run: () => ui.setListFilter("unread") });
      add(g, { id: "view.allItems", icon: "list", title: "Show all articles", keywords: ["filter", "read"], run: () => ui.setListFilter("all") });
      add(g, { id: "view.starredItems", icon: "star", title: "Show starred articles", keywords: ["filter"], run: () => ui.setListFilter("starred") });
    }
    add(g, {
      id: "view.sidebar", icon: "sidebar",
      title: ui.sidebarCollapsed ? "Show sidebar" : "Hide sidebar",
      keywords: ["toggle", "collapse", "expand"],
      shortcut: ["mod", "alt", "S"],
      run: () => ui.toggleSidebar(),
    });
    if (!isToday) {
      add(g, {
        id: "view.list", icon: "list",
        title: ui.listCollapsed ? "Show article list" : "Hide article list",
        keywords: ["toggle", "collapse", "expand"],
        run: () => ui.toggleList(),
      });
    }
  }

  {
    const g = "Settings";
    add(g, { id: "settings.open", icon: "settings", title: "Open Settings", keywords: ["preferences"], shortcut: ["mod", ","], run: () => ui.setShowSettings(true) });
    add(g, { id: "settings.reading", icon: "book", title: "Reading settings", keywords: ["preferences", "offline"], run: () => ui.setShowSettings(true, "reading") });
    add(g, { id: "settings.ai", icon: "sparkle", title: "AI Provider settings", keywords: ["preferences", "model", "api key", "local"], run: () => ui.setShowSettings(true, "ai") });
    add(g, { id: "settings.sync", icon: "refresh", title: "Sync settings", keywords: ["preferences", "feedly", "refresh interval"], run: () => ui.setShowSettings(true, "sync") });
    add(g, { id: "settings.appearance", icon: "eye", title: "Appearance settings", keywords: ["preferences", "theme", "font"], run: () => ui.setShowSettings(true, "appearance") });
  }

  for (const folder of folders ?? []) {
    add("Folders", {
      id: `folder.${folder.id}`,
      title: folder.name,
      icon: "folder",
      detail: folder.is_smart ? "Smart folder" : "Folder",
      run: () => ui.setSidebarView({ type: "folder", folderId: folder.id }),
    });
  }
  for (const feed of feeds ?? []) {
    add("Feeds", {
      id: `feed.${feed.id}`,
      title: feed.title,
      icon: "rss",
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
  const inputRef = useRef<HTMLInputElement>(null);
  useDialogFocus(dialogRef, close);

  const [query, setQuery] = useState("");
  const [active, setActive] = useState(0);
  const commands = useCommands();
  const { data: feeds } = useFeeds();

  // Chat: input that is not a command is a question for the app agent, which
  // knows the page, story or article on screen.
  const liveContext = useAgentContext();
  const selectedArticleId = useUiStore((s) => s.selectedArticleId);
  const { data: openArticle } = useArticle(selectedArticleId);
  const [chat, setChat] = useState<{ context: AgentContext; label: string; messages: AgentMessage[] } | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => { mounted.current = false; };
  }, []);

  const articleQuery = useDebounced(query.trim(), 150);
  const { data: foundArticles } = useQuery({
    queryKey: ["commandPaletteArticles", articleQuery],
    queryFn: () => getArticles({ search: articleQuery, limit: ARTICLE_RESULTS }),
    enabled: !chat && articleQuery.length >= 2,
    staleTime: 30_000,
  });

  const openArticleById = (id: string) => {
    const ui = useUiStore.getState();
    if (ui.sidebarView.type === "today") ui.openArticleFromToday(id);
    else ui.setSelectedArticleId(id);
  };

  const ask = async (text: string) => {
    const question = text.trim();
    if (!question || loading) return;
    const context = chat?.context ?? liveContext;
    const label = chat?.label ?? agentContextLabel(context, openArticle?.title);
    const prior = chat?.messages ?? [];
    const messages: AgentMessage[] = [...prior, { role: "user", content: question }];
    setChat({ context, label, messages });
    setQuery("");
    setError(null);
    setLoading(true);
    const priorIds = [...prior].reverse().find((m) => m.role === "assistant")?.articleIds;
    try {
      const resp = await askAgent(messages.map(({ role, content }) => ({ role, content })), context, priorIds);
      if (!mounted.current) return;
      setChat((current) => current && {
        ...current,
        messages: [...current.messages, { role: "assistant", content: resp.content, sources: resp.sources, articleIds: resp.article_ids, steps: resp.steps }],
      });
      const open = resp.actions.find((action) => action.type === "open_article");
      if (open) {
        close();
        window.setTimeout(() => openArticleById(open.article_id), 0);
      }
    } catch (e) {
      if (!mounted.current) return;
      setError(String(e instanceof Error ? e.message : e));
      setChat(prior.length ? { context, label, messages: prior } : null);
      setQuery(question);
    } finally {
      if (mounted.current) {
        setLoading(false);
        inputRef.current?.focus();
      }
    }
  };

  const openFullChat = (prompt?: string) => {
    if (loading) return;
    const context = chat?.context ?? liveContext;
    const text = (prompt ?? query).trim();
    close();
    window.setTimeout(() => openAgentChat({
      context,
      articleTitle: context.article_id ? openArticle?.title : null,
      messages: chat?.messages,
      prompt: text || undefined,
      autoSend: !!text,
    }), 0);
  };

  const lastAnswer = chat ? [...chat.messages].reverse().find((m) => m.role === "assistant") : undefined;
  const lastAnswerIsLatest = !!chat && !loading && chat.messages[chat.messages.length - 1] === lastAnswer;

  const results = useMemo(() => {
    if (chat) {
      // The articles the latest answer cited, ready to open.
      if (!lastAnswer?.sources || !lastAnswerIsLatest) return [];
      return partitionSources(lastAnswer.sources, lastAnswer.content).cited.map(({ source, number }): PaletteCommand => ({
        id: `cited.${source.id}`,
        group: number === null ? "Web" : `[${number}]`,
        title: source.title,
        detail: source.feed_title,
        icon: source.source_type === "web" ? "globe" : "book",
        run: () => {
          if (source.source_type === "web") { if (source.url) void openUrl(source.url); }
          else openArticleById(source.id);
        },
      }));
    }
    const matched = filterCommands(commands, query);
    const trimmed = query.trim();
    if (trimmed.length < 2) return matched;
    const askRow: PaletteCommand = {
      id: "ask.agent",
      group: "Ask Skim",
      title: trimmed,
      icon: "sparkle",
      stay: true,
      run: () => void ask(trimmed),
    };
    const feedTitles = new Map((feeds ?? []).map((f) => [f.id, f.title]));
    const articles: PaletteCommand[] = (foundArticles ?? []).slice(0, ARTICLE_RESULTS).map((a) => ({
      id: `articleResult.${a.id}`,
      group: "Articles",
      title: a.title,
      detail: feedTitles.get(a.feed_id),
      icon: "book",
      run: () => useUiStore.getState().setSelectedArticleId(a.id),
    }));
    return askFirst(commands, query) ? [askRow, ...matched, ...articles] : [...matched, askRow, ...articles];
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chat, lastAnswer, lastAnswerIsLatest, commands, feeds, foundArticles, query]);

  useEffect(() => setActive(0), [query, chat?.messages.length]);
  const activeIndex = Math.min(active, Math.max(results.length - 1, 0));

  useEffect(() => {
    listRef.current
      ?.querySelector<HTMLElement>(`[data-index="${activeIndex}"]`)
      ?.scrollIntoView?.({ block: "nearest" });
  }, [activeIndex]);

  useEffect(() => {
    if (chat && loading) listRef.current?.scrollTo?.({ top: listRef.current.scrollHeight });
  }, [chat, loading]);

  const run = (command: PaletteCommand | undefined) => {
    if (!command) return;
    if (command.stay) {
      command.run();
      return;
    }
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
    } else if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
      e.preventDefault();
      if (chat || query.trim()) openFullChat();
    } else if (e.key === "Enter") {
      e.preventDefault();
      if (chat && query.trim()) void ask(query);
      else run(results[activeIndex]);
    } else if (e.key === "Backspace" && chat && !query && !loading) {
      // Backspace on an empty follow-up returns to the command list.
      e.preventDefault();
      setChat(null);
      setError(null);
    }
  };

  // Group headers only when browsing; a search shows one ranked list with
  // each row's group on the right.
  const browsing = !chat && !query.trim();

  const renderRow = (command: PaletteCommand, index: number) => {
    const header = browsing && (index === 0 || results[index - 1].group !== command.group);
    const selected = index === activeIndex;
    const isAsk = command.id === "ask.agent";
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
          <span
            className={`flex items-center justify-center flex-shrink-0 ${isAsk ? "text-accent" : selected ? "text-text-primary" : "text-text-muted"}`}
            style={{ width: 18, height: 18 }}
          >
            {(() => {
              const Glyph = command.icon ? PALETTE_ICONS[command.icon] : undefined;
              return Glyph ? <Glyph size={16} strokeWidth={1.9} /> : null;
            })()}
          </span>
          {isAsk ? (
            <span className="truncate min-w-0">
              <span className="text-text-muted">Ask Skim: </span>{command.title}
            </span>
          ) : (
            <span className="truncate min-w-0">{command.title}</span>
          )}
          {command.detail && (
            <span className="text-text-muted truncate min-w-0 flex-shrink" style={{ fontSize: 12 }}>{command.detail}</span>
          )}
          <span className="flex-1" />
          {!browsing && !isAsk && (
            <span className="text-text-muted flex-shrink-0" style={{ fontSize: 11 }}>{command.group}</span>
          )}
          {isAsk && selected && (
            <span className="text-text-muted flex-shrink-0" style={{ fontSize: 11 }}>{agentContextLabel(liveContext, openArticle?.title)}</span>
          )}
          {command.shortcut && (
            <span className="flex items-center gap-1 flex-shrink-0">
              {command.shortcut.map((key) => <Kbd key={key}>{formatShortcutKey(key)}</Kbd>)}
            </span>
          )}
        </div>
      </div>
    );
  };

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
          maxHeight: chat ? "min(640px, 76vh)" : "min(560px, 70vh)",
          marginTop: chat ? "10vh" : "14vh",
          alignSelf: "flex-start",
        }}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center gap-3 border-b border-white/5" style={{ padding: "14px 18px" }}>
          {chat ? (
            <span className="text-accent flex-shrink-0 flex">
              {(() => { const Sparkle = PALETTE_ICONS.sparkle; return Sparkle ? <Sparkle size={16} strokeWidth={1.9} /> : null; })()}
            </span>
          ) : (
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="text-text-muted flex-shrink-0">
              <circle cx="11" cy="11" r="8" />
              <path d="M21 21l-4.35-4.35" />
            </svg>
          )}
          <input
            ref={inputRef}
            autoFocus
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            onKeyDown={onKeyDown}
            placeholder={chat ? "Ask a follow-up…" : "Type a command, or ask anything…"}
            aria-label={chat ? "Follow-up question" : "Search commands"}
            aria-controls="command-palette-list"
            aria-activedescendant={results.length ? `command-${activeIndex}` : undefined}
            role="combobox"
            aria-expanded="true"
            className="flex-1 bg-transparent text-text-primary placeholder-text-muted focus:outline-none"
            style={{ fontSize: 16 }}
          />
          <Kbd>esc</Kbd>
        </div>

        <div ref={listRef} id="command-palette-list" role="listbox" aria-label={chat ? "Conversation" : undefined} className="flex-1 overflow-y-auto" style={{ padding: 6 }}>
          {chat && (
            <div style={{ padding: "6px 12px 4px" }} aria-live="polite">
              <div className="text-text-muted" style={{ fontSize: 11, marginBottom: 8 }}>{chat.label}</div>
              {chat.messages.map((message, index) => message.role === "user" ? (
                <p key={index} className="text-text-primary" style={{ fontSize: 15, fontWeight: 600, marginTop: index ? 18 : 0, marginBottom: 6 }}>
                  {message.content}
                </p>
              ) : (
                <div key={index}>
                  <AgentSteps steps={message.steps ?? []} />
                  <AgentAnswer
                    content={message.content}
                    sources={message.sources ?? []}
                    onOpenArticle={(id) => { close(); window.setTimeout(() => openArticleById(id), 0); }}
                  />
                </div>
              ))}
              {loading && (
                <div className="flex items-center gap-2 text-text-muted" style={{ padding: "4px 0" }} role="status">
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="smooth-spin">
                    <path d="M21 12a9 9 0 11-6.219-8.56" />
                  </svg>
                  <span style={{ fontSize: 12 }}>Looking through your articles…</span>
                </div>
              )}
              {results.length > 0 && (
                <div className="text-text-muted uppercase" style={{ fontSize: 11, fontWeight: 600, letterSpacing: "0.06em", padding: "14px 0 2px" }}>
                  Articles
                </div>
              )}
            </div>
          )}
          {error && (isAiSetupError(error)
            ? <div style={{ padding: "6px 12px" }}><AiSetupNotice error={error} /></div>
            : <p role="alert" className="text-danger" style={{ fontSize: 13, padding: "6px 12px" }}>{error}</p>)}
          {!chat && results.length === 0 && (
            <p className="text-text-muted text-center" style={{ fontSize: 13, padding: "28px 12px" }}>
              No matching commands
            </p>
          )}
          {results.map(renderRow)}
        </div>

        <div className="flex items-center gap-4 border-t border-white/5 text-text-muted" style={{ padding: "8px 16px", fontSize: 11 }}>
          {chat ? (
            <>
              {(query.trim() || results.length > 0) && (
                <span className="flex items-center gap-1"><Kbd>↵</Kbd> {query.trim() ? "ask" : "open article"}</span>
              )}
              <span className="flex items-center gap-1"><Kbd>⌫</Kbd> commands</span>
              <span className="flex-1" />
              <button
                type="button"
                onClick={() => openFullChat()}
                disabled={loading}
                className="flex items-center gap-1 rounded-md hover:text-text-primary hover:bg-white/5 disabled:opacity-40"
                style={{ padding: "2px 6px", fontSize: 11 }}
              >
                Open full chat <Kbd>{formatShortcutKey("mod")}</Kbd><Kbd>↵</Kbd>
              </button>
            </>
          ) : (
            <>
              <span className="flex items-center gap-1"><Kbd>↑</Kbd><Kbd>↓</Kbd> navigate</span>
              <span className="flex items-center gap-1"><Kbd>↵</Kbd> run</span>
              {query.trim() && <span className="flex items-center gap-1"><Kbd>{formatShortcutKey("mod")}</Kbd><Kbd>↵</Kbd> ask in full chat</span>}
              <span className="flex-1" />
              <span className="flex items-center gap-1"><Kbd>{formatShortcutKey("mod")}</Kbd><Kbd>K</Kbd> toggle</span>
            </>
          )}
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
