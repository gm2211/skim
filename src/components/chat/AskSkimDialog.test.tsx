import { beforeEach, describe, expect, it, vi } from "vitest";
import { act, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { AskSkimDialog } from "./AskSkimDialog";
import { useUiStore } from "../../stores/uiStore";
import { chatWithArticles } from "../../services/commands";

let settings = { ai: { provider: "none", chat_provider: "same" } };
vi.mock("../../hooks/useSettings", () => ({ useSettings: () => ({ data: settings }) }));
vi.mock("../../services/commands", () => ({ chatWithArticles: vi.fn() }));
vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn() }));

beforeEach(() => {
  vi.clearAllMocks();
  settings = { ai: { provider: "none", chat_provider: "same" } };
  useUiStore.setState({ isPhone: false, showSettings: false });
  HTMLElement.prototype.scrollTo = vi.fn();
  vi.mocked(chatWithArticles).mockResolvedValue({ content: "Answer", sources: [], provider: "openai", model: "test-model", article_ids: [] });
});

describe("AskSkimDialog setup recovery", () => {
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
    await screen.findByText("Evidence [1]");
    await user.type(screen.getByRole("textbox"), "Summarize that");
    await user.click(screen.getByRole("button", { name: /Quasar report/ }));
    expect(onOpenArticle).toHaveBeenCalledWith("a");
    expect(onClose).toHaveBeenCalled();
    view.rerender(<AskSkimDialog open={false} onClose={onClose} onOpenArticle={onOpenArticle} />);
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    view.rerender(<AskSkimDialog open onClose={onClose} onOpenArticle={onOpenArticle} />);
    expect(screen.getByRole("combobox")).toHaveValue("all");
    expect(screen.getByRole("textbox")).toHaveValue("Summarize that");
    expect(screen.getByText("Evidence [1]")).toBeInTheDocument();
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
