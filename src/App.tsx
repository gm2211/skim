import { Sidebar } from "./components/layout/Sidebar";
import { ArticleList } from "./components/layout/ArticleList";
import { ArticleDetail } from "./components/layout/ArticleDetail";
import { AddFeedDialog } from "./components/feed/AddFeedDialog";
import { SettingsDialog } from "./components/settings/SettingsDialog";
import { useUiStore } from "./stores/uiStore";
import { useEffect, useRef } from "react";
import { triageArticles, refreshAllFeeds, importOpml } from "./services/commands";
import { useQueryClient } from "@tanstack/react-query";

function App() {
  const { showAddFeed, showSettings, selectedArticleId, listCollapsed } = useUiStore();
  const qc = useQueryClient();

  // Auto-triage on startup
  useEffect(() => {
    triageArticles(false).then(() => {
      qc.invalidateQueries({ queryKey: ["inbox"] });
      qc.invalidateQueries({ queryKey: ["triageStats"] });
    }).catch(() => {});
  }, []);

  // Auto-refresh on window focus if last refresh was > 1 hour ago.
  const lastRefreshRef = useRef<number>(Date.now());
  useEffect(() => {
    const STALE_MS = 60 * 60 * 1000;
    const onFocus = () => {
      if (Date.now() - lastRefreshRef.current < STALE_MS) return;
      lastRefreshRef.current = Date.now();
      refreshAllFeeds()
        .then(() => {
          qc.invalidateQueries({ queryKey: ["feeds"] });
          qc.invalidateQueries({ queryKey: ["articles"] });
          qc.invalidateQueries({ queryKey: ["articleCount"] });
          return triageArticles(false);
        })
        .then(() => {
          qc.invalidateQueries({ queryKey: ["inbox"] });
          qc.invalidateQueries({ queryKey: ["triageStats"] });
        })
        .catch(() => {});
    };
    window.addEventListener("focus", onFocus);
    return () => window.removeEventListener("focus", onFocus);
  }, [qc]);

  // Responsive auto-collapse
  useEffect(() => {
    const apply = () => {
      const width = document.documentElement.clientWidth;
      useUiStore.getState().applyResponsiveLayout(width);
    };
    apply();
    const observer = new ResizeObserver(apply);
    observer.observe(document.documentElement);
    return () => observer.disconnect();
  }, []);

  // OPML drag-drop import (iPad split-view from Files, desktop drop)
  useEffect(() => {
    const onDragOver = (e: DragEvent) => {
      if (e.dataTransfer?.types.includes("Files")) e.preventDefault();
    };
    const onDrop = async (e: DragEvent) => {
      const files = e.dataTransfer?.files;
      if (!files || files.length === 0) return;
      e.preventDefault();
      for (const file of Array.from(files)) {
        const name = file.name.toLowerCase();
        if (!name.endsWith(".opml") && !name.endsWith(".xml")) continue;
        try {
          const xml = await file.text();
          await importOpml(xml);
          qc.invalidateQueries({ queryKey: ["feeds"] });
          qc.invalidateQueries({ queryKey: ["articles"] });
        } catch (err) {
          console.error("OPML drop import failed", err);
        }
      }
    };
    window.addEventListener("dragover", onDragOver);
    window.addEventListener("drop", onDrop);
    return () => {
      window.removeEventListener("dragover", onDragOver);
      window.removeEventListener("drop", onDrop);
    };
  }, [qc]);

  // Disable default context menu
  useEffect(() => {
    const prevent = (e: MouseEvent) => e.preventDefault();
    document.addEventListener("contextmenu", prevent);
    return () => document.removeEventListener("contextmenu", prevent);
  }, []);

  // Keyboard shortcuts
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      // Block devtools shortcuts everywhere
      const key = e.key.toLowerCase();
      if (
        (key === "i" && (e.metaKey || e.ctrlKey) && e.altKey) || // Cmd+Option+I
        (key === "j" && (e.metaKey || e.ctrlKey) && e.altKey) || // Cmd+Option+J
        (key === "c" && (e.metaKey || e.ctrlKey) && e.shiftKey) || // Cmd+Shift+C
        (key === "u" && (e.metaKey || e.ctrlKey)) || // Cmd+U (view source)
        e.key === "F12"
      ) {
        e.preventDefault();
        return;
      }

      // Global shortcuts — work even when typing in inputs
      if (e.key === "," && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        useUiStore.getState().setShowSettings(true);
        return;
      }

      if (
        e.target instanceof HTMLInputElement ||
        e.target instanceof HTMLTextAreaElement
      )
        return;

      if (e.key === "Escape") {
        useUiStore.getState().setShowAddFeed(false);
        useUiStore.getState().setShowSettings(false);
      }
      if (e.key === "[" && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        useUiStore.getState().toggleSidebar();
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, []);

  return (
    <div className="flex flex-col h-full w-full">
      {/* Full-width drag region for window movement */}
      <div
        className="h-12 w-full flex-shrink-0 absolute top-0 left-0 right-0 z-10"
        data-tauri-drag-region
        style={{ WebkitAppRegion: "drag" } as React.CSSProperties}
      />
      <div className="flex flex-1 min-h-0">
        <Sidebar />
        <div className="flex flex-1 min-w-0">
          <ArticleList />
          {selectedArticleId ? (
            <ArticleDetail />
          ) : (
            <div
              className={`flex-1 flex flex-col items-center justify-center bg-bg-primary/60 select-none ${listCollapsed ? "cursor-pointer" : ""}`}
              onClick={() => {
                const state = useUiStore.getState();
                if (state.listCollapsed) state.toggleList();
              }}
            >
              <div className="text-text-muted flex items-center gap-2">
                {listCollapsed && (
                  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                    <rect x="3" y="3" width="18" height="18" rx="2" />
                    <path d="M9 3v18" />
                  </svg>
                )}
                <span className="text-sm">{listCollapsed ? "Show article list" : "Select an article to read"}</span>
              </div>
            </div>
          )}
        </div>
      </div>
      {showAddFeed && <AddFeedDialog />}
      {showSettings && <SettingsDialog />}
    </div>
  );
}

export default App;
