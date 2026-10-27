import { beforeEach, describe, expect, it, vi } from "vitest";
import { act, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { AskSkimDialog } from "./AskSkimDialog";
import { selectChatText } from "../../test/selectChatText";
import { useUiStore } from "../../stores/uiStore";
import { askAgent, chatWithArticles, researchTopic } from "../../services/commands";
import { useAgentChatStore } from "../../stores/agentChatStore";

let settings = { ai: { provider: "none", chat_provider: "same" } };
vi.mock("../../hooks/useSettings", () => ({ useSettings: () => ({ data: settings }) }));
vi.mock("../../services/commands", () => ({ chatWithArticles: vi.fn(), askAgent: vi.fn(), researchTopic: vi.fn(), RESEARCH_PROGRESS_EVENT: "research-progress" }));
const progressListeners: Array<(event: { payload: { request_id: string; label: string } }) => void> = [];
vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(async (_name: string, handler: (event: { payload: { request_id: string; label: string } }) => void) => {
    progressListeners.push(handler);
    return () => { progressListeners.splice(progressListeners.indexOf(handler), 1); };
  }),
}));
vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn() }));
vi.mock("../common/ModelPicker", () => ({
  ModelPicker: (p: { surface: string; disabled?: boolean }) => (
    <div data-testid="model-picker" data-surface={p.surface} data-disabled={String(!!p.disabled)} />
  ),
}));

beforeEach(() => {
  vi.clearAllMocks();
  settings = { ai: { provider: "none", chat_provider: "same" } };
  useUiStore.setState({ isPhone: false, showSettings: false });
  HTMLElement.prototype.scrollTo = vi.fn();
  window.scrollTo = vi.fn();
  vi.mocked(chatWithArticles).mockResolvedValue({ content: "Answer", sources: [], provider: "openai", model: "test-model", article_ids: [] });
});

describe("AskSkimDialog setup recovery", () => {
  it("shows cited sources as cards numbered like their chips and keeps uncited candidates collapsed", async () => {
    settings = { ai: { provider: "openai", chat_provider: "same" } };
    const onOpenArticle = vi.fn();
    vi.mocked(chatWithArticles).mockResolvedValueOnce({
      content: "Court evidence [2]",
      sources: ["Wallpaper", "Court ruling", "Phone colors"].map((title, index) => ({
        id: `source-${index}`, title, feed_title: "Desk", url: null, published_at: null, source_type: "article" as const,
      })),
      provider: "openai", model: "test", article_ids: ["source-0", "source-1", "source-2"],
    });
    const user = userEvent.setup();
    render(<AskSkimDialog onClose={vi.fn()} onOpenArticle={onOpenArticle} />);
    await user.type(screen.getByRole("textbox"), "Find court ruling");
    await user.click(screen.getByRole("button", { name: "Send" }));
    expect(await screen.findByRole("button", { name: /^1.*Court ruling/ })).toBeVisible();
    expect(screen.getByRole("link", { name: "1" })).toHaveAttribute("title", "Court ruling");
    expect(screen.getByRole("button", { name: /Wallpaper/ })).not.toBeVisible();
    await user.click(screen.getByText("Also searched (2)"));
    await user.click(screen.getByRole("button", { name: /Phone colors/ }));
    expect(onOpenArticle).toHaveBeenCalledWith("source-2");
  });

  it("queues a question asked mid-answer and sends it when the answer lands", async () => {
    settings = { ai: { provider: "openai", chat_provider: "same" } };
    let finish!: (value: Awaited<ReturnType<typeof chatWithArticles>>) => void;
    vi.mocked(chatWithArticles)
      .mockImplementationOnce(() => new Promise((resolve) => { finish = resolve; }))
      .mockResolvedValueOnce({ content: "Second answer", sources: [], provider: "openai", model: "test", article_ids: [] });
    const user = userEvent.setup();
    render(<AskSkimDialog onClose={vi.fn()} />);
    const input = screen.getByRole("textbox", { name: "Question about your articles" });
    await user.type(input, "First{Enter}");
    await user.type(input, "Follow-up");
    await user.click(screen.getByRole("button", { name: "Queue" }));
    expect(screen.getByRole("listitem", { name: "Queued message 1" })).toHaveTextContent("Follow-up");
    expect(chatWithArticles).toHaveBeenCalledTimes(1);
    await act(async () => finish({ content: "First answer", sources: [], provider: "openai", model: "test", article_ids: [] }));
    expect(await screen.findByText("Second answer")).toBeInTheDocument();
    expect(vi.mocked(chatWithArticles).mock.calls[1][1]).toBe("Follow-up");
    expect(screen.queryByRole("list", { name: "Queued messages" })).not.toBeInTheDocument();
  });

  it("asks a starter question as soon as it is clicked", async () => {
    settings = { ai: { provider: "openai", chat_provider: "same" } };
    const user = userEvent.setup();
    render(<AskSkimDialog onClose={vi.fn()} />);
    const starter = "What are the top 10 things I should know from today's articles?";
    await user.click(screen.getByRole("button", { name: starter }));
    expect(chatWithArticles).toHaveBeenCalledWith("unread", starter, [], undefined);
    expect(await screen.findByText("Answer")).toBeVisible();
    expect(screen.queryByRole("button", { name: "What did I miss this week?" })).toBeNull();
  });

  it("restores composer focus after a fast response and restores opener only on ordinary close", async () => {
    settings = { ai: { provider: "openai", chat_provider: "same" } };
    const opener = document.createElement("button");
    opener.textContent = "Fixture opener";
    document.body.appendChild(opener);
    opener.focus();
    const close = vi.fn();
    const view = render(<AskSkimDialog onClose={close} />);
    const user = userEvent.setup();
    await user.type(screen.getByRole("textbox"), "Question");
    await user.click(screen.getByRole("button", { name: "Send" }));
    await screen.findByText("Answer");
    expect(screen.getByRole("textbox")).toHaveFocus();
    view.rerender(<AskSkimDialog open={false} onClose={close} />);
    expect(opener).toHaveFocus();
    opener.remove();
  });

  it("does not restore the Ask opener when opening a citation and uses the phone safe area", async () => {
    settings = { ai: { provider: "openai", chat_provider: "same" } };
    useUiStore.setState({ isPhone: true });
    const opener = document.createElement("button");
    document.body.appendChild(opener);
    opener.focus();
    vi.mocked(chatWithArticles).mockResolvedValueOnce({ content: "Evidence [1]", sources: [{ id: "a", title: "Quasar report", feed_title: "Science", url: null, published_at: null, source_type: "article" }], provider: "openai", model: "test", article_ids: ["a"] });
    const close = vi.fn();
    const restoreFocusTarget = () => opener;
    const view = render(<AskSkimDialog restoreFocusTarget={restoreFocusTarget} onClose={close} onOpenArticle={vi.fn()} />);
    expect(screen.getByRole("dialog").style.paddingTop).toBe("max(var(--sat, 0px), 8px)");
    const user = userEvent.setup();
    await user.type(screen.getByRole("textbox"), "Quasar");
    await user.click(screen.getByRole("button", { name: "Send" }));
    await user.click(await screen.findByRole("button", { name: /Quasar report/ }));
    view.rerender(<AskSkimDialog open={false} restoreFocusTarget={restoreFocusTarget} onClose={close} onOpenArticle={vi.fn()} />);
    expect(opener).not.toHaveFocus();
    const reader = document.createElement("button");
    document.body.appendChild(reader);
    reader.focus();
    view.rerender(<AskSkimDialog open restoreFocusTarget={restoreFocusTarget} onClose={close} onOpenArticle={vi.fn()} />);
    reader.remove();
    view.rerender(<AskSkimDialog open={false} restoreFocusTarget={restoreFocusTarget} onClose={close} onOpenArticle={vi.fn()} />);
    expect(opener).toHaveFocus();
    opener.remove();
  });

  it("keeps conversation, scope and draft when hidden for reading a citation", async () => {
    settings = { ai: { provider: "openai", chat_provider: "same" } };
    const onClose = vi.fn();
    const onOpenArticle = vi.fn();
    vi.mocked(chatWithArticles).mockResolvedValueOnce({ content: "Evidence [1]", sources: [{ id: "a", title: "Quasar report", feed_title: "Science", url: null, published_at: null, source_type: "article" }], provider: "openai", model: "test", article_ids: ["a"] });
    const view = render(<AskSkimDialog onClose={onClose} onOpenArticle={onOpenArticle} />);
    const user = userEvent.setup();
    await user.selectOptions(screen.getByRole("combobox"), "all");
    await user.type(screen.getByRole("textbox"), "Find quasar");
    await user.click(screen.getByRole("button", { name: "Send" }));
    await screen.findByText(/^Evidence/);
    await user.type(screen.getByRole("textbox"), "Summarize that");
    await user.click(screen.getByRole("button", { name: /Quasar report/ }));
    expect(onOpenArticle).toHaveBeenCalledWith("a");
    expect(onClose).toHaveBeenCalled();
    view.rerender(<AskSkimDialog open={false} onClose={onClose} onOpenArticle={onOpenArticle} />);
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    view.rerender(<AskSkimDialog open onClose={onClose} onOpenArticle={onOpenArticle} />);
    expect(screen.getByRole("combobox")).toHaveValue("all");
    expect(screen.getByRole("textbox")).toHaveValue("Summarize that");
    expect(screen.getByText(/^Evidence/)).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Send" }));
    await screen.findByText("Answer");
    expect(chatWithArticles).toHaveBeenLastCalledWith("all", "Summarize that", [{ role: "user", content: "Find quasar" }, { role: "assistant", content: "Evidence [1]" }], ["a"]);
  });

  it("explains missing MLX weights without claiming the provider is unconfigured", async () => {
    settings = { ai: { provider: "mlx", chat_provider: "same" } };
    vi.mocked(chatWithArticles).mockRejectedValueOnce(new Error("[configure-ai] MLX on-device model unavailable: Model mlx-community/Qwen2.5-3B-Instruct-4bit is not downloaded."));
    const user = userEvent.setup();
    render(<AskSkimDialog onClose={vi.fn()} />);
    expect(screen.queryByText("Set up AI to continue")).not.toBeInTheDocument();
    await user.type(screen.getByRole("textbox"), "Find iPhone articles");
    await user.click(screen.getByRole("button", { name: "Send" }));
    expect(await screen.findByText("Download your selected model")).toBeInTheDocument();
    expect(screen.getByText(/Model mlx-community\/Qwen2.5-3B-Instruct-4bit is not downloaded/)).toBeInTheDocument();
    expect(screen.queryByText("Set up AI to continue")).not.toBeInTheDocument();
    expect(screen.getByRole("textbox")).toHaveValue("Find iPhone articles");
  });

  it("preserves draft through settings and enables sending after provider setup", async () => {
    const user = userEvent.setup();
    render(<AskSkimDialog onClose={vi.fn()} />);
    await user.type(screen.getByRole("textbox"), "What changed today?");
    expect(screen.getByRole("button", { name: "Send" })).toBeDisabled();
    await user.click(screen.getByRole("button", { name: "Open AI settings" }));
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    expect(chatWithArticles).not.toHaveBeenCalled();
    settings = { ai: { provider: "openai", chat_provider: "same" } };
    act(() => useUiStore.setState({ showSettings: false }));
    expect(screen.getByRole("textbox")).toHaveValue("What changed today?");
    await user.click(screen.getByRole("button", { name: "Send" }));
    expect(await screen.findByText("Answer")).toBeInTheDocument();
    expect(chatWithArticles).toHaveBeenCalledWith("unread", "What changed today?", [], undefined);
  });

  it("uses separate chat provider even when main AI is disabled", () => {
    settings = { ai: { provider: "none", chat_provider: "openai" } };
    render(<AskSkimDialog onClose={vi.fn()} />);
    expect(screen.queryByRole("button", { name: "Open AI settings" })).not.toBeInTheDocument();
  });

  it("keeps the model picker behind a cog, disabled while a question is in flight", async () => {
    settings = { ai: { provider: "openai", chat_provider: "same" } };
    let finish: (value: Awaited<ReturnType<typeof chatWithArticles>>) => void = () => {};
    vi.mocked(chatWithArticles).mockReturnValueOnce(
      new Promise((resolve) => {
        finish = resolve;
      }),
    );
    const user = userEvent.setup();
    render(<AskSkimDialog onClose={vi.fn()} />);

    expect(screen.queryByTestId("model-picker")).not.toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Chat settings" }));
    const picker = screen.getByTestId("model-picker");
    expect(picker).toHaveAttribute("data-surface", "chat");
    expect(picker).toHaveAttribute("data-disabled", "false");

    await user.type(screen.getByRole("textbox"), "Question");
    await user.click(screen.getByRole("button", { name: "Send" }));
    await user.click(screen.getByRole("button", { name: "Chat settings" }));
    expect(screen.getByTestId("model-picker")).toHaveAttribute("data-disabled", "true");

    await act(async () => {
      finish({ content: "Answer", sources: [], provider: "openai", model: "test", article_ids: [] });
    });
  });

  it("keeps failed question and offers settings for authentication errors", async () => {
    settings = { ai: { provider: "openai", chat_provider: "same" } };
    vi.mocked(chatWithArticles).mockRejectedValueOnce(new Error("[configure-ai] OpenAI API key not set"));
    const user = userEvent.setup();
    render(<AskSkimDialog onClose={vi.fn()} />);
    await user.type(screen.getByRole("textbox"), "Summarize this week");
    await user.click(screen.getByRole("button", { name: "Send" }));
    expect(await screen.findByRole("button", { name: "Open AI settings" })).toBeInTheDocument();
    expect(screen.getByRole("textbox")).toHaveValue("Summarize this week");
  });
});


it("renders Markdown and preserves quoted Ask Skim follow-ups through failed send and retry", async () => {
  settings = { ai: { provider: "openai", chat_provider: "same" } };
  vi.mocked(chatWithArticles)
    .mockResolvedValueOnce({ content: "## Evidence\n\nQuasar changed.", sources: [], provider: "openai", model: "test", article_ids: ["a"] })
    .mockRejectedValueOnce(new Error("Unavailable"))
    .mockResolvedValue({ content: "Explanation", sources: [], provider: "openai", model: "test", article_ids: ["a"] });
  render(<AskSkimDialog onClose={vi.fn()} />);
  const user = userEvent.setup();
  await user.type(screen.getByRole("textbox"), "Find quasar{Enter}");
  expect(await screen.findByRole("heading", { name: "Evidence" })).toBeInTheDocument();
  selectChatText(screen.getByText("Quasar changed.").firstChild!);
  await user.click(screen.getByRole("button", { name: "Reply to selection" }));
  await user.type(screen.getByRole("textbox"), "Why?{Enter}");
  await screen.findByRole("alert");
  expect(screen.getByRole("textbox")).toHaveValue("Why?");
  expect(screen.getByRole("note", { name: "Quoted text" })).toHaveTextContent("Quasar changed.");
  await user.click(screen.getByRole("button", { name: "Send" }));
  await screen.findByText("Explanation");
  const quoted = "Replying to Skim:\n> Quasar changed.\n\nWhy?";
  expect(vi.mocked(chatWithArticles).mock.calls[2][1]).toBe(quoted);
  await user.type(screen.getByRole("textbox"), "More{Enter}");
  expect(vi.mocked(chatWithArticles).mock.calls[3][2]).toContainEqual({ role: "user", content: quoted });
});

describe("AskSkimDialog continuing an agent conversation", () => {
  const agentAnswer = {
    content: "It compares Tokio and smol [1].", provider: "openai", model: "m",
    sources: [{ id: "r1", title: "Rust async runtimes", feed_title: "Lobsters", url: null, published_at: null, source_type: "article" as const }],
    article_ids: ["r1"], actions: [], steps: [{ tool: "get_article", label: "Read “Rust async runtimes”" }],
  };

  it("picks up the palette's conversation and answers follow-ups from the agent with the same context", async () => {
    settings = { ai: { provider: "openai", chat_provider: "same" } };
    vi.mocked(askAgent).mockResolvedValue(agentAnswer);
    useAgentChatStore.setState({ seed: {
      context: { view: "today", story: { story_id: "s1", title: "Async Rust", article_ids: ["r1"] } },
      messages: [
        { role: "user", content: "where's the rust piece?" },
        { role: "assistant", content: "Found it: [1]", sources: agentAnswer.sources, articleIds: ["r1"] },
      ],
    } });
    const user = userEvent.setup();
    render(<AskSkimDialog onClose={vi.fn()} />);
    expect(screen.getByText(/^Found it:/)).toBeInTheDocument();
    expect(screen.getByText("Story: Async Rust")).toBeInTheDocument();
    expect(screen.queryByRole("combobox", { name: "Articles to search" })).not.toBeInTheDocument();
    expect(useAgentChatStore.getState().seed).toBeNull();

    await user.type(screen.getByRole("textbox"), "What does it say?");
    await user.click(screen.getByRole("button", { name: "Send" }));
    expect(await screen.findByText(/compares Tokio and smol/)).toBeInTheDocument();
    expect(screen.getByText("Read “Rust async runtimes”")).toBeInTheDocument();
    const [messages, context, priorIds] = vi.mocked(askAgent).mock.calls[0];
    expect(messages.map((m) => m.role)).toEqual(["user", "assistant", "user"]);
    expect(context).toMatchObject({ view: "today", story: { story_id: "s1" } });
    expect(priorIds).toEqual(["r1"]);
    expect(chatWithArticles).not.toHaveBeenCalled();
  });

  it("runs the opener's send hook when a question is sent, not when the chat opens", async () => {
    settings = { ai: { provider: "openai", chat_provider: "same" } };
    vi.mocked(askAgent).mockResolvedValue(agentAnswer);
    const onSend = vi.fn();
    useAgentChatStore.setState({ seed: { context: { view: "today", story: { story_id: "s1", title: "Async Rust", article_ids: ["r1"] } }, onSend } });
    const user = userEvent.setup();
    render(<AskSkimDialog onClose={vi.fn()} />);
    expect(onSend).not.toHaveBeenCalled();
    await user.type(screen.getByRole("textbox"), "What does it say?");
    await user.click(screen.getByRole("button", { name: "Send" }));
    expect(await screen.findByText(/compares Tokio and smol/)).toBeInTheDocument();
    expect(onSend).toHaveBeenCalledTimes(1);
  });

  it("focuses the box for a passage asked about from a selection, even on a phone", () => {
    settings = { ai: { provider: "openai", chat_provider: "same" } };
    useUiStore.setState({ isPhone: true });
    useAgentChatStore.setState({ seed: { context: { view: "today", story: { story_id: "s1", title: "Async Rust", article_ids: ["r1"] } }, reply: { role: "story", text: "Tokio is the default" } } });
    render(<AskSkimDialog onClose={vi.fn()} />);
    expect(screen.getByText("Tokio is the default")).toBeInTheDocument();
    expect(screen.getByRole("textbox")).toHaveFocus();
  });

  it("leaves the keyboard down on a phone when the chat opens without a quote", () => {
    settings = { ai: { provider: "openai", chat_provider: "same" } };
    useUiStore.setState({ isPhone: true });
    useAgentChatStore.setState({ seed: { context: { view: "today" } } });
    render(<AskSkimDialog onClose={vi.fn()} />);
    expect(screen.getByRole("textbox")).not.toHaveFocus();
  });

  it("sends a handed-over question straight away", async () => {
    settings = { ai: { provider: "openai", chat_provider: "same" } };
    vi.mocked(askAgent).mockResolvedValue(agentAnswer);
    useAgentChatStore.setState({ seed: { context: { view: "all" }, prompt: "what's new in rust?", autoSend: true } });
    render(<AskSkimDialog onClose={vi.fn()} />);
    expect(await screen.findByText(/compares Tokio and smol/)).toBeInTheDocument();
    expect(vi.mocked(askAgent).mock.calls[0][0]).toEqual([{ role: "user", content: "what's new in rust?" }]);
  });
});

describe("AskSkimDialog deep research", () => {
  const BRIEFING = {
    content: "Fusion is still years off [1], though ITER now targets 2034 [w1].\n\n## What's happening\nPrivate firms raised more [2].",
    provider: "openai", model: "m", article_ids: ["a1", "a2"], actions: [],
    steps: [{ tool: "plan", label: "Planning the research" }, { tool: "web_search", label: "Searched the web for “ITER timeline”" }],
    sources: [
      { id: "a1", title: "Fusion's long road", feed_title: "Ars Technica", url: null, published_at: null, source_type: "article" as const },
      { id: "a2", title: "Fusion startups raise billions", feed_title: "The Verge", url: null, published_at: null, source_type: "article" as const },
      { id: "web-0", title: "ITER timeline", feed_title: "iter.org", url: "https://iter.org/t", published_at: null, source_type: "web" as const },
      { id: "web-1", title: "Uncited result", feed_title: "example.com", url: "https://example.com", published_at: null, source_type: "web" as const },
    ],
  };

  it("researches with live progress and shows a briefing citing feeds and the web", async () => {
    settings = { ai: { provider: "openai", chat_provider: "same" } };
    let finish: (value: typeof BRIEFING) => void = () => {};
    vi.mocked(researchTopic).mockImplementation((_messages, _context, requestId) => {
      queueMicrotask(() => progressListeners.forEach((fire) => {
        fire({ payload: { request_id: requestId, label: "Searched your feeds for “fusion”" } });
        fire({ payload: { request_id: "someone-else", label: "Not ours" } });
      }));
      return new Promise((resolve) => { finish = resolve; });
    });
    const user = userEvent.setup();
    render(<AskSkimDialog onClose={vi.fn()} />);
    await user.click(screen.getByRole("button", { name: "Deep research" }));
    expect(screen.getByRole("button", { name: "Deep research" })).toHaveAttribute("aria-pressed", "true");
    await user.type(screen.getByRole("textbox", { name: "Topic to research" }), "Where is fusion power at?");
    await user.click(screen.getByRole("button", { name: "Research" }));

    expect(await screen.findByText("Searched your feeds for “fusion”")).toBeVisible();
    expect(screen.queryByText("Not ours")).toBeNull();
    expect(screen.getByText(/takes a minute or two/)).toBeVisible();
    const [messages, context] = vi.mocked(researchTopic).mock.calls[0];
    expect(messages).toEqual([{ role: "user", content: "Where is fusion power at?" }]);
    expect(context).toEqual({});

    await act(async () => finish(BRIEFING));
    expect(await screen.findByText("Research briefing")).toBeVisible();
    expect(screen.getByText("How Skim researched this (2 steps)")).toBeInTheDocument();
    // [1], [w1], [2] become chips 1, 2, 3 in reading order, each matching a card.
    expect(screen.getAllByRole("link").map((link) => link.textContent)).toEqual(["1", "2", "3"]);
    expect(screen.getByRole("link", { name: "2" })).toHaveAttribute("title", "ITER timeline");
    expect(screen.getByRole("button", { name: /^2.*iter\.org.*ITER timeline/ })).toBeVisible();
    expect(screen.getByText("Also searched (1)")).toBeInTheDocument();
    expect(askAgent).not.toHaveBeenCalled();
    expect(chatWithArticles).not.toHaveBeenCalled();
  });

  it("starts in deep research when the palette asks for it", async () => {
    settings = { ai: { provider: "openai", chat_provider: "same" } };
    vi.mocked(researchTopic).mockResolvedValue(BRIEFING);
    useAgentChatStore.setState({ seed: { context: { view: "today" }, prompt: "fusion power", autoSend: true, research: true } });
    render(<AskSkimDialog onClose={vi.fn()} />);
    expect(await screen.findByText("Research briefing")).toBeVisible();
    expect(vi.mocked(researchTopic).mock.calls[0][1]).toEqual({ view: "today" });
  });
});
