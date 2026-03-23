import { create } from "zustand";
import type { SidebarView } from "../services/types";

type ListFilter = "all" | "unread" | "starred";

interface UiState {
  sidebarView: SidebarView;
  selectedArticleId: string | null;
  showAddFeed: boolean;
  showSettings: boolean;
  sidebarCollapsed: boolean;
  sidebarManualCollapse: boolean;
  listCollapsed: boolean;
  listManualCollapse: boolean;
  listFilter: ListFilter;

  setSidebarView: (view: SidebarView) => void;
  setSelectedArticleId: (id: string | null) => void;
  setShowAddFeed: (show: boolean) => void;
  setShowSettings: (show: boolean) => void;
  toggleSidebar: () => void;
  toggleList: () => void;
  setListFilter: (filter: ListFilter) => void;
  applyResponsiveLayout: (width: number) => void;
}

const SIDEBAR_COLLAPSE = 1100;
const LIST_COLLAPSE = 830;

export const useUiStore = create<UiState>((set, get) => ({
  sidebarView: { type: "all" },
  selectedArticleId: null,
  showAddFeed: false,
  showSettings: false,
  sidebarCollapsed: false,
  sidebarManualCollapse: false,
  listCollapsed: false,
  listManualCollapse: false,
  listFilter: "all",

  setSidebarView: (view) =>
    set({ sidebarView: view, selectedArticleId: null }),
  setSelectedArticleId: (id) => set({ selectedArticleId: id }),
  setShowAddFeed: (show) => set({ showAddFeed: show }),
  setShowSettings: (show) => set({ showSettings: show }),

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

  applyResponsiveLayout: (width: number) => {
    const state = get();
    const updates: Partial<UiState> = {};

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
