import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { AggregatorPostView, buildCommentTree, type ReaderCopyState } from "./AggregatorPostView";
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

  it("shows direct replies and folds deeper ones behind a toggle", async () => {
    vi.mocked(fetchAggregatorDetails).mockResolvedValue({
      kind: "reddit",
      selftext: null,
      external_url: null,
      comments: [
        { id: "a", author: "ann", score: 40, body: "Top comment", depth: 0 },
        { id: "a1", author: "bo", score: 12, body: "Direct reply", depth: 1 },
        { id: "a11", author: "cy", score: 3, body: "Deep reply", depth: 2 },
        { id: "a111", author: "di", score: 1, body: "Deeper reply", depth: 3 },
        { id: "b", author: "ed", score: 9, body: "Second comment", depth: 0 },
      ],
    });
    renderView(redditLinkPost);

    expect(await screen.findByText("Direct reply")).toBeInTheDocument();
    expect(screen.queryByText("Deep reply")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "2 replies" }));
    expect(screen.getByText("Deep reply")).toBeInTheDocument();
    expect(screen.queryByText("Deeper reply")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "1 reply" }));
    expect(screen.getByText("Deeper reply")).toBeInTheDocument();
    expect(screen.getByText("Second comment")).toBeInTheDocument();
  });

  it("reveals more top-level threads a page at a time", async () => {
    vi.mocked(fetchAggregatorDetails).mockResolvedValue({
      kind: "hacker_news",
      selftext: null,
      external_url: null,
      comments: Array.from({ length: 12 }, (_, i) => ({ id: `c${i}`, author: `user${i}`, score: null, body: `Comment ${i}`, depth: 0 })),
    });
    renderView({ ...redditLinkPost, kind: "hacker_news", siteName: "Hacker News", discussionUrl: "https://news.ycombinator.com/item?id=1" });

    expect(await screen.findByText("Comment 7")).toBeInTheDocument();
    expect(screen.queryByText("Comment 8")).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: "Show more comments" }));
    expect(screen.getByText("Comment 11")).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Show more comments" })).not.toBeInTheDocument();
  });

  it("rebuilds reply trees from flattened comments", () => {
    const tree = buildCommentTree([
      { id: "a", author: "a", score: null, body: "", depth: 0 },
      { id: "a1", author: "a", score: null, body: "", depth: 1 },
      { id: "a2", author: "a", score: null, body: "", depth: 1 },
      { id: "b", author: "a", score: null, body: "", depth: 0 },
    ]);
    expect(tree.map((node) => [node.comment.id, node.replies.map((reply) => reply.comment.id)])).toEqual([["a", ["a1", "a2"]], ["b", []]]);
  });
});
