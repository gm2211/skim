import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { AggregatorPostView, type ReaderCopyState } from "./AggregatorPostView";
import { fetchAggregatorDetails } from "../../services/commands";
import type { AggregatorPost } from "../../lib/aggregatorPost";

vi.mock("../../services/commands", () => ({ fetchAggregatorDetails: vi.fn() }));
vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn(() => Promise.resolve()) }));

const redditLinkPost: AggregatorPost = {
  kind: "reddit",
  siteName: "Reddit",
  community: "r/technology",
  submitter: "plain_handle",
  linkUrl: "https://www.bbc.com/news/articles/c1234",
  mediaUrl: null,
  discussionUrl: "https://www.reddit.com/r/technology/comments/1abc/post/",
  thumbnailUrl: "https://external-preview.redd.it/thumb.jpg",
  selfHtml: null,
  points: null,
  commentCount: null,
};

function renderView(post: AggregatorPost, readerState: ReaderCopyState = "unavailable") {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={queryClient}>
      <AggregatorPostView post={post} readerState={readerState}>
        <p>Extracted story body</p>
      </AggregatorPostView>
    </QueryClientProvider>,
  );
}

beforeEach(() => {
  vi.mocked(fetchAggregatorDetails).mockReset();
});

describe("AggregatorPostView", () => {
  it("makes the linked story the centerpiece when there is no reader copy", async () => {
    vi.mocked(fetchAggregatorDetails).mockImplementation(async () => { throw new Error("403"); });
    renderView(redditLinkPost);

    expect(screen.getByRole("region", { name: "Linked story" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Read on bbc\.com/ })).toBeInTheDocument();
    expect(screen.queryByText("Extracted story body")).not.toBeInTheDocument();
    expect(screen.queryByText(/submitted by|\[link\]|\[comments\]/)).not.toBeInTheDocument();
    // A failed discussion fetch reads as a way out, not an error.
    expect(await screen.findByText("Read the conversation on Reddit")).toBeInTheDocument();
    expect(screen.queryByText(/unavailable/i)).not.toBeInTheDocument();
  });

  it("shrinks the link to a source row once the story is extracted", async () => {
    vi.mocked(fetchAggregatorDetails).mockResolvedValue({
      kind: "reddit",
      selftext: null,
      external_url: redditLinkPost.linkUrl,
      points: 1520,
      comment_count: 342,
      comments: [{ id: "c1", author: "reader", score: 12, body: "Great link", depth: 0 }],
    });
    renderView(redditLinkPost, "ready");

    expect(screen.getByText("Extracted story body")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Open the original on bbc.com" })).toBeInTheDocument();
    expect(screen.queryByRole("region", { name: "Linked story" })).not.toBeInTheDocument();
    expect(await screen.findByText("Great link")).toBeInTheDocument();
    expect(screen.getByText("1.5k points · 342 comments")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /See all 342 comments on Reddit/ })).toBeInTheDocument();
  });

  it("shows a self post's own text and no link card", async () => {
    vi.mocked(fetchAggregatorDetails).mockResolvedValue(null);
    renderView({ ...redditLinkPost, linkUrl: null, thumbnailUrl: null, selfHtml: "<p>Has anyone tried this?</p>" });

    expect(screen.getByText("Has anyone tried this?")).toBeInTheDocument();
    expect(screen.queryByRole("region", { name: "Linked story" })).not.toBeInTheDocument();
  });

  it("falls back to the discussion's linked story when the feed had none", async () => {
    vi.mocked(fetchAggregatorDetails).mockResolvedValue({
      kind: "hacker_news",
      selftext: null,
      external_url: "https://blog.example.com/post",
      comments: [],
    });
    renderView({ ...redditLinkPost, kind: "hacker_news", siteName: "Hacker News", linkUrl: null, discussionUrl: "https://news.ycombinator.com/item?id=1" });

    expect(await screen.findByRole("button", { name: /Read on blog\.example\.com/ })).toBeInTheDocument();
    expect(screen.getByText("No comments yet")).toBeInTheDocument();
  });
});
