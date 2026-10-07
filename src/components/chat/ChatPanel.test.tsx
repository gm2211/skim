import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ChatDrawer } from "./ChatPanel";
import { chatWithArticle, webSearch } from "../../services/commands";
import { selectChatText } from "../../test/selectChatText";
import { useUiStore } from "../../stores/uiStore";

vi.mock("../../services/commands", () => ({
  chatWithArticle: vi.fn(),
  webSearch: vi.fn(),
}));

let settings = { ai: { provider: "openai", chat_provider: "same" } };
vi.mock("../../hooks/useSettings", () => ({
  useSettings: () => ({ data: settings }),
}));
vi.mock("../common/ModelPicker", () => ({
  ModelPicker: (p: { surface: string; disabled?: boolean }) => (
    <div data-testid="model-picker" data-surface={p.surface} data-disabled={String(!!p.disabled)} />
  ),
}));

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((res) => { resolve = res; });
  return { promise, resolve };
}

beforeEach(() => {
  vi.clearAllMocks();
  settings = { ai: { provider: "openai", chat_provider: "same" } };
  useUiStore.setState({ isPhone: false });
  HTMLElement.prototype.scrollIntoView = vi.fn();
  vi.mocked(webSearch).mockResolvedValue([]);
});

async function openAndType(text: string) {
  const user = userEvent.setup();
  await user.click(screen.getByText("Chat"));
  await user.type(screen.getByPlaceholderText("Ask about this article..."), text);
  return user;
}

describe("ChatDrawer", () => {
  it("opens by keyboard, focuses the composer, and sends without scrolling the document", async () => {
    vi.mocked(chatWithArticle).mockResolvedValue({ content: "Answer", web_citations: [], provider: "openai", model: "test" });
    const user = userEvent.setup();
    render(<ChatDrawer articleId="article-1" articleTitle="Article" />);
    screen.getByRole("button", { name: "Chat with article" }).focus();
    await user.keyboard("{Enter}");
    const input = screen.getByPlaceholderText("Ask about this article...");
    expect(input).toHaveFocus();
    await user.type(input, "Explain this{Enter}");
    expect(await screen.findByText("Answer")).toBeInTheDocument();
    expect(chatWithArticle).toHaveBeenCalledWith("article-1", [{ role: "user", content: "Explain this" }], undefined);
    expect(HTMLElement.prototype.scrollIntoView).not.toHaveBeenCalled();
  });

  it("sends the current generated summary and drops it when the article changes", async () => {
    vi.mocked(chatWithArticle).mockResolvedValue({ content: "Answer", web_citations: [], provider: "openai", model: "test" });
    const view = render(<ChatDrawer articleId="article-1" articleTitle="Article" summaryContext="The summary concludes X." open />);
    const user = userEvent.setup();
    await user.type(screen.getByPlaceholderText("Ask about this article..."), "Explain your summary{Enter}");
    await screen.findByText("Answer");
    expect(chatWithArticle).toHaveBeenLastCalledWith("article-1", [{ role: "user", content: "Explain your summary" }], "The summary concludes X.");
    view.rerender(<ChatDrawer articleId="article-2" articleTitle="Other" open />);
    await user.type(screen.getByPlaceholderText("Ask about this article..."), "Explain this article{Enter}");
    await waitFor(() => expect(chatWithArticle).toHaveBeenLastCalledWith("article-2", [{ role: "user", content: "Explain this article" }], undefined));
  });

  it("clears the AI setup card once settings change so the retry is reachable", async () => {
    vi.mocked(chatWithArticle)
      .mockRejectedValueOnce(new Error("[configure-ai] No local model selected. Go to Settings to download one."))
      .mockResolvedValueOnce({ content: "Answer", web_citations: [], provider: "mlx", model: "test" });
    settings = { ai: { provider: "local", chat_provider: "same" } };
    const view = render(<ChatDrawer articleId="article-1" articleTitle="Article" />);
    const user = await openAndType("Explain this");
    await user.click(screen.getByRole("button", { name: "Send message" }));
    expect(await screen.findByText("AI needs attention")).toBeInTheDocument();

    settings = { ai: { provider: "mlx", chat_provider: "same" } };
    view.rerender(<ChatDrawer articleId="article-1" articleTitle="Article" />);
    expect(screen.queryByText("AI needs attention")).not.toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Send message" }));
    expect(await screen.findByText("Answer")).toBeInTheDocument();
  });

  it("preserves a failed draft and keeps provider errors out of chat history", async () => {
    vi.mocked(chatWithArticle).mockRejectedValueOnce(new Error("Provider unavailable"));
    render(<ChatDrawer articleId="article-1" articleTitle="Article" />);
    const user = await openAndType("Explain this");

    await user.click(screen.getByRole("button", { name: "Send message" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("Provider unavailable");
    expect(screen.getByPlaceholderText("Ask about this article...")).toHaveValue("Explain this");
    expect(screen.queryByText("Error: Provider unavailable")).not.toBeInTheDocument();
  });

  it("preflights the effective chat provider and preserves the drawer for settings overlay", async () => {
    settings = { ai: { provider: "openai", chat_provider: "none" } };
    const user = userEvent.setup();
    render(<ChatDrawer articleId="article-1" articleTitle="Article" />);
    await user.click(screen.getByText("Chat"));

    expect(screen.getByRole("status", { name: "AI setup" })).toBeInTheDocument();
    expect(screen.getByPlaceholderText("Ask about this article...")).toBeDisabled();
    expect(chatWithArticle).not.toHaveBeenCalled();
  });

  it("mounts the chat model picker, disabled while a message is in flight", async () => {
    const response = deferred<{ content: string; web_citations: []; provider: string; model: string }>();
    vi.mocked(chatWithArticle).mockReturnValueOnce(response.promise);
    render(<ChatDrawer articleId="article-1" articleTitle="Article" />);
    const user = await openAndType("Explain this");

    const picker = screen.getByTestId("model-picker");
    expect(picker).toHaveAttribute("data-surface", "chat");
    expect(picker).toHaveAttribute("data-disabled", "false");

    await user.click(screen.getByRole("button", { name: "Send message" }));
    expect(screen.getByTestId("model-picker")).toHaveAttribute("data-disabled", "true");

    await act(async () => response.resolve({ content: "Answer", web_citations: [], provider: "openai", model: "test" }));
  });

  it("does not append a response that arrives after the article changes", async () => {
    const response = deferred<{ content: string; web_citations: []; provider: string; model: string }>();
    vi.mocked(chatWithArticle).mockReturnValueOnce(response.promise);
    const view = render(<ChatDrawer articleId="article-1" articleTitle="Article" />);
    const user = await openAndType("Explain this");
    await user.click(screen.getByRole("button", { name: "Send message" }));

    view.rerender(<ChatDrawer articleId="article-2" articleTitle="Other article" />);
    await act(async () => response.resolve({ content: "Old article answer", web_citations: [], provider: "openai", model: "test" }));

    await waitFor(() => expect(screen.queryByText("Old article answer")).not.toBeInTheDocument());
    expect(screen.queryByText("Explain this")).not.toBeInTheDocument();
  });
});


describe("ChatDrawer quoted replies", () => {
  it("sends selected excerpt, retains it in history, and resets quote on article change", async () => {
    vi.mocked(chatWithArticle)
      .mockResolvedValueOnce({ content: "First sentence. Second sentence.", web_citations: [], provider: "openai", model: "test" })
      .mockResolvedValue({ content: "Follow-up", web_citations: [], provider: "openai", model: "test" });
    const view = render(<ChatDrawer articleId="article-1" articleTitle="Article" />);
    const user = await openAndType("Explain");
    await user.click(screen.getByRole("button", { name: "Send message" }));
    selectChatText((await screen.findByText("First sentence. Second sentence.")).firstChild!, 16);
    await user.click(screen.getByRole("button", { name: "Reply to selection" }));
    expect(screen.getByRole("note", { name: "Quoted text" })).toHaveTextContent("Second sentence.");
    expect(screen.getByRole("textbox")).toHaveFocus();
    await user.type(screen.getByRole("textbox"), "Why?{Enter}");
    await screen.findByText("Follow-up");
    const quoted = { role: "user", content: "Replying to Skim:\n> Second sentence.\n\nWhy?" };
    expect(vi.mocked(chatWithArticle).mock.calls[1][1].slice(-1)[0]).toEqual(quoted);
    await user.type(screen.getByRole("textbox"), "More{Enter}");
    await waitFor(() => expect(vi.mocked(chatWithArticle).mock.calls[2][1]).toContainEqual(quoted));
    selectChatText(screen.getByText("First sentence. Second sentence.").firstChild!, 0, 15);
    await user.click(screen.getByRole("button", { name: "Reply to selection" }));
    view.rerender(<ChatDrawer articleId="article-2" articleTitle="Other" />);
    expect(screen.queryByRole("note", { name: "Quoted text" })).not.toBeInTheDocument();
  });

  it("restores quote and draft after failure, and permits removing quote before retry", async () => {
    vi.mocked(chatWithArticle)
      .mockResolvedValueOnce({ content: "Answer excerpt", web_citations: [], provider: "openai", model: "test" })
      .mockRejectedValueOnce(new Error("Provider unavailable"))
      .mockResolvedValueOnce({ content: "Retry answer", web_citations: [], provider: "openai", model: "test" });
    render(<ChatDrawer articleId="article-1" articleTitle="Article" />);
    const user = await openAndType("Explain");
    await user.click(screen.getByRole("button", { name: "Send message" }));
    selectChatText((await screen.findByText("Answer excerpt")).firstChild!);
    await user.click(screen.getByRole("button", { name: "Reply to selection" }));
    await user.type(screen.getByRole("textbox"), "Why?{Enter}");
    await screen.findByRole("alert");
    expect(screen.getByRole("textbox")).toHaveValue("Why?");
    expect(screen.getByRole("note", { name: "Quoted text" })).toHaveTextContent("Answer excerpt");
    await user.click(screen.getByRole("button", { name: "Remove quoted text" }));
    await user.click(screen.getByRole("button", { name: "Send message" }));
    await screen.findByText("Retry answer");
    expect(vi.mocked(chatWithArticle).mock.calls[2][1].slice(-1)[0]).toEqual({ role: "user", content: "Why?" });
  });
});
