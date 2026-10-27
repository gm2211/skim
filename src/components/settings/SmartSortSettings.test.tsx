import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { SettingsDialog } from "./SettingsDialog";
import { useUiStore } from "../../stores/uiStore";
import { getSmartSortPrompts, learnPreferencesNow, saveLearnedPreferences } from "../../services/commands";
import type { SmartSortPrompts } from "../../services/types";

const { saveSettings } = vi.hoisted(() => ({ saveSettings: vi.fn() }));
vi.mock("../../utils/platform", () => ({ isIOS: false, isMacOS: true }));
vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn().mockResolvedValue(() => {}) }));
const settings = { ai: { provider: "openai", api_key: "k", endpoint: null, model: "gpt-test", triage_user_prompt: "Prioritize AI infra" }, appearance: {}, sync: {} };
vi.mock("../../hooks/useSettings", () => ({
  useSettings: () => ({ data: settings }),
  useUpdateSettings: () => ({ mutateAsync: saveSettings, isPending: false, error: null }),
}));
vi.mock("../../services/commands", async (original) => ({
  ...await original<typeof import("../../services/commands")>(),
  getSmartSortPrompts: vi.fn(),
  saveLearnedPreferences: vi.fn(),
  learnPreferencesNow: vi.fn(),
  getSystemInfo: vi.fn().mockResolvedValue({ total_memory_gb: 16, available_memory_gb: 12, max_model_size_gb: 8 }),
}));

const prompts = (text: string, learning = true): SmartSortPrompts => ({
  base_prompt: "You rank RSS articles. Rate EVERY article on two separate 1-5 scales.",
  learned: { text, learning, updated_at: Math.floor(Date.now() / 1000) - 3 * 3600, since: null },
  new_signals: 4,
});

function renderTab() {
  useUiStore.setState({ isPhone: false, showSettings: true, settingsTab: "smartSort" });
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  return render(<QueryClientProvider client={qc}><SettingsDialog /></QueryClientProvider>);
}

beforeEach(() => {
  saveSettings.mockReset().mockResolvedValue(undefined);
  vi.mocked(getSmartSortPrompts).mockResolvedValue(prompts("- Likes Rust\n- Skips sports"));
  vi.mocked(saveLearnedPreferences).mockImplementation(async (text, learning) => prompts(text, learning));
  vi.mocked(learnPreferencesNow).mockResolvedValue(prompts("- Likes Rust\n- Likes GPUs"));
});

describe("Smart sort settings", () => {
  it("shows the three layers: base prompt read-only, the reader's prompt, and the learned note", async () => {
    renderTab();
    const learned = await screen.findByDisplayValue(/Likes Rust/);
    expect(learned).toHaveAccessibleName("Learned preferences");
    expect(screen.getByRole("textbox", { name: "Your prompt" })).toHaveValue("Prioritize AI infra");
    // The base prompt is shown as text, never as something to edit.
    expect(screen.getByText(/Rate EVERY article/).tagName).toBe("PRE");
    expect(screen.getAllByRole("textbox")).toHaveLength(2);
    expect(screen.getByText(/Updated 3 hours ago · 4 new articles read since/)).toBeInTheDocument();
    expect(screen.getByText("gpt-test", { exact: false })).toBeInTheDocument();
  });

  it("saves an edited note and the reader's prompt with Save", async () => {
    const user = userEvent.setup();
    renderTab();
    const learned = await screen.findByRole("textbox", { name: "Learned preferences" });
    await user.clear(learned);
    await user.type(learned, "- Likes databases");
    await user.click(screen.getByRole("checkbox", { name: "Keep learning from my reading" }));
    await user.type(screen.getByRole("textbox", { name: "Your prompt" }), ", skip sports");
    await user.click(screen.getByRole("button", { name: "Save" }));
    expect(saveSettings).toHaveBeenCalledWith(expect.objectContaining({
      ai: expect.objectContaining({ triage_user_prompt: "Prioritize AI infra, skip sports" }),
    }));
    expect(saveLearnedPreferences).toHaveBeenCalledWith("- Likes databases", false);
  });

  it("deletes the note on Save and says learning starts over", async () => {
    const user = userEvent.setup();
    renderTab();
    await screen.findByDisplayValue(/Likes Rust/);
    await user.click(screen.getByRole("button", { name: "Delete" }));
    expect(screen.getByRole("textbox", { name: "Learned preferences" })).toHaveValue("");
    expect(screen.getByText(/learns again only from what you read next/)).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Save" }));
    expect(saveLearnedPreferences).toHaveBeenCalledWith("", true);
  });

  it("learns now on top of unsaved edits", async () => {
    const user = userEvent.setup();
    renderTab();
    const learned = await screen.findByRole("textbox", { name: "Learned preferences" });
    await user.type(learned, "\n- Skips crypto");
    await user.click(screen.getByRole("button", { name: "Learn now" }));
    expect(saveLearnedPreferences).toHaveBeenCalledWith("- Likes Rust\n- Skips sports\n- Skips crypto", true);
    expect(await screen.findByDisplayValue(/Likes GPUs/)).toBeInTheDocument();
    expect(screen.getByRole("status")).toHaveTextContent("Updated from your latest reading.");
  });
});
