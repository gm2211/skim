import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { SettingsDialog } from "./SettingsDialog";
import { useUiStore } from "../../stores/uiStore";
import { listRemoteModels } from "../../services/commands";

const { saveSettings } = vi.hoisted(() => ({ saveSettings: vi.fn() }));
vi.mock("../../utils/platform", () => ({ isIOS: false, isMacOS: true }));
vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn().mockResolvedValue(() => {}) }));

const settings = { ai: { provider: "openai", api_key: "test-openai-secret", endpoint: null, model: "saved-model" }, appearance: {}, sync: {} };
vi.mock("../../hooks/useSettings", () => ({
  useSettings: () => ({ data: settings }),
  useUpdateSettings: () => ({ mutateAsync: saveSettings, isPending: false, error: null }),
}));
vi.mock("../../services/commands", async (original) => ({
  ...await original<typeof import("../../services/commands")>(),
  listRemoteModels: vi.fn(),
  mlxIsAvailable: vi.fn().mockResolvedValue(true),
  mlxIsModelDownloaded: vi.fn().mockResolvedValue(false),
}));

beforeEach(() => {
  saveSettings.mockClear();
  useUiStore.setState({ isPhone: false, showSettings: true });
  vi.mocked(listRemoteModels).mockResolvedValue([]);
});

describe("Settings provider drafts", () => {
  it("keeps on-device model changes in the draft until Save", async () => {
    const user = userEvent.setup();
    render(<SettingsDialog />);
    await user.selectOptions(await screen.findByRole("combobox", { name: "Provider" }), "mlx");
    await screen.findByText("On-device MLX runtime detected");
    await user.selectOptions(screen.getByRole("combobox", { name: "On-device model" }), "mlx-community/gemma-3-1b-it-4bit");
    expect(saveSettings).not.toHaveBeenCalled();
    await user.click(screen.getByRole("button", { name: "Cancel" }));
    expect(saveSettings).not.toHaveBeenCalled();
    expect(useUiStore.getState().showSettings).toBe(false);
  });
  it("does not send another provider's key and restores its draft on return", async () => {
    const user = userEvent.setup();
    render(<SettingsDialog />);
    await user.selectOptions(await screen.findByRole("combobox", { name: "Provider" }), "xai");
    expect(screen.queryByDisplayValue("test-openai-secret")).not.toBeInTheDocument();
    expect(screen.getByRole("combobox", { name: "Model" })).toHaveValue("");
    await user.click(screen.getByRole("button", { name: "Load available models" }));
    expect(listRemoteModels).toHaveBeenCalledWith("xai", null, null);
    await user.selectOptions(screen.getByRole("combobox", { name: "Provider" }), "openai");
    expect(screen.getByDisplayValue("test-openai-secret")).toBeInTheDocument();
    expect(screen.getByRole("combobox", { name: "Model" })).toHaveValue("saved-model");
  });
});
