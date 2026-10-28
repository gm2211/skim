import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { AiErrorText, AiSettingsButton, isBusyAiError } from "./AiSettingsButton";
import { useUiStore } from "../../stores/uiStore";

describe("AI settings shortcuts", () => {
  beforeEach(() => useUiStore.setState({ showSettings: false, settingsTab: "sync" }));

  it("the cog opens Settings on the AI tab", async () => {
    render(<AiSettingsButton />);
    await userEvent.click(screen.getByRole("button", { name: "AI settings" }));
    expect(useUiStore.getState()).toMatchObject({ showSettings: true, settingsTab: "ai" });
  });

  it("an AI error shows its message and a button to AI settings", async () => {
    render(<AiErrorText error="No AI provider configured. Go to Settings to set up an AI provider." />);
    expect(screen.getByRole("alert")).toHaveTextContent("No AI provider configured");
    await userEvent.click(screen.getByRole("button", { name: "AI settings" }));
    expect(useUiStore.getState()).toMatchObject({ showSettings: true, settingsTab: "ai" });
  });

  it("a rate limit offers Try again next to AI settings", async () => {
    const retry = vi.fn();
    const message = "Claude has hit your account's rate limit for the moment. Try again in a minute.";
    expect(isBusyAiError(message)).toBe(true);
    expect(isBusyAiError("You've reached your Claude plan's usage limit. It resets at 9:40 PM.")).toBe(true);
    expect(isBusyAiError("Claude is overloaded right now. Try again in a minute.")).toBe(true);
    expect(isBusyAiError("Not signed in to Claude")).toBe(false);
    render(<AiErrorText error={message} onRetry={retry} />);
    await userEvent.click(screen.getByRole("button", { name: "Try again" }));
    expect(retry).toHaveBeenCalledOnce();
    expect(screen.getByRole("button", { name: "AI settings" })).toBeInTheDocument();
  });
});
