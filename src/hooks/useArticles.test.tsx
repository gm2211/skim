import { act, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider, useQuery } from "@tanstack/react-query";
import { describe, expect, it, vi } from "vitest";
import type { ReactNode } from "react";
import { useArticle, useMarkAllRead, useMarkRead } from "./useArticles";
import * as commands from "../services/commands";

vi.mock("../services/commands", () => ({
  getArticle: vi.fn(),
  markArticlesRead: vi.fn(),
  markAllRead: vi.fn(),
}));

describe("read mutations update the open reader", () => {
  it.each(["selected", "all"] as const)("refreshes detail after marking %s read", async (scope) => {
    let isRead = false;
    vi.mocked(commands.getArticle).mockImplementation(async () => ({ id: "article", feed_id: "feed", title: "Story", url: null, author: null, content_html: null, content_text: null, published_at: null, fetched_at: 0, is_read: isRead, is_starred: false, feedly_entry_id: null, comments_url: null, feed_title: "Feed", feed_icon_url: null }));
    vi.mocked(commands.markArticlesRead).mockImplementation(async () => { isRead = true; });
    vi.mocked(commands.markAllRead).mockImplementation(async () => { isRead = true; });
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={client}>{children}</QueryClientProvider>;
    const { result, unmount } = renderHook(() => ({ article: useArticle("article"), recent: useQuery({ queryKey: ["recent", "recency"], queryFn: async () => ({ is_read: isRead }) }), selected: useMarkRead(), all: useMarkAllRead() }), { wrapper });
    await waitFor(() => expect(result.current.article.data?.is_read).toBe(false));
    await act(async () => {
      if (scope === "selected") await result.current.selected.mutateAsync(["article"]);
      else await result.current.all.mutateAsync(undefined);
    });
    await waitFor(() => {
      expect(result.current.article.data?.is_read).toBe(true);
      expect(result.current.recent.data?.is_read).toBe(true);
    });
    unmount();
    client.clear();
  });
});
