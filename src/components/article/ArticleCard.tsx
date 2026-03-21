import type { Article } from "../../services/types";

interface Props {
  article: Article;
  isSelected: boolean;
  onSelect: () => void;
}

function timeAgo(timestamp: number | null): string {
  if (!timestamp) return "";
  const now = Date.now() / 1000;
  const diff = now - timestamp;

  if (diff < 60) return "just now";
  if (diff < 3600) return `${Math.floor(diff / 60)}m`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h`;
  if (diff < 604800) return `${Math.floor(diff / 86400)}d`;
  return new Date(timestamp * 1000).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
  });
}

export function ArticleCard({ article, isSelected, onSelect }: Props) {
  return (
    <div
      onClick={onSelect}
      className={`px-3 py-2.5 border-b border-border-light cursor-pointer transition-colors ${
        isSelected
          ? "bg-bg-active"
          : "hover:bg-bg-hover"
      }`}
    >
      <div className="flex items-start justify-between gap-2">
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-1.5 mb-0.5">
            <span className="text-[11px] text-accent truncate">
              {article.feed_title}
            </span>
            <span className="text-[11px] text-text-muted">
              {timeAgo(article.published_at ?? article.fetched_at)}
            </span>
          </div>
          <h3
            className={`text-sm leading-snug line-clamp-2 ${
              article.is_read
                ? "text-text-muted font-normal"
                : "text-text-primary font-medium"
            }`}
          >
            {article.title}
          </h3>
          {article.content_text && (
            <p className="text-xs text-text-muted line-clamp-1 mt-0.5">
              {article.content_text.slice(0, 120)}
            </p>
          )}
        </div>
        <div className="flex flex-col items-center gap-1 pt-0.5">
          {!article.is_read && (
            <div className="w-2 h-2 rounded-full bg-accent" title="Unread" />
          )}
          {article.is_starred && (
            <svg
              width="12"
              height="12"
              viewBox="0 0 24 24"
              fill="currentColor"
              className="text-warning"
            >
              <polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2" />
            </svg>
          )}
        </div>
      </div>
    </div>
  );
}
