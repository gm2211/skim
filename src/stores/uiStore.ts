import { create } from "zustand";
import type { SidebarView } from "../services/types";

interface UiState {
  sidebarView: SidebarView;
  selectedArticleId: string | null;
  showAddFeed: boolean;
  showSettings: boolean;
  sidebarCollapsed: boolean;

  setSidebarView: (view: SidebarView) => void;
  setSelectedArticleId: (id: string | null) => void;
  setShowAddFeed: (show: boolean) => void;
  setShowSettings: (show: boolean) => void;
  toggleSidebar: () => void;
}

export const useUiStore = create<UiState>((set) => ({
  sidebarView: { type: "all" },
  selectedArticleId: null,
  showAddFeed: false,
  showSettings: false,
  sidebarCollapsed: false,

  setSidebarView: (view) =>
    set({ sidebarView: view, selectedArticleId: null }),
  setSelectedArticleId: (id) => set({ selectedArticleId: id }),
  setShowAddFeed: (show) => set({ showAddFeed: show }),
  setShowSettings: (show) => set({ showSettings: show }),
  toggleSidebar: () =>
    set((state) => ({ sidebarCollapsed: !state.sidebarCollapsed })),
}));
