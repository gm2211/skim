import type { ReactNode } from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { act, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useSelectModel, useSettings, useUpdateSettings } from "./useSettings";
import * as commands from "../services/commands";
import type { AppSettings } from "../services/types";

vi.mock("../services/commands", () => ({
  getSettings: vi.fn(),
  updateSettings: vi.fn(),
}));

const BASE_SETTINGS: AppSettings = {
  ai: {
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
  },
  appearance: { theme: "dark", font_size: 14, show_excerpt_in_list: false },
  sync: { refresh_interval_minutes: 30, max_articles_per_feed: 200, recent_cap: 3000, today_story_limit: 10 },
};

function wrapperFor(qc: QueryClient) {
  return function Wrapper({ children }: { children: ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>;
  };
}

beforeEach(() => {
  vi.clearAllMocks();
});

describe("useUpdateSettings", () => {
  it("applies the update optimistically, then rolls back when the save fails", async () => {
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    qc.setQueryData(["settings"], BASE_SETTINGS);
    vi.mocked(commands.updateSettings).mockRejectedValue(new Error("network down"));

    const { result } = renderHook(() => useUpdateSettings(), { wrapper: wrapperFor(qc) });
    const next: AppSettings = { ...BASE_SETTINGS, ai: { ...BASE_SETTINGS.ai, model: "gpt-4o-mini" } };

    await act(async () => {
      await result.current.mutateAsync(next).catch(() => {});
    });

    expect(qc.getQueryData(["settings"])).toEqual(BASE_SETTINGS);
  });

  it("keeps the optimistic value once the save succeeds", async () => {
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    qc.setQueryData(["settings"], BASE_SETTINGS);
    vi.mocked(commands.updateSettings).mockResolvedValue(undefined);
    vi.mocked(commands.getSettings).mockResolvedValue(BASE_SETTINGS);

    const { result } = renderHook(() => useUpdateSettings(), { wrapper: wrapperFor(qc) });
    const next: AppSettings = { ...BASE_SETTINGS, ai: { ...BASE_SETTINGS.ai, model: "gpt-4o-mini" } };

    await act(async () => {
      await result.current.mutateAsync(next);
    });

    expect((qc.getQueryData(["settings"]) as AppSettings).ai.model).toBe("gpt-4o-mini");
  });
});

describe("useSelectModel", () => {
  it("merges a model patch into the current settings and saves the whole blob", async () => {
    const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } });
    qc.setQueryData(["settings"], BASE_SETTINGS);
    vi.mocked(commands.updateSettings).mockResolvedValue(undefined);
    vi.mocked(commands.getSettings).mockResolvedValue(BASE_SETTINGS);

    const { result } = renderHook(
      () => ({ settings: useSettings(), selectModel: useSelectModel() }),
      { wrapper: wrapperFor(qc) },
    );
    await waitFor(() => expect(result.current.settings.data).toEqual(BASE_SETTINGS));

    await act(async () => {
      await result.current.selectModel({ model: "gpt-4o-mini" });
    });

    expect(commands.updateSettings).toHaveBeenCalledWith(
      expect.objectContaining({ ai: expect.objectContaining({ model: "gpt-4o-mini", provider: "openai" }) }),
    );
  });
});
