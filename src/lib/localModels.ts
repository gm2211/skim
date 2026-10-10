/**
 * GGUF models offered for the embedded llama.cpp provider on desktop.
 *
 * Every file is bartowski's Q4_K_M quant. The MLX catalog in aiModels.ts
 * uses the same small families through the shared Swift inference engine.
 */
export type LocalModelPreset = {
  repo: string;
  file: string;
  name: string;
  sizeGb: number;
  desc: string;
  recommended?: boolean;
  /** Hidden below this much unified memory. */
  minMemoryGb?: number;
};

// Sorted by download size. The bundled llama.cpp supports the qwen35,
// qwen35moe and gemma4 text architectures. Download size is not peak RAM.
export const LOCAL_MODEL_PRESETS: LocalModelPreset[] = [
  {
    repo: "bartowski/Qwen_Qwen3.5-2B-GGUF",
    file: "Qwen_Qwen3.5-2B-Q4_K_M.gguf",
    name: "Qwen3.5 2B",
    sizeGb: 1.4,
    desc: "Compact option for short summaries.",
  },
  {
    repo: "bartowski/Qwen_Qwen3.5-4B-GGUF",
    file: "Qwen_Qwen3.5-4B-Q4_K_M.gguf",
    name: "Qwen3.5 4B",
    sizeGb: 3.0,
    desc: "Recommended starting point for most Macs.",
    recommended: true,
  },
  {
    repo: "bartowski/google_gemma-4-E4B-it-GGUF",
    file: "google_gemma-4-E4B-it-Q4_K_M.gguf",
    name: "Gemma 4 E4B",
    sizeGb: 5.4,
    desc: "Google's alternative small model. Needs 16 GB+ memory.",
    minMemoryGb: 16,
  },
  {
    repo: "bartowski/Qwen_Qwen3.5-9B-GGUF",
    file: "Qwen_Qwen3.5-9B-Q4_K_M.gguf",
    name: "Qwen3.5 9B",
    sizeGb: 6.2,
    desc: "Larger option for triage and catch-up. 24 GB+ memory preferred.",
    minMemoryGb: 16,
  },
  {
    repo: "bartowski/Qwen3.8-27B-GGUF",
    file: "Qwen3.8-27B-Q4_K_M.gguf",
    name: "Qwen3.8 27B",
    sizeGb: 17.4,
    desc: "Large dense model. Needs 48 GB+ memory.",
    minMemoryGb: 48,
  },
  {
    repo: "bartowski/Qwen_Qwen3.6-35B-A3B-GGUF",
    file: "Qwen_Qwen3.6-35B-A3B-Q4_K_M.gguf",
    name: "Qwen3.6 35B-A3B",
    sizeGb: 22.3,
    desc: "Large mixture-of-experts model. Needs 48 GB+ memory.",
    minMemoryGb: 48,
  },
];

// Files Skim used to suggest. Not offered any more, but a downloaded copy
// keeps working and is still shown by name.
const RETIRED_LOCAL_MODELS: Pick<LocalModelPreset, "file" | "name">[] = [
  { file: "Qwen_Qwen3.5-35B-A3B-Q4_K_M.gguf", name: "Qwen3.5 35B-A3B" },
  { file: "google_gemma-3-1b-it-Q4_K_M.gguf", name: "Gemma 3 1B" },
  { file: "Qwen_Qwen3-1.7B-Q4_K_M.gguf", name: "Qwen3 1.7B" },
  { file: "Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf", name: "Qwen3 4B Instruct" },
  { file: "google_gemma-3-4b-it-Q4_K_M.gguf", name: "Gemma 3 4B" },
  { file: "Qwen_Qwen3-8B-Q4_K_M.gguf", name: "Qwen3 8B" },
  { file: "Qwen_Qwen3-30B-A3B-Q4_K_M.gguf", name: "Qwen3 30B-A3B" },
  { file: "Llama-3.2-1B-Instruct-Q4_K_M.gguf", name: "Llama 3.2 1B" },
  { file: "google_gemma-4-E2B-it-Q4_K_M.gguf", name: "Gemma 4 E2B" },
  { file: "Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf", name: "Llama 3.1 8B" },
  { file: "Qwen_Qwen3-32B-Q4_K_M.gguf", name: "Qwen3 32B" },
];

/** Presets that fit a machine with `memoryGb` of RAM (all but the gated ones when unknown). */
export function localModelPresetsFor(memoryGb: number | undefined): LocalModelPreset[] {
  return LOCAL_MODEL_PRESETS.filter((m) => !m.minMemoryGb || (memoryGb ?? 0) >= m.minMemoryGb - 0.5);
}

const QUANT_SUFFIX = /[-_.]((?:I?Q\d[A-Z0-9_]*)|B?F16|F32)$/i;
const ORG_PREFIX = /^(google|qwen|meta|microsoft|mistralai|nvidia|ibm|deepseek-ai|lfm2?)_/i;
const NOISE_WORDS = new Set(["it", "gguf"]);

/**
 * A readable name for a GGUF file plus its quantization, e.g.
 * "google_gemma-4-E2B-it-Q4_K_M.gguf" → { name: "Gemma 4 E2B", quant: "Q4_K_M" }.
 */
export function friendlyModelName(filename: string): { name: string; quant: string | null } {
  const base = filename.split("/").pop() ?? filename;
  const stem = base.replace(/\.gguf$/i, "");
  const quantMatch = stem.match(QUANT_SUFFIX);
  const quant = quantMatch ? quantMatch[1].toUpperCase() : null;

  const known =
    LOCAL_MODEL_PRESETS.find((m) => m.file === base) ?? RETIRED_LOCAL_MODELS.find((m) => m.file === base);
  if (known) return { name: known.name, quant };

  const words = (quantMatch ? stem.slice(0, quantMatch.index) : stem)
    .replace(ORG_PREFIX, "")
    .split(/[-_\s]+/)
    .filter((w) => w && !NOISE_WORDS.has(w.toLowerCase()))
    .map((w) => (/^[a-z]/.test(w) ? w[0].toUpperCase() + w.slice(1) : w));
  return { name: words.join(" ") || base, quant };
}
