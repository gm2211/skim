import { beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { AddFeedDialog } from "./AddFeedDialog";
import { useUiStore } from "../../stores/uiStore";
import * as commands from "../../services/commands";
import { openUrl } from "@tauri-apps/plugin-opener";

vi.mock("../../hooks/useFeeds", () => ({
  useAddFeed: () => ({ mutateAsync: vi.fn(), isPending: false, isError: false }),
}));

vi.mock("../../services/commands", () => ({
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
