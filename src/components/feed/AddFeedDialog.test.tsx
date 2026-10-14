import { beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { AddFeedDialog } from "./AddFeedDialog";
import { useUiStore } from "../../stores/uiStore";
import * as commands from "../../services/commands";
import { openUrl } from "@tauri-apps/plugin-opener";
import type { DiscoveredFeed } from "../../services/types";

vi.mock("../../services/commands", () => ({
  addFeed: vi.fn(),
  discoverFeeds: vi.fn(),
  searchFeeds: vi.fn(),
  previewFeed: vi.fn(),
  feedCatalog: vi.fn(),
  feedlyOauthAvailable: vi.fn(),
  feedlyOauthLogin: vi.fn(),
  getFeedlyStatus: vi.fn(),
  importFeedlyStored: vi.fn(),
  importOpml: vi.fn(),
  previewOpml: vi.fn(),
  refreshAllFeeds: vi.fn(),
  triageArticles: vi.fn(),
}));

vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn() }));

const queryClient = () =>
  new QueryClient({ defaultOptions: { queries: { retry: false } } });

function renderDialog() {
  return render(
    <QueryClientProvider client={queryClient()}>
      <AddFeedDialog />
    </QueryClientProvider>,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
  useUiStore.setState({ showAddFeed: true, addFeedTab: "feedly", isPhone: false });
  vi.mocked(commands.feedlyOauthAvailable).mockResolvedValue(false);
  vi.mocked(commands.getFeedlyStatus).mockResolvedValue(null);
  vi.mocked(commands.previewOpml).mockResolvedValue([]);
  vi.mocked(openUrl).mockResolvedValue(undefined);
  vi.mocked(commands.feedCatalog).mockResolvedValue([
    { id: "tech", name: "Tech", feeds: [feed({ title: "The Verge", url: "https://www.theverge.com/rss/index.xml" })] },
    { id: "space", name: "Space", feeds: [feed({ title: "NASA", url: "https://www.nasa.gov/feed/" })] },
  ]);
});

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

describe("Discover", () => {
  beforeEach(() => useUiStore.setState({ addFeedTab: "url" }));

  it("browses popular feeds by topic and adds one in place", async () => {
    const user = userEvent.setup();
    vi.mocked(commands.addFeed).mockResolvedValue({} as never);
    renderDialog();

    expect(await screen.findByText("The Verge")).toBeInTheDocument();
    await user.click(screen.getByRole("tab", { name: "Space" }));
    await user.click(screen.getByRole("button", { name: "Add NASA" }));

    expect(commands.addFeed).toHaveBeenCalledWith("https://www.nasa.gov/feed/");
    expect(await screen.findByText("Added 1 feed")).toBeInTheDocument();
    expect(useUiStore.getState().showAddFeed).toBe(true);
  });

  it("finds a site's feeds from its address and shows their latest posts", async () => {
    const user = userEvent.setup();
    vi.mocked(commands.discoverFeeds).mockResolvedValue([
      feed({ title: "Example Blog", items: [{ title: "Hello world", url: "https://example.com/1", published_at: null }] }),
      feed({ title: "Comments", url: "https://example.com/comments.xml", already_subscribed: true }),
    ]);
    renderDialog();

    await user.type(screen.getByRole("textbox", { name: /paste a website/ }), "example.com");
    expect(await screen.findByText("Example Blog", {}, { timeout: 2000 })).toBeInTheDocument();
    expect(commands.discoverFeeds).toHaveBeenCalledWith("example.com");
    expect(commands.searchFeeds).not.toHaveBeenCalled();
    expect(screen.getByText("Following")).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: /^Example Blog/ }));
    expect(screen.getByText("Hello world")).toBeInTheDocument();
    expect(commands.previewFeed).not.toHaveBeenCalled();
  });

  it("searches by topic words and previews a result on demand", async () => {
    const user = userEvent.setup();
    vi.mocked(commands.searchFeeds).mockResolvedValue([feed({ title: "Rust Blog", subscribers: 12_300 })]);
    vi.mocked(commands.previewFeed).mockResolvedValue(
      feed({ title: "Rust Blog", items: [{ title: "Rust 2.0", url: null, published_at: null }] }),
    );
    renderDialog();

    await user.type(screen.getByRole("textbox", { name: /paste a website/ }), "rust lang");
    expect(await screen.findByText("Rust Blog", {}, { timeout: 2000 })).toBeInTheDocument();
    expect(commands.searchFeeds).toHaveBeenCalledWith("rust lang");
    expect(screen.getByText(/12K followers/)).toBeInTheDocument();

    await user.click(screen.getByRole("button", { name: /^Rust Blog/ }));
    expect(await screen.findByText("Rust 2.0")).toBeInTheDocument();
  });

  it("shows why discovery failed", async () => {
    const user = userEvent.setup();
    vi.mocked(commands.discoverFeeds).mockRejectedValue("No feeds found on that page.");
    renderDialog();

    await user.type(screen.getByRole("textbox", { name: /paste a website/ }), "nofeeds.example");
    expect(await screen.findByText("No feeds found on that page.", {}, { timeout: 2000 })).toBeInTheDocument();
  });
});

describe("closing the dialog", () => {
  it("closes on Escape, so the keyboard is not a dead end", () => {
    renderDialog();
    expect(screen.getByRole("dialog")).toBeInTheDocument();
    fireEvent.keyDown(document.body, { key: "Escape" });
    expect(useUiStore.getState().showAddFeed).toBe(false);
  });
});

describe("AddFeedDialog Feedly export", () => {
  it("opens and copies the authenticated Feedly OPML export URL", async () => {
    const user = userEvent.setup();
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText } });
    renderDialog();

    await user.click(screen.getByRole("button", { name: "Open Feedly export" }));
    await user.click(screen.getByRole("button", { name: "Copy export link" }));

    const url = "https://feedly.com/i/back?nextUri=%2Fopml";
    expect(openUrl).toHaveBeenCalledWith(url);
    expect(writeText).toHaveBeenCalledWith(url);
    expect(screen.getByRole("status")).toHaveTextContent("Export link copied");
    expect(screen.getByRole("button", { name: "Copy export link" })).toBeEnabled();
  });

  it("shows an opener error when Feedly cannot be opened", async () => {
    vi.mocked(openUrl).mockRejectedValueOnce(new Error("open failed"));
    renderDialog();

    await userEvent.setup().click(screen.getByRole("button", { name: "Open Feedly export" }));

    expect(await screen.findByText("open failed")).toBeInTheDocument();
  });

  it("still previews a selected OPML file", async () => {
    vi.mocked(commands.previewOpml).mockResolvedValue([
      { title: "Example feed", url: "https://example.com/feed.xml", category: null, already_exists: false },
    ]);
    renderDialog();

    const file = new File(["<opml />"], "subscriptions.opml", { type: "application/xml" });
    Object.defineProperty(file, "text", { value: async () => "<opml />" });
    const input = document.querySelector('input[type="file"]');
    expect(input).not.toBeNull();
    fireEvent.change(input!, { target: { files: [file] } });

    expect(await screen.findByText("Example feed")).toBeInTheDocument();
    expect(commands.previewOpml).toHaveBeenCalledWith("<opml />");
  });
});
