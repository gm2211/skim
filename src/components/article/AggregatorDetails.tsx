import { useQuery } from "@tanstack/react-query";
import { openUrl } from "@tauri-apps/plugin-opener";
import { fetchAggregatorDetails } from "../../services/commands";

function aggregatorHost(url: string): string | null {
  try {
    return new URL(url).hostname.toLowerCase();
  } catch {
    return null;
  }
}

function isHttpUrl(url: string): boolean {
  try {
    return ["http:", "https:"].includes(new URL(url).protocol);
  } catch {
    return false;
  }
}

export function isAggregatorUrl(url: string): boolean {
  const host = aggregatorHost(url);
  return !!host && (
    host === "news.ycombinator.com" || host.endsWith(".ycombinator.com") ||
    host === "reddit.com" || host === "www.reddit.com" || host === "old.reddit.com" || host === "new.reddit.com" || host === "redd.it" || host.endsWith(".reddit.com") ||
    host === "lobste.rs" || host.endsWith(".lobste.rs")
  );
}

export function AggregatorDetails({ url }: { url: string }) {
  const supported = isAggregatorUrl(url);
  const { data, isLoading, isError } = useQuery({
    queryKey: ["aggregatorDetails", url],
    queryFn: () => fetchAggregatorDetails(url, 10),
    enabled: supported,
    staleTime: 5 * 60 * 1000,
  });

  if (!supported || (!isLoading && !data && !isError)) return null;
  if (isLoading) return <p className="text-text-muted text-sm">Loading discussion…</p>;
  if (isError || !data) {
    return (
      <div className="flex items-center gap-3 text-text-muted text-sm">
        <span>Discussion unavailable.</span>
        <button type="button" className="text-accent hover:underline" onClick={() => openUrl(url)}>
          Open discussion
        </button>
      </div>
    );
  }

  return (
    <section className="flex flex-col gap-4" aria-label="Discussion details">
      {data.selftext && (
        <div className="rounded-xl border border-white/10 bg-white/[0.03] p-4">
          <div className="text-text-muted text-xs font-semibold uppercase tracking-wider mb-2">Post</div>
          <p className="text-text-primary whitespace-pre-wrap">{data.selftext}</p>
        </div>
      )}
      {data.external_url && isHttpUrl(data.external_url) && (
        <button
          type="button"
          className="text-left rounded-xl border border-white/10 bg-white/[0.03] p-4 hover:bg-white/[0.06] transition-colors"
          onClick={() => openUrl(data.external_url!)}
          aria-label="Open linked story"
        >
          <div className="text-accent text-xs font-semibold uppercase tracking-wider mb-1">Linked story</div>
          <div className="text-text-primary text-sm break-all">{data.external_url}</div>
        </button>
      )}
      {data.comments.length > 0 && (
        <div className="flex flex-col gap-3">
          <div className="text-text-muted text-xs font-semibold uppercase tracking-wider">Top comments</div>
          {data.comments.map((comment) => (
            <article key={comment.id} className="rounded-xl border border-white/10 bg-white/[0.03] p-4">
              <div className="text-text-secondary text-xs mb-2">
                {comment.author}{comment.score != null ? ` · ${comment.score} points` : ""}
              </div>
              <p className="text-text-primary whitespace-pre-wrap">{comment.body}</p>
            </article>
          ))}
        </div>
      )}
    </section>
  );
}
