import { describe, expect, it } from "vitest";
import { friendlyModelName, localModelPresetsFor, LOCAL_MODEL_PRESETS } from "./localModels";

describe("friendlyModelName", () => {
  it("names curated and retired downloads", () => {
    expect(friendlyModelName("google_gemma-4-E2B-it-Q4_K_M.gguf")).toEqual({ name: "Gemma 4 E2B", quant: "Q4_K_M" });
    expect(friendlyModelName("Qwen_Qwen3.5-4B-Q4_K_M.gguf")).toEqual({ name: "Qwen3.5 4B", quant: "Q4_K_M" });
    expect(friendlyModelName("/models/Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf")).toEqual({
      name: "Qwen3 4B Instruct",
      quant: "Q4_K_M",
    });
  });

  it("derives a readable name for files it has never seen", () => {
    expect(friendlyModelName("microsoft_Phi-4-mini-instruct-Q5_K_M.gguf")).toEqual({
      name: "Phi 4 Mini Instruct",
      quant: "Q5_K_M",
    });
    expect(friendlyModelName("mistral-7b-instruct-v0.2.IQ4_XS.gguf")).toEqual({
      name: "Mistral 7b Instruct V0.2",
      quant: "IQ4_XS",
    });
    expect(friendlyModelName("custom.gguf")).toEqual({ name: "Custom", quant: null });
  });
});

describe("localModelPresetsFor", () => {
  it("hides the 35B model below 32 GB and when memory is unknown", () => {
    expect(localModelPresetsFor(16).map((m) => m.name)).not.toContain("Qwen3.5 35B-A3B");
    expect(localModelPresetsFor(undefined).map((m) => m.name)).not.toContain("Qwen3.5 35B-A3B");
    expect(localModelPresetsFor(64)).toHaveLength(LOCAL_MODEL_PRESETS.length);
  });

  it("recommends exactly one model", () => {
    expect(LOCAL_MODEL_PRESETS.filter((m) => m.recommended).map((m) => m.name)).toEqual(["Qwen3.5 4B"]);
  });

  it("follows bartowski's file naming for every preset", () => {
    for (const m of LOCAL_MODEL_PRESETS) {
      expect(m.file).toBe(`${m.repo.split("/")[1].replace(/-GGUF$/, "")}-Q4_K_M.gguf`);
    }
  });
});
