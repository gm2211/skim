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
    expect(mlxModelsFor(false)).toEqual(MLX_MODELS);
  });
});

describe("resolveMlxRepoId", () => {
  it("prefers a saved model that is in the available list", () => {
    const repoId = resolveMlxRepoId({ model: "mlx-community/Qwen3-1.7B-4bit", local_model_path: null }, false);
    expect(repoId).toBe("mlx-community/Qwen3-1.7B-4bit");
  });

  it("falls back to the device default when nothing is saved", () => {
    expect(resolveMlxRepoId({ model: null, local_model_path: null }, false)).toBe(
      "mlx-community/Qwen3-4B-Instruct-2507-4bit",
    );
    expect(resolveMlxRepoId({ model: null, local_model_path: null }, true)).toBe(
      "mlx-community/gemma-3-1b-it-4bit",
    );
  });

  it("falls back to the device default when the saved model is not phone-friendly", () => {
    // A desktop-only model was saved, but the device is now a phone.
    const repoId = resolveMlxRepoId({ model: "mlx-community/gemma-3-4b-it-4bit", local_model_path: null }, true);
    expect(repoId).toBe("mlx-community/gemma-3-1b-it-4bit");
  });
});

describe("retired MLX models", () => {
  const smol = "mlx-community/SmolLM3-3B-4bit";

  it("keeps a saved retired model selected and listed", () => {
    expect(resolveMlxRepoId({ model: smol, local_model_path: smol }, false)).toBe(smol);
    expect(mlxModelsFor(false, smol).map((m) => m.repoId)).toContain(smol);
  });

  it("does not offer retired models to new picks", () => {
    expect(mlxModelsFor(false).map((m) => m.repoId)).not.toContain(smol);
  });

  it("falls back on phone when the retired model is not phone-friendly", () => {
    expect(resolveMlxRepoId({ model: smol, local_model_path: null }, true)).toBe(
      "mlx-community/gemma-3-1b-it-4bit",
    );
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
