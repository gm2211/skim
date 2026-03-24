import { useEffect, useRef } from "react";
import type { Article } from "../../services/types";

interface Props {
  x: number;
  y: number;
  article: Article;
  onClose: () => void;
  onToggleRead: () => void;
  onToggleStar: () => void;
  onMarkAboveRead: () => void;
  onMarkBelowRead: () => void;
  onMarkAboveUnread: () => void;
  onMarkBelowUnread: () => void;
  onCopyLink: () => void;
}

export function ArticleContextMenu({
  x,
  y,
  article,
  onClose,
  onToggleRead,
  onToggleStar,
  onMarkAboveRead,
  onMarkBelowRead,
  onMarkAboveUnread,
  onMarkBelowUnread,
  onCopyLink,
}: Props) {
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) onClose();
    };
    const keyHandler = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("mousedown", handler);
    document.addEventListener("keydown", keyHandler);
    return () => {
      document.removeEventListener("mousedown", handler);
      document.removeEventListener("keydown", keyHandler);
    };
  }, [onClose]);

  // Adjust position to stay within viewport
  useEffect(() => {
    if (!ref.current) return;
    const rect = ref.current.getBoundingClientRect();
    if (rect.right > window.innerWidth) {
      ref.current.style.left = `${x - rect.width}px`;
    }
    if (rect.bottom > window.innerHeight) {
      ref.current.style.top = `${y - rect.height}px`;
    }
  }, [x, y]);

  const item = (
    label: string,
    onClick: () => void,
    icon: React.ReactNode
  ) => (
    <button
      onClick={() => {
        onClick();
        onClose();
      }}
      className="flex items-center gap-3 w-full text-left text-text-primary hover:bg-white/10 rounded-md transition-colors"
      style={{ padding: "7px 12px", fontSize: 13 }}
    >
      <span className="w-4 flex-shrink-0 flex items-center justify-center opacity-70">
        {icon}
      </span>
      {label}
    </button>
  );

  return (
    <div
      ref={ref}
      className="fixed z-50 rounded-xl border border-white/10 shadow-2xl backdrop-blur-xl"
      style={{
        left: x,
        top: y,
        background: "rgba(30, 35, 45, 0.92)",
        padding: "6px",
        minWidth: 220,
      }}
    >
      {/* Article header */}
      <div
        className="flex items-center gap-3 border-b border-white/10"
        style={{ padding: "8px 12px 10px" }}
      >
        <div
          className="rounded-md bg-accent/20 text-accent flex items-center justify-center font-bold flex-shrink-0"
          style={{ width: 36, height: 36, fontSize: 14 }}
        >
          {(article.feed_title || "?")[0].toUpperCase()}
        </div>
        <div className="min-w-0">
          <p className="text-text-primary font-medium truncate" style={{ fontSize: 13 }}>
            {article.title}
          </p>
          <p className="text-text-muted truncate" style={{ fontSize: 11 }}>
            {article.feed_title}
          </p>
        </div>
      </div>

      <div style={{ padding: "4px 0" }}>
        {item(
          article.is_read ? "Mark as Unread" : "Mark as Read",
          onToggleRead,
          <svg width="14" height="14" viewBox="0 0 24 24" fill={article.is_read ? "currentColor" : "none"} stroke="currentColor" strokeWidth="2">
            <circle cx="12" cy="12" r="5" />
          </svg>
        )}

        {item(
          article.is_starred ? "Unstar" : "Star",
          onToggleStar,
          <svg width="14" height="14" viewBox="0 0 24 24" fill={article.is_starred ? "currentColor" : "none"} stroke="currentColor" strokeWidth="1.5" className={article.is_starred ? "text-warning" : ""}>
            <polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2" />
          </svg>
        )}
      </div>

      <div className="border-t border-white/10" style={{ padding: "4px 0" }}>
        {item(
          "Mark Above as Read",
          onMarkAboveRead,
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M12 19V5M5 12l7-7 7 7" />
          </svg>
        )}

        {item(
          "Mark Below as Read",
          onMarkBelowRead,
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M12 5v14M5 12l7 7 7-7" />
          </svg>
        )}

        {item(
          "Mark Above as Unread",
          onMarkAboveUnread,
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M12 19V5M5 12l7-7 7 7" />
          </svg>
        )}

        {item(
          "Mark Below as Unread",
          onMarkBelowUnread,
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M12 5v14M5 12l7 7 7-7" />
          </svg>
        )}
      </div>

      <div className="border-t border-white/10" style={{ padding: "4px 0" }}>
        {item(
          "Copy Link",
          onCopyLink,
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71" />
            <path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71" />
          </svg>
        )}
      </div>
    </div>
  );
}
