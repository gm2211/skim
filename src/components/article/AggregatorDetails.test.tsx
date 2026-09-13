import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { AggregatorDetails, isAggregatorUrl } from "./AggregatorDetails";
import { fetchAggregatorDetails } from "../../services/commands";

vi.mock("../../services/commands", () => ({ fetchAggregatorDetails: vi.fn() }));
vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn() }));

function renderDetails(url: string) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={queryClient}>
      <AggregatorDetails url={url} />
    </QueryClientProvider>,
  );
}

beforeEach(() => vi.mocked(fetchAggregatorDetails).mockReset());

describe("AggregatorDetails", () => {
  it("recognizes supported aggregator URLs only", () => {
    expect(isAggregatorUrl("https://news.ycombinator.com/item?id=123")).toBe(true);
    expect(isAggregatorUrl("https://www.reddit.com/r/rust/comments/abc/post")).toBe(true);
    expect(isAggregatorUrl("https://lobste.rs/s/abc/post")).toBe(true);
    expect(isAggregatorUrl("https://example.com/post")).toBe(false);
  });

  it("renders self-post, linked story, and top comments", async () => {
    vi.mocked(fetchAggregatorDetails).mockResolvedValue({
      kind: "reddit",
      selftext: "A self post.",
      external_url: "https://example.com/story",
      comments: [{ id: "c1", author: "reader", score: 12, body: "Great link", depth: 0 }],
    });
    renderDetails("https://www.reddit.com/r/test/comments/abc/post");

    expect(await screen.findByText("A self post.")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Open linked story" })).toBeInTheDocument();
    expect(screen.getByText("Great link")).toBeInTheDocument();
    expect(fetchAggregatorDetails).toHaveBeenCalledWith("https://www.reddit.com/r/test/comments/abc/post", 10);
  });

  it("does not query ordinary article URLs", async () => {
    renderDetails("https://example.com/story");
    await waitFor(() => expect(fetchAggregatorDetails).not.toHaveBeenCalled());
    expect(screen.queryByRole("region", { name: "Discussion details" })).not.toBeInTheDocument();
  });
});
