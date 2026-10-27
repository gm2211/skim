import { beforeEach, describe, expect, it, vi } from "vitest";
import { act, render, screen } from "@testing-library/react";
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
  subscribedFeed: vi.fn(),
  countStarredInFeed: vi.fn(),
  removeFeed: vi.fn(),
  listNewspapers: vi.fn(),
  signInNewspaper: vi.fn(),
  signOutNewspaper: vi.fn(),
}));
vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn() }));
const events = vi.hoisted(() => ({ handlers: new Map<string, () => void>() }));
vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn((name: string, handler: () => void) => {
    events.handlers.set(name, handler);
    return Promise.resolve(() => {});
  }),
}));

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
  vi.mocked(commands.listNewspapers).mockResolvedValue([]);
  vi.mocked(commands.previewFeed).mockResolvedValue(feed({ items: [] }));
  vi.mocked(openUrl).mockResolvedValue(undefined);
});

describe("Discover", () => {
  it("follows every section of a newspaper and signs in to it", async () => {
    const user = userEvent.setup();
    const nyt = (signedIn: boolean) => ({
      id: "nyt",
      name: "The New York Times",
      site: "https://www.nytimes.com",
      icon_url: null,
      free: false,
      can_sign_in: true,
      signed_in: signedIn,
      sections: [
        feed({ title: "Top Stories", url: "https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml", site_url: "https://www.nytimes.com" }),
        feed({ title: "World", url: "https://rss.nytimes.com/services/xml/rss/nyt/World.xml", site_url: "https://www.nytimes.com", already_subscribed: true }),
      ],
         note: null,
    });
    vi.mocked(commands.listNewspapers).mockResolvedValue([nyt(false)]);
    vi.mocked(commands.addFeed).mockResolvedValue({} as never);
    vi.mocked(commands.signInNewspaper).mockResolvedValue(undefined);
    vi.mocked(commands.signOutNewspaper).mockResolvedValue(undefined);
    renderView();

    expect(await screen.findByText("Subscription · 2 sections")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: /The New York Times/ }));
    expect(screen.getByRole("heading", { name: "The New York Times" })).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Follow all sections" }));
    expect(commands.addFeed).toHaveBeenCalledTimes(1);
    expect(commands.addFeed).toHaveBeenCalledWith("https://rss.nytimes.com/services/xml/rss/nyt/HomePage.xml");

    await user.click(screen.getByRole("button", { name: "Sign in" }));
    expect(commands.signInNewspaper).toHaveBeenCalledWith("nyt");

    // Closing the sign-in window tells Discover to reload sign-in state.
    vi.mocked(commands.listNewspapers).mockResolvedValue([nyt(true)]);
    act(() => events.handlers.get("newspaper-auth-changed")?.());
    expect(await screen.findByText("Signed in")).toBeInTheDocument();
    await user.click(await screen.findByRole("button", { name: "Sign out" }));
    expect(commands.signOutNewspaper).toHaveBeenCalledWith("nyt");
  });

  it("explains a newspaper with no RSS feeds instead of offering to follow it", async () => {
    const user = userEvent.setup();
    const note = "The Post's servers turn away RSS readers, so Skim can't follow its sections.";
    vi.mocked(commands.listNewspapers).mockResolvedValue([{
      id: "wapo",
      name: "The Washington Post",
      site: "https://www.washingtonpost.com",
      icon_url: null,
      free: false,
      can_sign_in: true,
      signed_in: false,
      sections: [],
      note,
    }]);
    renderView();

    expect(await screen.findByText("Subscription · No RSS feeds")).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: /The Washington Post/ }));
    expect(screen.getByText(note)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Follow all sections" })).not.toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Sign in" })).toBeInTheDocument();
  });

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
    expect(await screen.findByRole("button", { name: "Unfollow NASA" })).toBeInTheDocument();

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
    expect(screen.getByRole("button", { name: "Unfollow Comments" })).toBeInTheDocument();
  });

  it("unfollows from the Following button after asking", async () => {
    const user = userEvent.setup();
    vi.mocked(commands.discoverFeeds).mockResolvedValue([
      feed({ title: "Comments", url: "https://example.com/comments.xml", already_subscribed: true }),
    ]);
    vi.mocked(commands.subscribedFeed).mockResolvedValue({ id: "feed-7", title: "Comments" } as never);
    vi.mocked(commands.countStarredInFeed).mockResolvedValue(2);
    vi.mocked(commands.removeFeed).mockResolvedValue(undefined);
    renderView();

    await user.type(screen.getByRole("textbox", { name: /paste a website/ }), "example.com");
    await user.click(await screen.findByRole("button", { name: "Unfollow Comments" }, { timeout: 2000 }));
    expect(commands.subscribedFeed).toHaveBeenCalledWith("https://example.com/comments.xml");
    expect(await screen.findByRole("dialog", { name: 'Unfollow Comments?' })).toBeInTheDocument();
    expect(screen.getByText("2 starred articles")).toBeInTheDocument();

    // Cancel keeps it.
    await user.click(screen.getByRole("button", { name: "Cancel" }));
    expect(commands.removeFeed).not.toHaveBeenCalled();
    expect(screen.getByRole("button", { name: "Unfollow Comments" })).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: "Unfollow Comments" }));
    await user.click(await screen.findByRole("button", { name: "Unfollow" }));
    expect(commands.removeFeed).toHaveBeenCalledWith("feed-7");
    expect(await screen.findByRole("button", { name: "Follow Comments" })).toBeInTheDocument();
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
