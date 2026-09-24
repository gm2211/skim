import { act, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { invoke } from "@tauri-apps/api/core";
import type { ReactNode } from "react";
import { beforeEach, expect, it, vi } from "vitest";
import { useSummarizeArticle } from "./useAi";

vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));
beforeEach(() => vi.mocked(invoke).mockReset());

it("carries custom word count through mutation and Tauri command without losing global fallback", async () => {
  vi.mocked(invoke).mockResolvedValue({});
  const client = new QueryClient();
  const wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={client}>{children}</QueryClientProvider>;
  const { result } = renderHook(() => useSummarizeArticle(), { wrapper });
  await act(async () => {
    await result.current.mutateAsync({ articleId: "article", summaryLength: "custom", summaryCustomWordCount: 650 });
  });
  await waitFor(() => expect(invoke).toHaveBeenCalledWith("summarize_article", expect.objectContaining({
    articleId: "article", summaryLength: "custom", summaryCustomWordCount: 650,
  })));
  await act(async () => { await result.current.mutateAsync({ articleId: "other" }); });
  expect(invoke).toHaveBeenLastCalledWith("summarize_article", expect.objectContaining({
    articleId: "other", summaryCustomWordCount: null,
  }));
});
