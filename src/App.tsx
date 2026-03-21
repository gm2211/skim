import { Sidebar } from "./components/layout/Sidebar";
import { ArticleList } from "./components/layout/ArticleList";
import { ArticleDetail } from "./components/layout/ArticleDetail";
import { AddFeedDialog } from "./components/feed/AddFeedDialog";
import { SettingsDialog } from "./components/settings/SettingsDialog";
import { useUiStore } from "./stores/uiStore";
import { useEffect } from "react";

function App() {
  const { showAddFeed, showSettings, selectedArticleId } = useUiStore();

  // Keyboard shortcuts
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      // Don't handle if typing in an input
      if (
        e.target instanceof HTMLInputElement ||
        e.target instanceof HTMLTextAreaElement
      )
        return;

      if (e.key === "Escape") {
        useUiStore.getState().setShowAddFeed(false);
        useUiStore.getState().setShowSettings(false);
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, []);

  return (
    <div className="flex h-full w-full bg-bg-primary">
      <Sidebar />
      <div className="flex flex-1 min-w-0">
        <ArticleList />
        {selectedArticleId && <ArticleDetail />}
      </div>
      {showAddFeed && <AddFeedDialog />}
      {showSettings && <SettingsDialog />}
    </div>
  );
}

export default App;
