import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { SettingsDialog } from "./SettingsDialog";
import { useUiStore } from "../../stores/uiStore";
import { listRemoteModels, mlxAvailability } from "../../services/commands";

function renderDialog() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(
    <QueryClientProvider client={qc}>
      <SettingsDialog />
    </QueryClientProvider>,
  );
}

const { saveSettings, nativeRuntime } = vi.hoisted(() => ({ saveSettings: vi.fn(), nativeRuntime: vi.fn() }));
vi.mock("../../utils/platform", () => ({ isIOS: false, isMacOS: true }));
vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn().mockResolvedValue(() => {}) }));
vi.mock("@tauri-apps/api/core", async (original) => ({
  ...await original<typeof import("@tauri-apps/api/core")>(),
  isTauri: nativeRuntime,
}));

const settings = { ai: { provider: "openai", api_key: "test-openai-secret", endpoint: null, model: "saved-model" }, appearance: {}, sync: {} };
vi.mock("../../hooks/useSettings", () => ({
  useSettings: () => ({ data: settings }),
  useUpdateSettings: () => ({ mutateAsync: saveSettings, isPending: false, error: null }),
}));
vi.mock("../../services/commands", async (original) => ({
  ...await original<typeof import("../../services/commands")>(),
  listRemoteModels: vi.fn(),
  mlxAvailability: vi.fn().mockResolvedValue({ available: true }),
  mlxIsModelDownloaded: vi.fn().mockResolvedValue(false),
}));

beforeEach(() => {
  saveSettings.mockClear();
  nativeRuntime.mockReturnValue(true);
  settings.ai.provider = "openai";
  useUiStore.setState({ isPhone: false, showSettings: true });
  vi.mocked(listRemoteModels).mockResolvedValue([]);
});

describe("Settings provider drafts", () => {
  it("hides native options in browsers and retains an unavailable saved choice without starting its engine", async () => {
    nativeRuntime.mockReturnValue(false);
    settings.ai.provider = "mlx";
    vi.mocked(mlxAvailability).mockClear();
    renderDialog();
    const picker = await screen.findByRole("combobox", { name: "Provider" });
    expect(picker).toHaveValue("mlx");
    expect(screen.getByRole("option", { name: "On-device (MLX) (unavailable here)" })).toBeDisabled();
    expect(screen.queryByRole("option", { name: "Local (Embedded)" })).not.toBeInTheDocument();
    expect(screen.queryByRole("option", { name: "Apple Intelligence" })).not.toBeInTheDocument();
    expect(screen.queryByRole("combobox", { name: "On-device model" })).not.toBeInTheDocument();
    expect(mlxAvailability).not.toHaveBeenCalled();
  });
  it("keeps on-device model changes in the draft until Save", async () => {
    const user = userEvent.setup();
    renderDialog();
    await user.selectOptions(await screen.findByRole("combobox", { name: "Provider" }), "mlx");
    await screen.findByText("On-device MLX runtime detected");
    await user.selectOptions(screen.getByRole("combobox", { name: "On-device model" }), "mlx-community/gemma-3-1b-it-4bit");
    expect(saveSettings).not.toHaveBeenCalled();
    await user.click(screen.getByRole("button", { name: "Cancel" }));
    expect(saveSettings).not.toHaveBeenCalled();
    expect(useUiStore.getState().showSettings).toBe(false);
  });
  it("shows why the on-device runtime failed instead of blaming the hardware", async () => {
    vi.mocked(mlxAvailability).mockResolvedValueOnce({
      available: false,
      reason: "macOS AI bridge exited before replying (killed by signal 5)",
    });
    const user = userEvent.setup();
    renderDialog();
    await user.selectOptions(await screen.findByRole("combobox", { name: "Provider" }), "mlx");
    await screen.findByText("On-device MLX could not start: macOS AI bridge exited before replying (killed by signal 5)");
    expect(screen.queryByText(/requires an Apple silicon Mac/)).toBeNull();
  });
  it("does not send another provider's key and restores its draft on return", async () => {
    const user = userEvent.setup();
    renderDialog();
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
