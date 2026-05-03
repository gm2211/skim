import { create } from "zustand";
import type { SidebarView } from "../services/types";

type ListFilter = "all" | "unread" | "starred";

type PhonePane = "sidebar" | "list" | "detail";
type ArticleReturnTarget = "catchup";

interface UiState {
  sidebarView: SidebarView;
  selectedArticleId: string | null;
  articleReturnTarget: ArticleReturnTarget | null;
  showAddFeed: boolean;
  showSettings: boolean;
  showCatchup: boolean;
  sidebarCollapsed: boolean;
  sidebarManualCollapse: boolean;
  listCollapsed: boolean;
  listManualCollapse: boolean;
  listFilter: ListFilter;
  // Phone-mode: single visible pane at a time. Sidebar/list/detail are
  // pushed onto a stack and navigated via buttons or swipe-right-to-back.
  isPhone: boolean;
  phonePane: PhonePane;

  setSidebarView: (view: SidebarView) => void;
  setSelectedArticleId: (id: string | null) => void;
  openArticleFromCatchup: (id: string) => void;
  closeArticleDetail: () => void;
  setShowAddFeed: (show: boolean) => void;
  setShowSettings: (show: boolean) => void;
  setShowCatchup: (show: boolean) => void;
  toggleSidebar: () => void;
  toggleList: () => void;
  setListFilter: (filter: ListFilter) => void;
  setPhonePane: (pane: PhonePane) => void;
  phoneBack: () => void;
  applyResponsiveLayout: (width: number) => void;
}

const SIDEBAR_COLLAPSE = 1100;
const LIST_COLLAPSE = 830;
// Phone-class widths force the sidebar collapsed and let the article list
// take the full viewport (single-pane mobile layout).
const PHONE_BREAKPOINT = 600;

export const useUiStore = create<UiState>((set, get) => ({
  sidebarView: { type: "all" },
  selectedArticleId: null,
  articleReturnTarget: null,
  showAddFeed: false,
  showSettings: false,
  showCatchup: false,
  sidebarCollapsed: false,
  sidebarManualCollapse: false,
  listCollapsed: false,
  listManualCollapse: false,
  listFilter: "unread",
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
      selectedArticleId: id,
      articleReturnTarget: null,
      phonePane: state.isPhone && id ? "detail" : state.phonePane,
    })),
  openArticleFromCatchup: (id) =>
    set((state) => ({
      selectedArticleId: id,
      articleReturnTarget: "catchup",
      showCatchup: false,
      phonePane: state.isPhone ? "detail" : state.phonePane,
    })),
  closeArticleDetail: () =>
    set((state) => {
      if (state.articleReturnTarget === "catchup") {
        return {
          selectedArticleId: null,
          articleReturnTarget: null,
          showCatchup: true,
          phonePane: state.isPhone ? "list" : state.phonePane,
        };
      }
      return {
        selectedArticleId: null,
        articleReturnTarget: null,
        phonePane: state.isPhone ? "list" : state.phonePane,
      };
    }),
  setShowAddFeed: (show) => set({ showAddFeed: show }),
  setShowSettings: (show) => set({ showSettings: show }),
  setShowCatchup: (show) => set({ showCatchup: show }),

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

  setPhonePane: (pane) => set({ phonePane: pane }),
  phoneBack: () =>
    set((state) => {
      if (state.phonePane === "detail") {
        if (state.articleReturnTarget === "catchup") {
          return {
            phonePane: "list",
            selectedArticleId: null,
            articleReturnTarget: null,
            showCatchup: true,
          };
        }
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
