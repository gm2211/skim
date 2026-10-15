import { beforeEach, describe, expect, it } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { AiErrorText, AiSettingsButton } from "./AiSettingsButton";
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
});
