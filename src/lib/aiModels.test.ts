import { describe, expect, it } from "vitest";
import {
  MLX_MODELS,
  RETIRED_MLX_MODELS,
  hasChatOverride,
  mlxModelsFor,
  modelPatch,
  resolveMlxRepoId,
  switchProvider,
} from "./aiModels";
import type { AiSettings } from "../services/types";

describe("modelPatch", () => {
  it("mlx sets both model and local_model_path to the repo id", () => {
    expect(modelPatch("mlx", "mlx-community/gemma-3-1b-it-4bit")).toEqual({
      model: "mlx-community/gemma-3-1b-it-4bit",
      local_model_path: "mlx-community/gemma-3-1b-it-4bit",
    });
  });

  it("local (llama.cpp) sets only local_model_path", () => {
    expect(modelPatch("local", "/models/llama.gguf")).toEqual({
      local_model_path: "/models/llama.gguf",
    });
  });

  it("remote providers set only model", () => {
    expect(modelPatch("openai", "gpt-4o-mini")).toEqual({ model: "gpt-4o-mini" });
    expect(modelPatch("anthropic", "")).toEqual({ model: null });
  });
});

describe("mlxModelsFor", () => {
  it("returns only phone-friendly models on phone", () => {
    const phoneModels = mlxModelsFor(true);
    expect(phoneModels.length).toBeGreaterThan(0);
    expect(phoneModels.every((m) => m.phoneFriendly)).toBe(true);
  });

  it("returns the full catalog off phone", () => {
    expect(mlxModelsFor(false, undefined, 64)).toEqual(MLX_MODELS);
  });

  it("hides memory-gated choices when memory is unknown and reveals them at their minimum", () => {
    const ids = (memory?: number) => mlxModelsFor(false, undefined, memory).map((m) => m.repoId);
    expect(ids()).not.toContain("mlx-community/Qwen3.5-9B-4bit");
    expect(ids()).not.toContain("mlx-community/Qwen3.8-27B-4bit");
    expect(ids(16)).toContain("mlx-community/Qwen3.5-9B-4bit");
    expect(ids(16)).not.toContain("mlx-community/Qwen3.8-27B-4bit");
    expect(ids(48)).toContain("mlx-community/Qwen3.8-27B-4bit");
  });

  it("allows the rounded 11.5 GB report for nominal 12 GB devices", () => {
    expect(mlxModelsFor(true, undefined, 11.5).map((m) => m.repoId)).toContain("mlx-community/Qwen3.5-4B-4bit");
    expect(mlxModelsFor(false, undefined, 11.5).map((m) => m.repoId)).toContain("mlx-community/gemma-4-e2b-it-4bit");
    expect(mlxModelsFor(true, undefined, 11.4).map((m) => m.repoId)).not.toContain("mlx-community/Qwen3.5-4B-4bit");
  });

  it("retains a selected model when device filtering or memory gating would otherwise hide it", () => {
    expect(mlxModelsFor(false, "mlx-community/Qwen3.5-9B-4bit").map((m) => m.repoId)).toContain(
      "mlx-community/Qwen3.5-9B-4bit",
    );
    expect(mlxModelsFor(true, "mlx-community/Qwen3-4B-Instruct-2507-4bit").map((m) => m.repoId)).toContain(
      "mlx-community/Qwen3-4B-Instruct-2507-4bit",
    );
  });
});

describe("resolveMlxRepoId", () => {
  it("prefers a saved model that is in the available list", () => {
    const repoId = resolveMlxRepoId({ model: "mlx-community/Qwen3-1.7B-4bit", local_model_path: null }, false);
    expect(repoId).toBe("mlx-community/Qwen3-1.7B-4bit");
  });

  it("falls back to the device default when nothing is saved", () => {
    expect(resolveMlxRepoId({ model: null, local_model_path: null }, false)).toBe(
      "mlx-community/Qwen3.5-4B-4bit",
    );
    expect(resolveMlxRepoId({ model: null, local_model_path: null }, true)).toBe(
      "mlx-community/LFM2.5-1.2B-Instruct-4bit",
    );
  });

  it("preserves an explicitly saved model when it is not phone-friendly", () => {
    // A desktop-only model was saved, but the device is now a phone.
    const repoId = resolveMlxRepoId({ model: "mlx-community/gemma-4-e2b-it-4bit", local_model_path: null }, true);
    expect(repoId).toBe("mlx-community/gemma-4-e2b-it-4bit");
  });
});

describe("custom MLX selections", () => {
  it("preserves a saved repository outside the preset catalog", () => {
    const saved = "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit";
    expect(resolveMlxRepoId({ model: saved, local_model_path: null }, false)).toBe(saved);
    expect(mlxModelsFor(false, saved).map((m) => m.repoId)).toContain(saved);
  });

  it("matches native precedence and rejects leaked cloud model names", () => {
    expect(resolveMlxRepoId({ model: "claude-sonnet-5", local_model_path: "mlx-community/Qwen3-1.7B-4bit" }, true)).toBe("mlx-community/Qwen3-1.7B-4bit");
    expect(resolveMlxRepoId({ model: "claude-sonnet-5", local_model_path: null }, true)).toBe("mlx-community/LFM2.5-1.2B-Instruct-4bit");
  });
});

describe("retired MLX models", () => {
  const oldQwen = "mlx-community/Qwen3-4B-Instruct-2507-4bit";

  it("keeps a saved retired model selected and listed", () => {
    expect(resolveMlxRepoId({ model: oldQwen, local_model_path: oldQwen }, false)).toBe(oldQwen);
    expect(mlxModelsFor(false, oldQwen).map((m) => m.repoId)).toContain(oldQwen);
  });

  it("does not offer retired models to new picks", () => {
    expect(mlxModelsFor(false, undefined, 64).map((m) => m.repoId)).not.toContain(oldQwen);
  });

  it("preserves retired phone and Mac Qwen3 selections", () => {
    for (const repoId of ["mlx-community/Qwen3-1.7B-4bit", oldQwen, "mlx-community/Qwen3-8B-4bit", "mlx-community/Qwen3-30B-A3B-4bit"]) {
      expect(resolveMlxRepoId({ model: repoId, local_model_path: null }, true)).toBe(repoId);
      expect(mlxModelsFor(true, repoId).map((m) => m.repoId)).toContain(repoId);
    }
  });

  it("never overlaps the live catalog", () => {
    const live = new Set(MLX_MODELS.map((m) => m.repoId));
    expect(RETIRED_MLX_MODELS.some((m) => live.has(m.repoId))).toBe(false);
  });
});

describe("hasChatOverride", () => {
  it("is false when chat_provider is null, empty, or 'same'", () => {
    expect(hasChatOverride({ chat_provider: null })).toBe(false);
    expect(hasChatOverride({ chat_provider: "" })).toBe(false);
    expect(hasChatOverride({ chat_provider: "same" })).toBe(false);
  });

  it("is true for a distinct chat provider", () => {
    expect(hasChatOverride({ chat_provider: "openai" })).toBe(true);
  });
});

describe("switchProvider", () => {
  const anthropic = {
    provider: "anthropic",
    api_key: "sk-ant-1",
    endpoint: null,
    model: "claude-sonnet-5",
    local_model_path: null,
  } as AiSettings;

  it("keeps a cloud key through a trip to a local model and back", () => {
    const local = switchProvider(anthropic, "local");
    expect(local.api_key).toBeNull();
    expect(local.model).toBeNull();
    const withModel = { ...local, local_model_path: "/models/qwen.gguf" };
    const back = switchProvider(withModel, "anthropic");
    expect(back.api_key).toBe("sk-ant-1");
    expect(back.model).toBe("claude-sonnet-5");
    expect(back.local_model_path).toBeNull();
    expect(switchProvider(back, "local").local_model_path).toBe("/models/qwen.gguf");
  });

  it("never hands one provider's key to another", () => {
    const openai = switchProvider(anthropic, "openai");
    expect(openai.api_key).toBeNull();
    const withKey = { ...openai, api_key: "sk-openai" };
    expect(switchProvider(withKey, "anthropic").api_key).toBe("sk-ant-1");
    expect(switchProvider(switchProvider(withKey, "anthropic"), "openai").api_key).toBe("sk-openai");
  });

  it("does not file the active provider's values under provider_credentials", () => {
    const back = switchProvider(switchProvider(anthropic, "local"), "anthropic");
    expect(back.provider_credentials).toEqual({});
  });
});
