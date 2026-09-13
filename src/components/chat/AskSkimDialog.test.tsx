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
    expect(chatWithArticles).toHaveBeenCalledWith("unread", "What changed today?", []);
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
