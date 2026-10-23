import { useEffect, useMemo, useRef, useSyncExternalStore } from "react";
import { createPortal } from "react-dom";
import { openUrl } from "@tauri-apps/plugin-opener";
import { canGoBackArticle, canGoForwardArticle, useUiStore } from "../../stores/uiStore";
import { useFeeds, useRefreshAllFeeds } from "../../hooks/useFeeds";
import { useFolders } from "../../hooks/useFolders";
import { useArticle, useToggleRead, useToggleStar } from "../../hooks/useArticles";
import { useArticleInteraction, useSetPriorityOverride } from "../../hooks/useLearning";
import { useDialogFocus } from "../../hooks/useDialogFocus";
import { askAgent, getArticles, type AgentContext } from "../../services/commands";
import { runAppCommand } from "../../lib/appCommands";
import { formatShortcutKey, type PaletteCommand } from "../../lib/commandPalette";
import { createCommandRegistry, createPaletteController, isAskCommand, type AskTurn } from "@byos/commands";
import { agentContextLabel, type AgentMessage } from "../../lib/agentContext";
import { partitionSources } from "../../lib/chatCitations";
import { useAgentContext } from "../../hooks/useAgentContext";
import { openAgentChat } from "../../stores/agentChatStore";
import { AgentAnswer, AgentSteps, citationStyle } from "../chat/AgentAnswer";
import { AiSetupNotice, isAiSetupError } from "../common/AiSetupNotice";
import { AiErrorText } from "../common/AiSettingsButton";
import { PALETTE_ICONS } from "../ui/icons";
import { PAPER_NAME } from "../../lib/dispatch";

const ARTICLE_RESULTS = 8;

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
    add(g, { id: "go.today", icon: "newspaper", title: PAPER_NAME, keywords: ["today", "briefing", "edition", "front page", "newspaper"], run: () => ui.setSidebarView({ type: "today" }) });
    add(g, { id: "go.all", icon: "list", title: "All Articles", run: () => ui.setSidebarView({ type: "all" }) });
    add(g, { id: "go.starred", icon: "star", title: "Starred", keywords: ["favorites"], run: () => ui.setSidebarView({ type: "starred" }) });
    add(g, { id: "go.recent", icon: "clock", title: "Recently Read", keywords: ["history"], run: () => ui.setSidebarView({ type: "recent" }) });
    add(g, { id: "go.inbox", icon: "inbox", title: "For you", keywords: ["ai inbox", "triage", "priority", "ranked", "sort", "smart sorting"], run: () => { ui.setSidebarView({ type: "all" }); ui.setListSort("forYou"); } });
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

/** What Skim keeps with an answer, for its own rendering and the next turn. */
type AnswerData = Pick<AgentMessage, "sources" | "articleIds" | "steps">;

const toAgentMessages = (history: readonly AskTurn[]): AgentMessage[] =>
  history.map((turn) => ({ role: turn.role, content: turn.content, ...(turn.data as AnswerData | undefined) }));

export function CommandPalette() {
  const setShowCommandPalette = useUiStore((s) => s.setShowCommandPalette);
  const close = () => setShowCommandPalette(false);
  const dialogRef = useRef<HTMLDivElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  useDialogFocus(dialogRef, close);

  const commands = useCommands();
  const { data: feeds } = useFeeds();

  // Chat: input that is not a command is a question for the app agent, which
  // knows the page, story or article on screen.
  const liveContext = useAgentContext();
  const selectedArticleId = useUiStore((s) => s.selectedArticleId);
  const { data: openArticle } = useArticle(selectedArticleId);

  // The palette engine (ranking, keys, Ask flow) is BYOS's; the closures below
  // always read this render's values.
  const latest = useRef({ commands, feeds, liveContext, openArticle });
  latest.current = { commands, feeds, liveContext, openArticle };
  // A conversation keeps the context it started with, even if the view changes underneath.
  const chatContext = useRef<{ context: AgentContext; label: string } | null>(null);

  const openArticleById = (id: string) => {
    const ui = useUiStore.getState();
    if (ui.sidebarView.type === "today") ui.openArticleFromToday(id);
    else ui.setSelectedArticleId(id);
  };

  const controller = useMemo(() => {
    const registry = createCommandRegistry([
      {
        id: "skim",
        // Rows re-resolve by id when run, so a row never acts on a stale article.
        commands: () => latest.current.commands.map((command) => ({
          ...command,
          run: () => latest.current.commands.find((c) => c.id === command.id)?.run(),
        })),
      },
      {
        id: "articles",
        minQuery: 2,
        debounceMs: 150,
        limit: ARTICLE_RESULTS,
        search: async (query) => {
          const found = await getArticles({ search: query, limit: ARTICLE_RESULTS });
          const feedTitles = new Map((latest.current.feeds ?? []).map((f) => [f.id, f.title]));
          return found.map((a): PaletteCommand => ({
            id: `articleResult.${a.id}`,
            group: "Articles",
            title: a.title,
            detail: feedTitles.get(a.feed_id),
            icon: "book",
            run: () => useUiStore.getState().setSelectedArticleId(a.id),
          }));
        },
      },
    ]);
    return createPaletteController({
      registry,
      // Let the palette unmount and hand focus back before the command opens
      // its own dialog or moves focus.
      schedule: (run) => { window.setTimeout(run, 0); },
      onOpenChange: (open) => { if (!open) useUiStore.getState().setShowCommandPalette(false); },
      ask: {
        label: "Ask Skim",
        ask: async (question, { history }) => {
          const { liveContext, openArticle } = latest.current;
          if (!history.length) chatContext.current = { context: liveContext, label: agentContextLabel(liveContext, openArticle?.title) };
          const context = chatContext.current?.context ?? liveContext;
          const prior = toAgentMessages(history);
          const messages = [...prior, { role: "user" as const, content: question }];
          const priorIds = [...prior].reverse().find((m) => m.role === "assistant")?.articleIds;
          let resp;
          try {
            resp = await askAgent(messages.map(({ role, content }) => ({ role, content })), context, priorIds);
          } catch (e) {
            throw new Error(String(e instanceof Error ? e.message : e));
          }
          const open = resp.actions.find((action) => action.type === "open_article");
          if (open) return { kind: "action", perform: () => openArticleById(open.article_id) };
          const data: AnswerData = { sources: resp.sources, articleIds: resp.article_ids, steps: resp.steps };
          // The articles the answer cited, ready to open.
          const cited = partitionSources(resp.sources, resp.content).cited.map(({ source, number }): PaletteCommand => ({
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
          return { kind: "answer", text: resp.content, data, commands: cited };
        },
        openFull: (prompt, history) => {
          const context = chatContext.current?.context ?? latest.current.liveContext;
          openAgentChat({
            context,
            articleTitle: context.article_id ? latest.current.openArticle?.title : null,
            messages: history.length ? toAgentMessages(history) : undefined,
            prompt: prompt || undefined,
            autoSend: !!prompt,
          });
        },
      },
    });
  }, []);

  const state = useSyncExternalStore(controller.subscribe, controller.getState, controller.getState);
  // The app mounts the palette while it is shown; follow the store if it stays mounted.
  const shown = useUiStore((s) => s.showCommandPalette);
  useEffect(() => { if (shown) controller.open(); }, [controller, shown]);

  // Commands depend on the open article, the view and loaded feeds; rebuild when their rows change.
  const signature = commands.map((c) => `${c.id}\u0000${c.title}\u0000${c.detail ?? ""}`).join("\u0001");
  useEffect(() => controller.refresh(), [controller, signature]);

  const chatting = state.mode === "answered" || state.mode === "pending";
  const loading = state.mode === "pending";
  const results = state.items;
  const activeIndex = state.active;
  const chatLabel = chatContext.current?.label ?? agentContextLabel(liveContext, openArticle?.title);

  useEffect(() => {
    listRef.current
      ?.querySelector<HTMLElement>(`[data-index="${activeIndex}"]`)
      ?.scrollIntoView?.({ block: "nearest" });
  }, [activeIndex]);

  useEffect(() => {
    if (loading) listRef.current?.scrollTo?.({ top: listRef.current.scrollHeight });
  }, [loading]);

  useEffect(() => {
    if (state.mode === "answered" || state.error) inputRef.current?.focus();
  }, [state.mode, state.error]);

  // Group headers only when browsing; a search shows one ranked list with
  // each row's group on the right.
  const browsing = state.showGroups;

  const renderRow = (command: PaletteCommand, index: number) => {
    const header = browsing && (index === 0 || results[index - 1].group !== command.group);
    const selected = index === activeIndex;
    const isAsk = isAskCommand(command);
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
          onMouseMove={() => { if (!selected) controller.setActive(index); }}
          onClick={() => controller.run(command)}
          className={`flex items-center gap-3 rounded-lg cursor-pointer ${selected ? "bg-white/10 text-text-primary" : "text-text-secondary"}`}
          style={{ padding: "8px 12px", fontSize: 14 }}
        >
          <span
            className={`flex items-center justify-center flex-shrink-0 ${isAsk ? "text-accent" : selected ? "text-text-primary" : "text-text-muted"}`}
            style={{ width: 18, height: 18 }}
          >
            {(() => {
              const Glyph = isAsk ? PALETTE_ICONS.sparkle : command.icon ? PALETTE_ICONS[command.icon] : undefined;
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
          maxHeight: chatting ? "min(640px, 76vh)" : "min(560px, 70vh)",
          marginTop: chatting ? "10vh" : "14vh",
          alignSelf: "flex-start",
        }}
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex items-center gap-3 border-b border-white/5" style={{ padding: "14px 18px" }}>
          {chatting ? (
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
            value={state.query}
            onChange={(e) => controller.setQuery(e.target.value)}
            onKeyDown={(e) => { if (controller.handleKey(e.nativeEvent)) e.preventDefault(); }}
            placeholder={chatting ? "Ask a follow-up…" : "Type a command, or ask anything…"}
            aria-label={chatting ? "Follow-up question" : "Search commands"}
            aria-controls="command-palette-list"
            aria-activedescendant={results.length ? `command-${activeIndex}` : undefined}
            role="combobox"
            aria-expanded="true"
            className="flex-1 bg-transparent text-text-primary placeholder-text-muted focus:outline-none"
            style={{ fontSize: 16 }}
          />
          <Kbd>esc</Kbd>
        </div>

        <div ref={listRef} id="command-palette-list" role="listbox" aria-label={chatting ? "Conversation" : undefined} className="flex-1 overflow-y-auto" style={{ padding: 6 }}>
          {chatting && (
            <div style={{ padding: "6px 12px 4px" }} aria-live="polite">
              <div className="text-text-muted" style={{ fontSize: 11, marginBottom: 8 }}>{chatLabel}</div>
              {state.history.map((turn, index) => turn.role === "user" ? (
                <p key={index} className="text-text-primary" style={{ fontSize: 15, fontWeight: 600, marginTop: index ? 18 : 0, marginBottom: 6 }}>
                  {turn.content}
                </p>
              ) : (
                <div key={index}>
                  <AgentSteps steps={(turn.data as AnswerData | undefined)?.steps ?? []} />
                  <AgentAnswer
                    content={turn.content}
                    sources={(turn.data as AnswerData | undefined)?.sources ?? []}
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
              {results.length > 0 && !(chatting && citationStyle() === "merged") && (
                <div className="text-text-muted uppercase" style={{ fontSize: 11, fontWeight: 600, letterSpacing: "0.06em", padding: "14px 0 2px" }}>
                  Articles
                </div>
              )}
            </div>
          )}
          {state.error && (isAiSetupError(state.error)
            ? <div style={{ padding: "6px 12px" }}><AiSetupNotice error={state.error} /></div>
            : <AiErrorText error={state.error} style={{ fontSize: 13, padding: "6px 12px" }} />)}
          {!chatting && results.length === 0 && (
            <p className="text-text-muted text-center" style={{ fontSize: 13, padding: "28px 12px" }}>
              No matching commands
            </p>
          )}
          {!(chatting && citationStyle() === "merged") && results.map(renderRow)}
        </div>

        <div className="flex items-center gap-4 border-t border-white/5 text-text-muted" style={{ padding: "8px 16px", fontSize: 11 }}>
          {chatting ? (
            <>
              {(state.query.trim() || results.length > 0) && (
                <span className="flex items-center gap-1"><Kbd>↵</Kbd> {state.query.trim() ? "ask" : "open article"}</span>
              )}
              <span className="flex items-center gap-1"><Kbd>⌫</Kbd> commands</span>
              <span className="flex-1" />
              <button
                type="button"
                onClick={() => controller.openFull()}
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
              {state.query.trim() && <span className="flex items-center gap-1"><Kbd>{formatShortcutKey("mod")}</Kbd><Kbd>↵</Kbd> ask in full chat</span>}
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
