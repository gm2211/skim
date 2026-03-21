import { useEffect } from "react";
import { useArticle, useMarkRead, useToggleStar } from "../../hooks/useArticles";
import { useSummarizeArticle } from "../../hooks/useAi";
import { useUiStore } from "../../stores/uiStore";

function formatDate(timestamp: number | null): string {
  if (!timestamp) return "";
  const date = new Date(timestamp * 1000);
  return date.toLocaleDateString("en-US", {
    weekday: "short",
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

export function ArticleDetail() {
  const { selectedArticleId, setSelectedArticleId } = useUiStore();
  const { data: article } = useArticle(selectedArticleId);
  const markRead = useMarkRead();
  const toggleStar = useToggleStar();
  const summarize = useSummarizeArticle();

  // Mark as read when opened
  useEffect(() => {
    if (article && !article.is_read) {
      markRead.mutate([article.id]);
    }
  }, [article?.id]);

  if (!article) {
    return (
      <div className="flex-1 flex items-center justify-center bg-bg-primary">
        <span className="text-text-muted text-sm">Select an article to read</span>
      </div>
    );
  }

  return (
    <div className="flex-1 flex flex-col h-full bg-bg-primary overflow-hidden">
      {/* Toolbar */}
      <div className="px-4 py-2 border-b border-border-light flex items-center justify-between bg-bg-secondary">
        <div className="flex items-center gap-2">
          <button
            onClick={() => setSelectedArticleId(null)}
            className="text-text-muted hover:text-text-primary p-1"
            title="Close"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M18 6L6 18M6 6l12 12" />
            </svg>
          </button>
        </div>
        <div className="flex items-center gap-1">
          <button
            onClick={() => summarize.mutate(article.id)}
            disabled={summarize.isPending}
            className="text-xs px-2.5 py-1 rounded border border-border text-text-secondary hover:text-text-primary hover:border-accent transition-colors disabled:opacity-50"
          >
            {summarize.isPending ? "Summarizing..." : "Summarize"}
          </button>
          <button
            onClick={() => toggleStar.mutate(article.id)}
            className={`p-1 rounded hover:bg-bg-hover ${
              article.is_starred ? "text-warning" : "text-text-muted hover:text-text-primary"
            }`}
            title={article.is_starred ? "Unstar" : "Star"}
          >
            <svg
              width="16"
              height="16"
              viewBox="0 0 24 24"
              fill={article.is_starred ? "currentColor" : "none"}
              stroke="currentColor"
              strokeWidth="2"
            >
              <polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2" />
            </svg>
          </button>
          {article.url && (
            <a
              href={article.url}
              target="_blank"
              rel="noopener noreferrer"
              className="text-text-muted hover:text-text-primary p-1 rounded hover:bg-bg-hover"
              title="Open in browser"
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6M15 3h6v6M10 14L21 3" />
              </svg>
            </a>
          )}
        </div>
      </div>

      {/* Content */}
      <div className="flex-1 overflow-y-auto">
        <div className="max-w-3xl mx-auto px-6 py-6">
          {/* Header */}
          <div className="mb-6">
            <h1 className="text-xl font-bold leading-tight mb-2">
              {article.title}
            </h1>
            <div className="flex items-center gap-3 text-xs text-text-muted">
              <span className="text-accent">{article.feed_title}</span>
              {article.author && <span>by {article.author}</span>}
              <span>{formatDate(article.published_at)}</span>
            </div>
          </div>

          {/* AI Summary */}
          {summarize.data && (
            <div className="mb-6 p-4 rounded-lg border border-border bg-bg-secondary">
              <div className="text-xs text-text-muted mb-2 uppercase tracking-wider">
                AI Summary
                {summarize.data.provider && (
                  <span className="ml-2 normal-case">
                    via {summarize.data.provider}
                    {summarize.data.model && ` / ${summarize.data.model}`}
                  </span>
                )}
              </div>
              {summarize.data.bullet_summary && (
                <div className="text-sm text-text-primary mb-3 whitespace-pre-wrap">
                  {summarize.data.bullet_summary}
                </div>
              )}
              {summarize.data.full_summary && (
                <div className="text-sm text-text-secondary leading-relaxed">
                  {summarize.data.full_summary}
                </div>
              )}
            </div>
          )}

          {summarize.isError && (
            <div className="mb-6 p-3 rounded-lg border border-danger/30 bg-danger/10 text-sm text-danger">
              {(summarize.error as Error)?.message ?? "Failed to summarize article"}
            </div>
          )}

          {/* Article body */}
          {article.content_html ? (
            <div
              className="article-content text-text-primary"
              dangerouslySetInnerHTML={{ __html: article.content_html }}
            />
          ) : article.content_text ? (
            <div className="article-content text-text-primary whitespace-pre-wrap">
              {article.content_text}
            </div>
          ) : (
            <p className="text-text-muted text-sm">
              No content available.{" "}
              {article.url && (
                <a
                  href={article.url}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-accent hover:underline"
                >
                  Open in browser
                </a>
              )}
            </p>
          )}
        </div>
      </div>
    </div>
  );
}
