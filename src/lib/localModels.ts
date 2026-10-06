/**
 * GGUF models offered for the embedded llama.cpp provider on desktop.
 *
 * Every file is bartowski's Q4_K_M quant. The MLX tier in aiModels.ts stays on
 * Qwen3/Gemma 3 until the Swift MLX library can load the newer architectures.
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

// Sorted ascending by size. Qwen 3.5 (Feb 2026) and Gemma 4 (Mar 2026) are
// the current small open families; the bundled llama.cpp loads both
// (`qwen35`, `qwen35moe`, `gemma4` architectures).
export const LOCAL_MODEL_PRESETS: LocalModelPreset[] = [
  {
    repo: "bartowski/Qwen_Qwen3.5-2B-GGUF",
    file: "Qwen_Qwen3.5-2B-Q4_K_M.gguf",
    name: "Qwen3.5 2B",
    sizeGb: 1.4,
    desc: "Fastest. Fine for short summaries on any Mac.",
  },
  {
    repo: "bartowski/Qwen_Qwen3.5-4B-GGUF",
    file: "Qwen_Qwen3.5-4B-Q4_K_M.gguf",
    name: "Qwen3.5 4B",
    sizeGb: 3.0,
    desc: "Best balance of quality and speed for most Macs.",
    recommended: true,
  },
  {
    repo: "bartowski/google_gemma-4-E4B-it-GGUF",
    file: "google_gemma-4-E4B-it-Q4_K_M.gguf",
    name: "Gemma 4 E4B",
    sizeGb: 5.4,
    desc: "Google's small model, with a plainer writing style.",
  },
  {
    repo: "bartowski/Qwen_Qwen3.5-9B-GGUF",
    file: "Qwen_Qwen3.5-9B-Q4_K_M.gguf",
    name: "Qwen3.5 9B",
    sizeGb: 6.2,
    desc: "Sharper triage and catch-up. Best with 16 GB+ memory.",
  },
  {
    repo: "bartowski/Qwen_Qwen3.5-35B-A3B-GGUF",
    file: "Qwen_Qwen3.5-35B-A3B-Q4_K_M.gguf",
    name: "Qwen3.5 35B-A3B",
    sizeGb: 22.3,
    desc: "Best quality, and quick for its size. Needs 32 GB+ memory.",
    minMemoryGb: 32,
  },
];

// Files Skim used to suggest. Not offered any more, but a downloaded copy
// keeps working and is still shown by name.
const RETIRED_LOCAL_MODELS: Pick<LocalModelPreset, "file" | "name">[] = [
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
  return LOCAL_MODEL_PRESETS.filter((m) => !m.minMemoryGb || (memoryGb ?? 0) >= m.minMemoryGb);
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
