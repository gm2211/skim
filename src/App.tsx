import { Sidebar } from "./components/layout/Sidebar";
import { ArticleList } from "./components/layout/ArticleList";
import { ArticleDetail } from "./components/layout/ArticleDetail";
import { AddFeedDialog } from "./components/feed/AddFeedDialog";
import { SettingsDialog } from "./components/settings/SettingsDialog";
import { useUiStore } from "./stores/uiStore";
import { useEffect } from "react";

function App() {
  const { showAddFeed, showSettings, selectedArticleId, listCollapsed } = useUiStore();

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

      if (
        e.target instanceof HTMLInputElement ||
        e.target instanceof HTMLTextAreaElement
      )
        return;

      if (e.key === "Escape") {
        useUiStore.getState().setShowAddFeed(false);
        useUiStore.getState().setShowSettings(false);
      }
      if (e.key === "," && (e.metaKey || e.ctrlKey)) {
        e.preventDefault();
        useUiStore.getState().setShowSettings(true);
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
