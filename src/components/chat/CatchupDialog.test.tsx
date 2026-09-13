import { beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { CatchupDialog } from "./CatchupDialog";
import { useUiStore } from "../../stores/uiStore";
import { generateCatchupReport } from "../../services/commands";

let provider = "openai";
let settings = { ai: { provider } };

vi.mock("../../hooks/useSettings", () => ({
  useSettings: () => ({ data: settings }),
}));

vi.mock("../../services/commands", () => ({
  generateCatchupReport: vi.fn(),
}));

vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn() }));

const report = {
  takeaways: [{ text: "The main takeaway", article_ids: [] }],
  notable_mentions: [],
  sources: [],
};

beforeEach(() => {
  vi.clearAllMocks();
  provider = "openai";
  settings = { ai: { provider } };
  useUiStore.setState({ isPhone: false, showSettings: false });
  vi.mocked(generateCatchupReport).mockResolvedValue(report);
});

describe("CatchupDialog", () => {
  it("offers AI setup before a request when no provider is configured", async () => {
    provider = "none";
    settings = { ai: { provider } };
    render(<CatchupDialog onClose={vi.fn()} />);

    expect(screen.getByRole("button", { name: "Run catch-up" })).toBeDisabled();
    await userEvent.setup().click(screen.getByRole("button", { name: "Open AI settings" }));

    expect(useUiStore.getState().showSettings).toBe(true);
    expect(generateCatchupReport).not.toHaveBeenCalled();
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("turns backend configuration errors into a settings action", async () => {
    vi.mocked(generateCatchupReport).mockRejectedValueOnce(new Error("No AI provider configured"));
    render(<CatchupDialog onClose={vi.fn()} />);

    await userEvent.setup().click(screen.getByRole("button", { name: "Run catch-up" }));

    expect(await screen.findByRole("button", { name: "Open AI settings" })).toBeInTheDocument();
    expect(screen.queryByText("No AI provider configured")).not.toBeInTheDocument();
  });

  it("shows generic failures with an explicit retry", async () => {
    vi.mocked(generateCatchupReport).mockRejectedValueOnce(new Error("Network unavailable"));
    render(<CatchupDialog onClose={vi.fn()} />);

    await userEvent.setup().click(screen.getByRole("button", { name: "Run catch-up" }));

    expect(await screen.findByRole("alert")).toHaveTextContent("Network unavailable");
    expect(screen.getByRole("button", { name: "Try again" })).toBeInTheDocument();
  });

  it("runs only on explicit action and never on a scope change", async () => {
    render(<CatchupDialog onClose={vi.fn()} />);

    expect(generateCatchupReport).not.toHaveBeenCalled();
    await userEvent.setup().click(screen.getByRole("button", { name: "Run catch-up" }));
    await waitFor(() => expect(generateCatchupReport).toHaveBeenCalledWith("unread"));

    await userEvent.setup().selectOptions(screen.getByLabelText("Include"), "inbox");
    await waitFor(() => expect(screen.getByRole("button", { name: "Run catch-up" })).toBeInTheDocument());
    expect(generateCatchupReport).toHaveBeenCalledTimes(1);
  });

  it("closes with Escape and exposes modal semantics", () => {
    const onClose = vi.fn();
    render(<CatchupDialog onClose={onClose} />);

    const dialog = screen.getByRole("dialog", { name: "Quick Catch-up" });
    expect(dialog).toHaveAttribute("aria-modal", "true");
    fireEvent.keyDown(dialog, { key: "Escape" });
    expect(onClose).toHaveBeenCalledOnce();
  });
});
