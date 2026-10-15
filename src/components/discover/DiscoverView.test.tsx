import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { DiscoverView } from "./DiscoverView";
import { useUiStore } from "../../stores/uiStore";
import * as commands from "../../services/commands";
import { openUrl } from "@tauri-apps/plugin-opener";
import type { DiscoveredFeed, FeedPreviewItem } from "../../services/types";

vi.mock("../../services/commands", () => ({
  addFeed: vi.fn(),
  discoverFeeds: vi.fn(),
  searchFeeds: vi.fn(),
  previewFeed: vi.fn(),
  feedCatalog: vi.fn(),
}));
vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn() }));

function feed(over: Partial<DiscoveredFeed> = {}): DiscoveredFeed {
  return {
    url: "https://example.com/feed.xml",
    title: "Example",
    site_url: "https://example.com",
    description: null,
    icon_url: null,
    subscribers: null,
    items: [],
    already_subscribed: false,
    ...over,
  };
}

function item(title: string, over: Partial<FeedPreviewItem> = {}): FeedPreviewItem {
  return { title, url: `https://example.com/${encodeURIComponent(title)}`, published_at: null, author: null, image_url: null, ...over };
}

const verge = feed({ title: "The Verge", url: "https://www.theverge.com/rss/index.xml", site_url: "https://www.theverge.com" });
const nasa = feed({ title: "NASA", url: "https://www.nasa.gov/feed/", site_url: "https://www.nasa.gov" });

function renderView() {
  return render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <DiscoverView />
    </QueryClientProvider>,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
  useUiStore.setState({ isPhone: false, sidebarCollapsed: false });
  vi.mocked(commands.feedCatalog).mockResolvedValue([
    { id: "tech", name: "Tech", feeds: [verge] },
    { id: "space", name: "Space", feeds: [nasa] },
  ]);
  vi.mocked(commands.searchFeeds).mockResolvedValue([]);
  vi.mocked(commands.previewFeed).mockResolvedValue(feed({ items: [] }));
  vi.mocked(openUrl).mockResolvedValue(undefined);
});

describe("Discover", () => {
  it("opens a topic, then a feed's page, and follows it", async () => {
    const user = userEvent.setup();
    vi.mocked(commands.addFeed).mockResolvedValue({} as never);
    vi.mocked(commands.previewFeed).mockResolvedValue(
      feed({ ...nasa, items: [item("Artemis update", { author: "NASA", image_url: "https://img/1.jpg" })] }),
    );
    renderView();

    await user.click((await screen.findAllByRole("button", { name: /^Space/ }))[0]);
    expect(screen.getByRole("heading", { name: "Space" })).toBeInTheDocument();
    expect(commands.searchFeeds).toHaveBeenCalledWith("Space");

    await user.click(screen.getByRole("button", { name: /^NASA,/ }));
    expect(await screen.findByText("Artemis update")).toBeInTheDocument();
    expect(screen.getByText(/by NASA/)).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Follow NASA" }));
    expect(commands.addFeed).toHaveBeenCalledWith("https://www.nasa.gov/feed/");
    expect(await screen.findByLabelText("Following NASA")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: /Artemis update/ }));
    expect(openUrl).toHaveBeenCalledWith("https://example.com/Artemis%20update");

    await user.click(screen.getByRole("button", { name: "Space" }));
    expect(screen.getByRole("heading", { name: "Space" })).toBeInTheDocument();
  });

  it("finds a site's feeds from its address", async () => {
    const user = userEvent.setup();
    vi.mocked(commands.discoverFeeds).mockResolvedValue([
      feed({ title: "Example Blog" }),
      feed({ title: "Comments", url: "https://example.com/comments.xml", already_subscribed: true }),
    ]);
    renderView();

    await user.type(screen.getByRole("textbox", { name: /paste a website/ }), "example.com");
    expect(await screen.findByText("Example Blog", {}, { timeout: 2000 })).toBeInTheDocument();
    expect(commands.discoverFeeds).toHaveBeenCalledWith("example.com");
    expect(screen.getByText("2 feeds found")).toBeInTheDocument();
    expect(screen.getByLabelText("Following Comments")).toBeInTheDocument();
  });

  it("searches by words and shows follower counts", async () => {
    const user = userEvent.setup();
    vi.mocked(commands.searchFeeds).mockResolvedValue([feed({ title: "Rust Blog", subscribers: 12_300 })]);
    renderView();

    await user.type(screen.getByRole("textbox", { name: /paste a website/ }), "rust lang");
    expect(await screen.findByText("Rust Blog", {}, { timeout: 2000 })).toBeInTheDocument();
    expect(commands.searchFeeds).toHaveBeenCalledWith("rust lang");
    expect(screen.getByText(/12K followers/)).toBeInTheDocument();
  });

  it("shows why discovery failed", async () => {
    const user = userEvent.setup();
    vi.mocked(commands.discoverFeeds).mockRejectedValue("No feeds found on that page.");
    renderView();

    await user.type(screen.getByRole("textbox", { name: /paste a website/ }), "nofeeds.example");
    expect(await screen.findByText("No feeds found on that page.", {}, { timeout: 2000 })).toBeInTheDocument();
  });
});

describe("opening Discover", () => {
  it("routes Add feed to the Discover view and keeps Import as a dialog", () => {
    useUiStore.getState().setShowAddFeed(true);
    expect(useUiStore.getState().sidebarView).toEqual({ type: "discover" });
    expect(useUiStore.getState().showAddFeed).toBe(false);
    useUiStore.getState().setShowAddFeed(true, "feedly");
    expect(useUiStore.getState().showAddFeed).toBe(true);
  });
});
