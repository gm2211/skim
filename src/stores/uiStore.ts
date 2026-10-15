import { create } from "zustand";
import type { SidebarView } from "../services/types";

type ListFilter = "all" | "unread" | "starred";
/** "For you" ranks a list's unread articles the way the AI Inbox did. */
export type ListSort = "newest" | "forYou";
export type AddFeedTab = "url" | "feedly";
export type SettingsTab = "ai" | "sync" | "appearance" | "reading";

type PhonePane = "sidebar" | "list" | "detail";
type ArticleReturnTarget = "today";

interface UiState {
  sidebarView: SidebarView;
  /** Which page of the paper Today shows: 1 is today's edition, each page after it a week earlier. */
  todayPage: number;
  selectedArticleId: string | null;
  articleReturnTarget: ArticleReturnTarget | null;
  // Browser-style history of opened articles. `articleHistoryIndex` points at
  // the article currently shown (or, when the reader is closed, the last one
  // shown, so Back reopens it).
  articleHistory: string[];
  articleHistoryIndex: number;
  showAddFeed: boolean;
  addFeedTab: AddFeedTab;
  showSettings: boolean;
  settingsTab: SettingsTab;
  showCommandPalette: boolean;
  sidebarCollapsed: boolean;
  sidebarManualCollapse: boolean;
  listCollapsed: boolean;
  listManualCollapse: boolean;
  listFilter: ListFilter;
  listSort: ListSort;
  // Phone-mode: single visible pane at a time. Sidebar/list/detail are
  // pushed onto a stack and navigated via buttons or swipe-right-to-back.
  isPhone: boolean;
  phonePane: PhonePane;

  setSidebarView: (view: SidebarView) => void;
  setSelectedArticleId: (id: string | null) => void;
  openArticleFromToday: (id: string) => void;
  closeArticleDetail: () => void;
  goBackArticle: () => void;
  goForwardArticle: () => void;
  setShowAddFeed: (show: boolean, tab?: AddFeedTab) => void;
  setShowSettings: (show: boolean, tab?: SettingsTab) => void;
  setShowCommandPalette: (show: boolean) => void;
  setTodayPage: (page: number) => void;
  toggleSidebar: () => void;
  toggleList: () => void;
  setListFilter: (filter: ListFilter) => void;
  setListSort: (sort: ListSort) => void;
  setPhonePane: (pane: PhonePane) => void;
  phoneBack: () => void;
  applyResponsiveLayout: (width: number) => void;
}

const SIDEBAR_COLLAPSE = 1100;
const LIST_COLLAPSE = 830;
// Phone-class widths force the sidebar collapsed and let the article list
// take the full viewport (single-pane mobile layout).
const PHONE_BREAKPOINT = 600;
const MAX_ARTICLE_HISTORY = 100;

type ArticleHistory = Pick<UiState, "articleHistory" | "articleHistoryIndex">;

/** Record `id` as the newest history entry, dropping any forward entries. */
function pushArticleHistory(state: UiState, id: string | null): ArticleHistory {
  const { articleHistory, articleHistoryIndex } = state;
  if (!id || articleHistory[articleHistoryIndex] === id) {
    return { articleHistory, articleHistoryIndex };
  }
  const next = [...articleHistory.slice(0, articleHistoryIndex + 1), id].slice(-MAX_ARTICLE_HISTORY);
  return { articleHistory: next, articleHistoryIndex: next.length - 1 };
}

export function canGoBackArticle(state: Pick<UiState, "selectedArticleId" | "articleHistoryIndex">): boolean {
  return state.selectedArticleId ? state.articleHistoryIndex > 0 : state.articleHistoryIndex >= 0;
}

export function canGoForwardArticle(state: Pick<UiState, "selectedArticleId" | "articleHistory" | "articleHistoryIndex">): boolean {
  return !!state.selectedArticleId && state.articleHistoryIndex < state.articleHistory.length - 1;
}

export const useUiStore = create<UiState>((set, get) => ({
  sidebarView: { type: "all" },
  todayPage: 1,
  selectedArticleId: null,
  articleReturnTarget: null,
  articleHistory: [],
  articleHistoryIndex: -1,
  showAddFeed: false,
  addFeedTab: "url",
  showSettings: false,
  settingsTab: "ai",
  showCommandPalette: false,
  sidebarCollapsed: false,
  sidebarManualCollapse: false,
  listCollapsed: false,
  listManualCollapse: false,
  listFilter: "unread",
  listSort: "newest",
  isPhone: false,
  phonePane: "list",

  setSidebarView: (view) =>
    set((state) => ({
      sidebarView: view,
      selectedArticleId: null,
      articleReturnTarget: null,
      // On phone, picking a feed/view from the sidebar drawer pops back to
      // the list pane so the user immediately sees the chosen feed.
      phonePane: state.isPhone ? "list" : state.phonePane,
    })),
  setSelectedArticleId: (id) =>
    set((state) => ({
      ...pushArticleHistory(state, id),
      selectedArticleId: id,
      articleReturnTarget: null,
      phonePane: state.isPhone && id ? "detail" : state.phonePane,
    })),
  openArticleFromToday: (id) =>
    set((state) => ({
      ...pushArticleHistory(state, id),
      selectedArticleId: id,
      articleReturnTarget: "today",
      phonePane: state.isPhone ? "detail" : state.phonePane,
    })),
  closeArticleDetail: () =>
    set((state) => {
      // An article opened from Today closes back onto that
      // page, which is still the view in the list column.
      return {
        selectedArticleId: null,
        articleReturnTarget: null,
        phonePane: state.isPhone ? "list" : state.phonePane,
      };
    }),
  goBackArticle: () =>
    set((state) => {
      if (!canGoBackArticle(state)) return state;
      const index = state.selectedArticleId ? state.articleHistoryIndex - 1 : state.articleHistoryIndex;
      return {
        articleHistoryIndex: index,
        selectedArticleId: state.articleHistory[index],
        articleReturnTarget: null,
              phonePane: state.isPhone ? "detail" : state.phonePane,
      };
    }),
  goForwardArticle: () =>
    set((state) => {
      if (!canGoForwardArticle(state)) return state;
      const index = state.articleHistoryIndex + 1;
      return {
        articleHistoryIndex: index,
        selectedArticleId: state.articleHistory[index],
        articleReturnTarget: null,
              phonePane: state.isPhone ? "detail" : state.phonePane,
      };
    }),
  // Adding feeds happens in the Discover view; only importing (OPML/Feedly)
  // still opens the dialog.
  setShowAddFeed: (show, tab) =>
    set((state) =>
      show && (tab ?? "url") === "url"
        ? {
            showAddFeed: false,
            sidebarView: { type: "discover" },
            selectedArticleId: null,
            articleReturnTarget: null,
            phonePane: state.isPhone ? "list" : state.phonePane,
          }
        : { showAddFeed: show, addFeedTab: show ? tab ?? "feedly" : state.addFeedTab },
    ),
  setShowSettings: (show, tab) =>
    set((state) => ({
      showSettings: show,
      // Each open starts on the AI tab unless a caller asks for another.
      settingsTab: show ? tab ?? "ai" : state.settingsTab,
    })),
  setShowCommandPalette: (show) => set({ showCommandPalette: show }),
  setTodayPage: (page) => set({ todayPage: Math.max(1, Math.floor(page)) }),

  toggleSidebar: () =>
    set((state) => {
      const next = !state.sidebarCollapsed;
      return { sidebarCollapsed: next, sidebarManualCollapse: next };
    }),

  toggleList: () =>
    set((state) => {
      const next = !state.listCollapsed;
      return { listCollapsed: next, listManualCollapse: next };
    }),

  setListFilter: (filter) => set({ listFilter: filter }),
  setListSort: (sort) => set({ listSort: sort }),

  setPhonePane: (pane) => set({ phonePane: pane }),
  phoneBack: () =>
    set((state) => {
      if (state.phonePane === "detail") {
        return { phonePane: "list", selectedArticleId: null, articleReturnTarget: null };
      }
      if (state.phonePane === "sidebar") return { phonePane: "list" };
      return state;
    }),

  applyResponsiveLayout: (width: number) => {
    const state = get();
    const updates: Partial<UiState> = {};

    const phone = width < PHONE_BREAKPOINT;
    if (phone !== state.isPhone) {
      updates.isPhone = phone;
      // Entering phone mode: clear old desktop collapse state so the
      // single-pane layout starts fresh on the list.
      if (phone) {
        updates.phonePane = "list";
      }
    }

    // Collapse: sidebar first (at wider breakpoint), then list (at narrower)
    if (width < SIDEBAR_COLLAPSE && !state.sidebarCollapsed) {
      updates.sidebarCollapsed = true;
    }
    if (width < LIST_COLLAPSE && !state.listCollapsed) {
      updates.listCollapsed = true;
    }

    // Re-expand when space returns (only auto-collapsed, not manual)
    if (width >= LIST_COLLAPSE && state.listCollapsed && !state.listManualCollapse) {
      updates.listCollapsed = false;
    }
    if (width >= SIDEBAR_COLLAPSE && state.sidebarCollapsed && !state.sidebarManualCollapse) {
      updates.sidebarCollapsed = false;
    }

    if (Object.keys(updates).length > 0) {
      set(updates);
    }
  },
}));
