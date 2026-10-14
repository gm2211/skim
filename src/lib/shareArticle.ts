export type ShareOutcome = "shared" | "copied" | "cancelled" | "failed";

/**
 * Opens the platform share sheet for an article, or copies its link where the
 * webview has no Web Share support.
 */
export async function shareArticle(target: { url: string; title?: string | null }): Promise<ShareOutcome> {
  const data: ShareData = { url: target.url };
  if (target.title) data.title = target.title;

  if (typeof navigator !== "undefined" && typeof navigator.share === "function") {
    try {
      await navigator.share(data);
      return "shared";
    } catch (error) {
      // Closing the sheet rejects with AbortError; that is not a failure.
      if ((error as { name?: string } | null)?.name === "AbortError") return "cancelled";
    }
  }

  try {
    await navigator.clipboard.writeText(target.url);
    return "copied";
  } catch {
    return "failed";
  }
}
