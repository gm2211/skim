import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { CommandPalette } from "./CommandPalette";
import { useUiStore } from "../../stores/uiStore";
import { APP_COMMAND_EVENT } from "../../lib/appCommands";

const refresh = vi.fn();
const toggleStar = vi.fn();
vi.mock("../../hooks/useFeeds", () => ({
  useFeeds: () => ({ data: [{ id: "f1", title: "Hacker News", unread_count: 3 }] }),
  useRefreshAllFeeds: () => ({ mutate: refresh }),
}));
vi.mock("../../hooks/useFolders", () => ({ useFolders: () => ({ data: [] }) }));
vi.mock("../../hooks/useArticles", () => ({
  useArticle: (id: string | null) => ({
    data: id ? { id, title: "Open story", url: "https://example.com", is_starred: false, is_read: true } : undefined,
  }),
  useToggleStar: () => ({ mutate: toggleStar }),
  useToggleRead: () => ({ mutate: vi.fn() }),
}));
vi.mock("../../hooks/useLearning", () => ({
  useArticleInteraction: () => ({ data: undefined }),
  useSetPriorityOverride: () => ({ mutate: vi.fn() }),
}));
vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn() }));
vi.mock("../../services/commands", () => ({
  getArticles: vi.fn().mockResolvedValue([{ id: "a9", feed_id: "f1", title: "Rust 2027 roadmap" }]),
}));

const INITIAL_STATE = useUiStore.getState();

function renderPalette() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <CommandPalette />
    </QueryClientProvider>,
  );
}

beforeEach(() => {
  useUiStore.setState({ ...INITIAL_STATE, showCommandPalette: true }, true);
  refresh.mockClear();
  toggleStar.mockClear();
});

describe("CommandPalette", () => {
  it("runs the top match on Enter and closes", async () => {
    const user = userEvent.setup();
    renderPalette();
    await user.type(screen.getByRole("combobox"), "catch");
    await user.keyboard("{Enter}");
    await waitFor(() => expect(useUiStore.getState().showCatchup).toBe(true));
    expect(useUiStore.getState().showCommandPalette).toBe(false);
  });

  it("shows shortcuts and opens a settings section", async () => {
    const user = userEvent.setup();
    renderPalette();
    expect(screen.getByRole("option", { name: /Open Settings/ })).toHaveTextContent(",");
    await user.type(screen.getByRole("combobox"), "appearance");
    await user.keyboard("{Enter}");
    await waitFor(() => expect(useUiStore.getState().showSettings).toBe(true));
    expect(useUiStore.getState().settingsTab).toBe("appearance");
  });

  it("jumps to a feed by name", async () => {
    const user = userEvent.setup();
    renderPalette();
    await user.type(screen.getByRole("combobox"), "hacker");
    await user.keyboard("{Enter}");
    await waitFor(() => expect(useUiStore.getState().sidebarView).toEqual({ type: "feed", feedId: "f1" }));
  });

  it("opens an article found by title", async () => {
    const user = userEvent.setup();
    renderPalette();
    await user.type(screen.getByRole("combobox"), "roadmap");
    await user.click(await screen.findByRole("option", { name: /Rust 2027 roadmap/ }));
    await waitFor(() => expect(useUiStore.getState().selectedArticleId).toBe("a9"));
  });

  it("offers article actions only while an article is open", async () => {
    const user = userEvent.setup();
    const { unmount } = renderPalette();
    expect(screen.queryByRole("option", { name: /Star article/ })).not.toBeInTheDocument();
    unmount();

    useUiStore.setState({ selectedArticleId: "a1" });
    const events: string[] = [];
    window.addEventListener(APP_COMMAND_EVENT, (e) => events.push((e as CustomEvent).detail));
    renderPalette();
    await user.click(screen.getByRole("option", { name: /Star article/ }));
    await waitFor(() => expect(toggleStar).toHaveBeenCalledWith("a1"));

    useUiStore.setState({ showCommandPalette: true });
    await user.type(screen.getByRole("combobox"), "summarize");
    await user.keyboard("{Enter}");
    await waitFor(() => expect(events).toContain("summarize"));
  });

  it("moves the selection with the arrow keys", async () => {
    const user = userEvent.setup();
    renderPalette();
    const options = screen.getAllByRole("option");
    expect(options[0]).toHaveAttribute("aria-selected", "true");
    await user.keyboard("{ArrowDown}");
    expect(screen.getAllByRole("option")[1]).toHaveAttribute("aria-selected", "true");
    await user.keyboard("{ArrowUp}{ArrowUp}");
    const all = screen.getAllByRole("option");
    expect(all[all.length - 1]).toHaveAttribute("aria-selected", "true");
  });
});
