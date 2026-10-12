import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { CommandPalette } from "./CommandPalette";
import { useUiStore } from "../../stores/uiStore";
import { APP_COMMAND_EVENT } from "../../lib/appCommands";
import { useAgentChatStore } from "../../stores/agentChatStore";

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
const askAgent = vi.fn();
vi.mock("../../services/commands", () => ({
  getArticles: vi.fn().mockResolvedValue([{ id: "a9", feed_id: "f1", title: "Rust 2027 roadmap" }]),
  askAgent: (...args: unknown[]) => askAgent(...args),
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
  askAgent.mockReset();
  useAgentChatStore.setState({ seed: null });
});

const ANSWER = {
  content: "Two matches:\n- [1] Rust async runtimes compared\n- [2] Tokio 2.0 released",
  provider: "anthropic",
  model: "m",
  sources: [
    { id: "r1", title: "Rust async runtimes compared", feed_title: "Lobsters", url: null, published_at: null, source_type: "article" },
    { id: "r2", title: "Tokio 2.0 released", feed_title: "Hacker News", url: null, published_at: null, source_type: "article" },
    { id: "r3", title: "Unrelated", feed_title: "Hacker News", url: null, published_at: null, source_type: "article" },
  ],
  article_ids: ["r1", "r2", "r3"],
  actions: [],
  steps: [{ tool: "search_articles", label: "Searched for “rust async”" }],
};

describe("CommandPalette", () => {
  it("runs the top match on Enter and closes", async () => {
    const user = userEvent.setup();
    renderPalette();
    await user.type(screen.getByRole("combobox"), "catch");
    await user.keyboard("{Enter}");
    // "Catch me up" opens Today with the catch-up showing.
    await waitFor(() => expect(useUiStore.getState().sidebarView).toEqual({ type: "today" }));
    expect(useUiStore.getState().todayMode).toBe("catchup");
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

  it("offers Back and Forward through article history with their shortcuts", async () => {
    const user = userEvent.setup();
    useUiStore.setState({ selectedArticleId: "a2", articleHistory: ["a1", "a2", "a3"], articleHistoryIndex: 1 });
    renderPalette();
    expect(screen.getByRole("option", { name: /Forward to next article/ })).toHaveTextContent("]");
    await user.click(screen.getByRole("option", { name: /Back to previous article/ }));
    await waitFor(() => expect(useUiStore.getState().selectedArticleId).toBe("a1"));
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

  it("answers a question it has no command for, with links to the articles it found", async () => {
    const user = userEvent.setup();
    askAgent.mockResolvedValue(ANSWER);
    useUiStore.setState({ sidebarView: { type: "today" } });
    renderPalette();
    await user.type(screen.getByRole("combobox"), "where's an article about rust async");
    expect(screen.getAllByRole("option")[0]).toHaveTextContent("Ask Skim: where's an article about rust async");
    await user.keyboard("{Enter}");

    expect(await screen.findByText(/Two matches/)).toBeInTheDocument();
    expect(screen.getByText("Searched for “rust async”")).toBeInTheDocument();
    expect(useUiStore.getState().showCommandPalette).toBe(true);
    const [messages, context] = askAgent.mock.calls[0];
    expect(messages).toEqual([{ role: "user", content: "where's an article about rust async" }]);
    expect(context).toMatchObject({ view: "today" });

    // Only the cited articles are offered, and Enter opens the first.
    const options = screen.getAllByRole("option");
    expect(options.map((o) => o.textContent)).toEqual([
      expect.stringContaining("Rust async runtimes compared"),
      expect.stringContaining("Tokio 2.0 released"),
    ]);
    await user.keyboard("{Enter}");
    await waitFor(() => expect(useUiStore.getState().selectedArticleId).toBe("r1"));
    expect(useUiStore.getState().showCommandPalette).toBe(false);
  });

  it("asks follow-ups with the conversation and stable citation numbers", async () => {
    const user = userEvent.setup();
    askAgent.mockResolvedValue(ANSWER);
    renderPalette();
    await user.type(screen.getByRole("combobox"), "where's the rust piece?{Enter}");
    await screen.findByText(/Two matches/);
    askAgent.mockResolvedValue({ ...ANSWER, content: "It compares Tokio and smol [1]." });
    await user.type(screen.getByRole("combobox"), "what does it say?{Enter}");
    await screen.findByText(/compares Tokio and smol/);
    const [messages, , priorIds] = askAgent.mock.calls[1];
    expect(messages.map((m: { role: string }) => m.role)).toEqual(["user", "assistant", "user"]);
    expect(priorIds).toEqual(["r1", "r2", "r3"]);
  });

  it("continues the conversation in the full chat", async () => {
    const user = userEvent.setup();
    askAgent.mockResolvedValue(ANSWER);
    const events: string[] = [];
    window.addEventListener(APP_COMMAND_EVENT, (e) => events.push((e as CustomEvent).detail));
    useUiStore.setState({ selectedArticleId: "a1" });
    renderPalette();
    await user.type(screen.getByRole("combobox"), "where's the rust piece?{Enter}");
    await screen.findByText(/Two matches/);
    await user.click(screen.getByRole("button", { name: /Open full chat/ }));
    await waitFor(() => expect(events).toContain("ask-skim"));
    const seed = useAgentChatStore.getState().seed;
    expect(seed?.context).toMatchObject({ article_id: "a1" });
    expect(seed?.messages?.map((m) => m.role)).toEqual(["user", "assistant"]);
    expect(useUiStore.getState().showCommandPalette).toBe(false);
  });

  it("opens the article when the agent asks to", async () => {
    const user = userEvent.setup();
    askAgent.mockResolvedValue({ ...ANSWER, content: "Opened it.", actions: [{ type: "open_article", article_id: "r2" }] });
    renderPalette();
    await user.type(screen.getByRole("combobox"), "open the tokio article{Enter}");
    await waitFor(() => expect(useUiStore.getState().selectedArticleId).toBe("r2"));
    expect(useUiStore.getState().showCommandPalette).toBe(false);
  });

  it("goes back to commands, keeping the question, when asking fails", async () => {
    const user = userEvent.setup();
    askAgent.mockRejectedValue("Request failed: 500");
    renderPalette();
    await user.type(screen.getByRole("combobox"), "what is new in rust?{Enter}");
    expect(await screen.findByRole("alert")).toHaveTextContent("Request failed: 500");
    expect(screen.getByRole("combobox")).toHaveValue("what is new in rust?");
    expect(screen.getAllByRole("option")[0]).toHaveTextContent("Ask Skim");
  });
});
