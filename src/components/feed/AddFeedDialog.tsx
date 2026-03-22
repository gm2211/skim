import { useState } from "react";
import { useAddFeed } from "../../hooks/useFeeds";
import { useUiStore } from "../../stores/uiStore";

export function AddFeedDialog() {
  const [url, setUrl] = useState("");
  const addFeed = useAddFeed();
  const setShowAddFeed = useUiStore((s) => s.setShowAddFeed);

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (!url.trim()) return;

    try {
      await addFeed.mutateAsync(url.trim());
      setShowAddFeed(false);
    } catch {
      // error is shown via addFeed.error
    }
  };

  return (
    <div className="fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center z-50">
      <div
        className="border border-white/10 rounded-2xl w-full max-w-md mx-4 shadow-2xl overflow-hidden"
        style={{ background: "rgba(22, 27, 34, 0.95)" }}
      >
        <div className="flex items-center justify-between" style={{ padding: "20px 24px 16px" }}>
          <h2 style={{ fontSize: 18, fontWeight: 600 }} className="text-text-primary">Add Feed</h2>
          <button
            onClick={() => setShowAddFeed(false)}
            className="text-text-muted hover:text-text-primary p-1 rounded-lg hover:bg-white/10 transition-colors"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M18 6L6 18M6 6l12 12" />
            </svg>
          </button>
        </div>

        <form onSubmit={handleSubmit} style={{ padding: "0 24px 24px" }}>
          <div style={{ marginBottom: 20 }}>
            <label className="block text-text-secondary" style={{ fontSize: 13, marginBottom: 8 }}>
              Feed URL
            </label>
            <input
              type="url"
              value={url}
              onChange={(e) => setUrl(e.target.value)}
              placeholder="https://example.com/feed.xml"
              autoFocus
              className="w-full border border-white/10 rounded-xl text-text-primary placeholder-text-muted focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/30 transition-colors"
              style={{
                background: "rgba(255, 255, 255, 0.05)",
                padding: "12px 16px",
                fontSize: 15,
              }}
            />
          </div>

          {addFeed.isError && (
            <div
              className="rounded-xl border border-danger/30 text-danger"
              style={{ padding: "12px 16px", marginBottom: 20, fontSize: 14, background: "rgba(248, 81, 73, 0.1)" }}
            >
              {String(addFeed.error instanceof Error ? addFeed.error.message : addFeed.error)}
            </div>
          )}

          <div className="flex justify-end gap-3">
            <button
              type="button"
              onClick={() => setShowAddFeed(false)}
              className="text-text-secondary hover:text-text-primary rounded-xl hover:bg-white/5 transition-colors"
              style={{ padding: "10px 20px", fontSize: 14 }}
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={addFeed.isPending || !url.trim()}
              className="bg-accent text-white rounded-xl hover:bg-accent-hover disabled:opacity-40 font-medium transition-colors"
              style={{ padding: "10px 24px", fontSize: 14 }}
            >
              {addFeed.isPending ? "Adding..." : "Add Feed"}
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
