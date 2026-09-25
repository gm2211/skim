import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { ModelPicker } from "./ModelPicker";
import { useUiStore } from "../../stores/uiStore";
import type { AiSettings, AppSettings } from "../../services/types";
import type { ModelSurface } from "../../hooks/useModelChoices";

vi.mock("../../services/commands", () => ({
  getSettings: vi.fn(),
  updateSettings: vi.fn(),
  listRemoteModels: vi.fn(),
  mlxIsModelDownloaded: vi.fn(),
  listLocalModels: vi.fn(),
}));

import * as commands from "../../services/commands";

const BASE_AI: AiSettings = {
  provider: "openai",
  api_key: null,
  model: "gpt-4-turbo",
  endpoint: null,
  local_model_path: null,
  local_gpu_layers: null,
  local_preload: null,
  local_idle_evict_minutes: null,
  local_power_mode: null,
  models_directory: null,
  summary_length: null,
  summary_tone: null,
  summary_format: null,
  summary_custom_prompt: null,
  summary_custom_word_count: null,
  chat_provider: null,
  chat_model: null,
  chat_api_key: null,
  chat_endpoint: null,
};

function settingsWith(ai: Partial<AiSettings>): AppSettings {
  return {
    ai: { ...BASE_AI, ...ai },
    appearance: { theme: "dark", font_size: 14, show_excerpt_in_list: false },
    sync: { refresh_interval_minutes: 30, max_articles_per_feed: 200, recent_cap: 3000, today_story_limit: 10 },
  };
}

function lastSavedSettings(): AppSettings {
  const calls = vi.mocked(commands.updateSettings).mock.calls;
  return calls[calls.length - 1][0] as AppSettings;
}

function renderPicker(surface: ModelSurface, settings: AppSettings, props: { disabled?: boolean; compact?: boolean } = {}) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  vi.mocked(commands.getSettings).mockResolvedValue(settings);
  const view = render(
    <QueryClientProvider client={qc}>
      <ModelPicker surface={surface} {...props} />
    </QueryClientProvider>,
  );
  return { ...view, qc };
}

beforeEach(() => {
  vi.clearAllMocks();
  useUiStore.setState({ isPhone: false, showSettings: false });
  vi.mocked(commands.updateSettings).mockResolvedValue(undefined);
  vi.mocked(commands.listLocalModels).mockResolvedValue([]);
  vi.mocked(commands.mlxIsModelDownloaded).mockResolvedValue(false);
  vi.mocked(commands.listRemoteModels).mockResolvedValue([]);
});

describe("ModelPicker", () => {
  it("lists remote models for a provider like openai and saves the one picked", async () => {
    vi.mocked(commands.listRemoteModels).mockResolvedValue([
      { id: "gpt-4o-mini", display_name: "GPT-4o mini" },
      { id: "gpt-4-turbo", display_name: "GPT-4 Turbo" },
    ]);
    renderPicker("catchup", settingsWith({ provider: "openai", model: "gpt-4-turbo" }));

    const combo = await screen.findByRole("combobox", { name: "AI model" });
    await screen.findByRole("option", { name: "GPT-4o mini" });
    await userEvent.setup().selectOptions(combo, "gpt-4o-mini");

    await waitFor(() => expect(commands.updateSettings).toHaveBeenCalled());
    const saved = lastSavedSettings();
    expect(saved.ai.model).toBe("gpt-4o-mini");
  });

  it("disables an MLX model that is not downloaded and saves both model fields for one that is", async () => {
    const downloaded = "mlx-community/gemma-3-1b-it-4bit";
    vi.mocked(commands.mlxIsModelDownloaded).mockImplementation(async (repoId: string) => repoId === downloaded);
    renderPicker("today", settingsWith({ provider: "mlx", model: null, local_model_path: null }));

    const combo = await screen.findByRole("combobox", { name: "AI model" });
    await waitFor(() => {
      const notDownloaded = screen.getByRole("option", { name: /LFM2 1\.2B/ }) as HTMLOptionElement;
      expect(notDownloaded.disabled).toBe(true);
    });

    await userEvent.setup().selectOptions(combo, downloaded);

    await waitFor(() => expect(commands.updateSettings).toHaveBeenCalled());
    const saved = lastSavedSettings();
    expect(saved.ai.model).toBe(downloaded);
    expect(saved.ai.local_model_path).toBe(downloaded);
  });

  it("clears a stale chat_model override when picking from the main list on the chat surface", async () => {
    vi.mocked(commands.listRemoteModels).mockResolvedValue([{ id: "gpt-4o-mini", display_name: "GPT-4o mini" }]);
    renderPicker("chat", settingsWith({ provider: "openai", model: "gpt-4-turbo", chat_provider: null, chat_model: "stale-model" }));

    const combo = await screen.findByRole("combobox", { name: "AI model" });
    await screen.findByRole("option", { name: "GPT-4o mini" });
    await userEvent.setup().selectOptions(combo, "gpt-4o-mini");

    await waitFor(() => expect(commands.updateSettings).toHaveBeenCalled());
    const saved = lastSavedSettings();
    expect(saved.ai.model).toBe("gpt-4o-mini");
    expect(saved.ai.chat_model).toBe(null);
  });

  it("is read-only on the chat surface when a chat-only provider override is active", async () => {
    renderPicker("chat", settingsWith({ provider: "openai", chat_provider: "anthropic", chat_model: "claude-3-5-sonnet" }));

    await screen.findByRole("combobox", { name: "AI model" });
    const options = (await screen.findAllByRole("option")) as HTMLOptionElement[];
    expect(options).toHaveLength(2);
    expect(options[0]).toHaveTextContent("claude-3-5-sonnet");
    expect(options[0].disabled).toBe(true);
    expect(options[1]).toHaveTextContent("AI settings…");
    expect(commands.listRemoteModels).not.toHaveBeenCalled();
  });

  it('opens Settings from the "AI settings…" entry without saving anything', async () => {
    vi.mocked(commands.listRemoteModels).mockResolvedValue([{ id: "gpt-4o-mini", display_name: "GPT-4o mini" }]);
    renderPicker("catchup", settingsWith({ provider: "openai", model: "gpt-4-turbo" }));

    const combo = await screen.findByRole("combobox", { name: "AI model" });
    await screen.findByRole("option", { name: "AI settings…" });
    await userEvent.setup().selectOptions(combo, "__settings__");

    expect(useUiStore.getState().showSettings).toBe(true);
    expect(commands.updateSettings).not.toHaveBeenCalled();
  });

  it("renders nothing when the provider is none", async () => {
    const { container } = renderPicker("today", settingsWith({ provider: "none" }));
    await waitFor(() => expect(commands.getSettings).toHaveBeenCalled());
    expect(container).toBeEmptyDOMElement();
  });

  it("keeps the current remote model selectable when the list fails to load", async () => {
    vi.mocked(commands.listRemoteModels).mockRejectedValue(new Error("network down"));
    renderPicker("catchup", settingsWith({ provider: "openai", model: "gpt-4-turbo" }));

    await screen.findByRole("combobox", { name: "AI model" });
    await waitFor(() => expect(commands.listRemoteModels).toHaveBeenCalled());
    const current = await screen.findByRole("option", { name: "gpt-4-turbo" });
    expect((current as HTMLOptionElement).disabled).toBe(false);
  });
});
