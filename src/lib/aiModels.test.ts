import { describe, expect, it } from "vitest";
import {
  MLX_MODELS,
  hasChatOverride,
  mlxModelsFor,
  modelPatch,
  resolveMlxRepoId,
} from "./aiModels";

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
