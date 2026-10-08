import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { SettingsDialog } from "./SettingsDialog";
import { useUiStore } from "../../stores/uiStore";
import { claudeOauthBeginPaste, claudeOauthStatus, listRemoteModels, mlxAvailability } from "../../services/commands";

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
vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn().mockResolvedValue(undefined) }));
vi.mock("../../services/commands", async (original) => ({
  ...await original<typeof import("../../services/commands")>(),
  listRemoteModels: vi.fn(),
  claudeOauthStatus: vi.fn().mockResolvedValue(false),
  claudeOauthBeginPaste: vi.fn().mockResolvedValue({ authorizeUrl: "https://example.invalid/auth" }),
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
    await screen.findByRole("group", { name: "Choose an AI service" });
    expect(screen.getByRole("status")).toHaveTextContent("On-device (MLX) is unavailable here");
    expect(screen.queryByRole("button", { name: /^Local \(Embedded\)/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /^Apple Intelligence/ })).not.toBeInTheDocument();
    expect(screen.queryByRole("combobox", { name: "Provider" })).not.toBeInTheDocument();
    expect(screen.queryByRole("combobox", { name: "On-device model" })).not.toBeInTheDocument();
    expect(mlxAvailability).not.toHaveBeenCalled();
  });
  it("uses shared settings tabs and preserves hidden account drafts", async () => {
    const user = userEvent.setup();
    renderDialog();
    await screen.findByRole("button", { name: "Change AI service" });
    expect(screen.queryByRole("combobox", { name: "Provider" })).not.toBeInTheDocument();
    expect(screen.getByRole("tab", { name: "Model" })).toHaveAttribute("aria-selected", "true");
    expect(screen.getByDisplayValue("test-openai-secret")).not.toBeVisible();
    await user.click(screen.getByRole("tab", { name: "Account" }));
    await user.clear(screen.getByDisplayValue("test-openai-secret"));
    await user.type(screen.getByPlaceholderText("sk-..."), "test-new-secret");
    await user.keyboard("{ArrowRight}");
    // Input focus does not change tabs; tab navigation starts on a tab button.
    await user.click(screen.getByRole("tab", { name: "Account" }));
    await user.keyboard("{ArrowRight}");
    expect(screen.getByRole("tab", { name: "Tools" })).toHaveAttribute("aria-selected", "true");
    expect(screen.getByPlaceholderText("sk-...")).not.toBeVisible();
    await user.click(screen.getByRole("tab", { name: "Account" }));
    expect(screen.getByDisplayValue("test-new-secret")).toBeInTheDocument();
    expect(saveSettings).not.toHaveBeenCalled();
  });
  it("preserves a pending sign-in across tabs and opening provider choices", async () => {
    const user = userEvent.setup();
    settings.ai.provider = "claude-subscription";
    vi.mocked(claudeOauthStatus).mockClear();
    vi.mocked(claudeOauthBeginPaste).mockClear();
    renderDialog();
    await user.click(await screen.findByRole("tab", { name: "Account" }));
    await user.click(screen.getByRole("button", { name: "Sign in (copy-paste)" }));
    await user.type(await screen.findByPlaceholderText("code#state"), "fake-code#fake-state");
    await user.click(screen.getByRole("tab", { name: "Model" }));
    expect(screen.getByPlaceholderText("code#state")).not.toBeVisible();
    await user.click(screen.getByRole("button", { name: "Change AI service" }));
    await user.click(screen.getByRole("button", { name: "Back to settings" }));
    expect(screen.getByRole("button", { name: "Change AI service" })).toHaveFocus();
    await user.click(screen.getByRole("tab", { name: "Account" }));
    expect(screen.getByPlaceholderText("code#state")).toHaveValue("fake-code#fake-state");
    expect(screen.getByRole("button", { name: "Finish sign-in" })).toBeEnabled();
    expect(claudeOauthBeginPaste).toHaveBeenCalledTimes(1);
    expect(claudeOauthStatus).toHaveBeenCalledTimes(1);
  });
  it("keeps on-device model changes in the draft until Save", async () => {
    const user = userEvent.setup();
    renderDialog();
    await user.click(await screen.findByRole("button", { name: "Change AI service" }));
    await user.click(screen.getByRole("button", { name: /^On-device \(MLX\)/ }));
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
    await user.click(await screen.findByRole("button", { name: "Change AI service" }));
    await user.click(screen.getByRole("button", { name: /^On-device \(MLX\)/ }));
    await screen.findByText("On-device MLX could not start: macOS AI bridge exited before replying (killed by signal 5)");
    expect(screen.queryByText(/requires an Apple silicon Mac/)).toBeNull();
  });
  it("does not send another provider's key and restores its draft on return", async () => {
    const user = userEvent.setup();
    renderDialog();
    await user.click(await screen.findByRole("button", { name: "Change AI service" }));
    await user.click(screen.getByRole("button", { name: /^Grok/ }));
    expect(screen.getByRole("button", { name: "Change AI service" })).toHaveFocus();
    expect(screen.queryByDisplayValue("test-openai-secret")).not.toBeInTheDocument();
    expect(screen.getByRole("combobox", { name: "Model" })).toHaveValue("");
    await user.click(screen.getByRole("button", { name: "Load available models" }));
    expect(listRemoteModels).toHaveBeenCalledWith("xai", null, null);
    await user.click(screen.getByRole("button", { name: "Change AI service" }));
    await user.click(screen.getByRole("button", { name: /^OpenAI/ }));
    expect(screen.getByRole("combobox", { name: "Model" })).toHaveValue("saved-model");
    await user.click(screen.getByRole("tab", { name: "Account" }));
    expect(screen.getByDisplayValue("test-openai-secret")).toBeInTheDocument();
  });
});
