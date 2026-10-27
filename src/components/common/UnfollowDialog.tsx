/**
 * Asks before unfollowing a feed, because unfollowing deletes its articles.
 * Used by the feed list's menu and by Discover's Following button.
 */
export function UnfollowDialog({ title, starredCount, pending, onCancel, onConfirm }: {
  title: string;
  starredCount: number;
  pending: boolean;
  onCancel: () => void;
  onConfirm: () => void;
}) {
  return (
    <div
      className="fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center z-50"
      onClick={onCancel}
    >
      <div
        role="dialog"
        aria-modal="true"
        aria-label={`Unfollow ${title}?`}
        className="border border-white/10 rounded-2xl shadow-2xl"
        style={{ background: "rgba(22, 27, 34, 0.98)", maxWidth: 420, width: "100%", margin: "0 20px" }}
        onClick={(e) => e.stopPropagation()}
      >
        <div style={{ padding: "20px 24px 16px" }}>
          <h3 className="text-text-primary" style={{ fontSize: 16, fontWeight: 600, marginBottom: 8, overflowWrap: "anywhere" }}>
            Unfollow "{title}"?
          </h3>
          {starredCount > 0 ? (
            <p className="text-text-secondary" style={{ fontSize: 13 }}>
              This feed has{" "}
              <strong className="text-amber-400">
                {starredCount} starred article{starredCount !== 1 ? "s" : ""}
              </strong>
              . Unfollowing deletes all its articles, including the starred ones.
            </p>
          ) : (
            <p className="text-text-muted" style={{ fontSize: 13 }}>
              All articles from this feed will be deleted. You can follow it again from Discover.
            </p>
          )}
        </div>
        <div className="flex justify-end gap-2 border-t border-white/5" style={{ padding: "12px 20px" }}>
          <button
            onClick={onCancel}
            className="text-text-secondary hover:text-text-primary rounded-lg hover:bg-white/5 transition-colors"
            style={{ padding: "8px 16px", fontSize: 13 }}
          >
            Cancel
          </button>
          <button
            onClick={onConfirm}
            disabled={pending}
            autoFocus
            className="bg-danger text-white rounded-lg hover:bg-red-600 disabled:opacity-40 transition-colors font-medium"
            style={{ padding: "8px 16px", fontSize: 13 }}
          >
            {pending ? "Unfollowing…" : "Unfollow"}
          </button>
        </div>
      </div>
    </div>
  );
}
