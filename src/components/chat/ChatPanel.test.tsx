import { act, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { ChatDrawer } from "./ChatPanel";
import { chatWithArticle, webSearch } from "../../services/commands";
import { useUiStore } from "../../stores/uiStore";

vi.mock("../../services/commands", () => ({
  chatWithArticle: vi.fn(),
  webSearch: vi.fn(),
}));

let settings = { ai: { provider: "openai", chat_provider: "same" } };
vi.mock("../../hooks/useSettings", () => ({
  useSettings: () => ({ data: settings }),
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
    expect(chatWithArticle).toHaveBeenCalledWith("article-1", [{ role: "user", content: "Explain this" }]);
    expect(HTMLElement.prototype.scrollIntoView).not.toHaveBeenCalled();
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
