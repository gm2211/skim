/**
 * GGUF models offered for the embedded llama.cpp provider on desktop.
 *
 * Mirrors the curated MLX tier in aiModels.ts so both local runtimes suggest
 * the same families. Every file is bartowski's Q4_K_M quant.
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

// Sorted ascending by size.
export const LOCAL_MODEL_PRESETS: LocalModelPreset[] = [
  {
    repo: "bartowski/google_gemma-3-1b-it-GGUF",
    file: "google_gemma-3-1b-it-Q4_K_M.gguf",
    name: "Gemma 3 1B",
    sizeGb: 0.8,
    desc: "Fastest. Fine for short summaries on any Mac.",
  },
  {
    repo: "bartowski/Qwen_Qwen3-1.7B-GGUF",
    file: "Qwen_Qwen3-1.7B-Q4_K_M.gguf",
    name: "Qwen3 1.7B",
    sizeGb: 1.3,
    desc: "Still quick, and noticeably better summaries than 1B models.",
  },
  {
    repo: "bartowski/Qwen_Qwen3-4B-Instruct-2507-GGUF",
    file: "Qwen_Qwen3-4B-Instruct-2507-Q4_K_M.gguf",
    name: "Qwen3 4B Instruct",
    sizeGb: 2.5,
    desc: "Best balance of quality and speed for most Macs.",
    recommended: true,
  },
  {
    repo: "bartowski/google_gemma-3-4b-it-GGUF",
    file: "google_gemma-3-4b-it-Q4_K_M.gguf",
    name: "Gemma 3 4B",
    sizeGb: 2.5,
    desc: "Same size as Qwen3 4B with a plainer writing style.",
  },
  {
    repo: "bartowski/Qwen_Qwen3-8B-GGUF",
    file: "Qwen_Qwen3-8B-Q4_K_M.gguf",
    name: "Qwen3 8B",
    sizeGb: 5.0,
    desc: "Sharper triage and catch-up. Best with 16 GB+ memory.",
  },
  {
    repo: "bartowski/Qwen_Qwen3-30B-A3B-GGUF",
    file: "Qwen_Qwen3-30B-A3B-Q4_K_M.gguf",
    name: "Qwen3 30B-A3B",
    sizeGb: 18.6,
    desc: "Best quality, and quick for its size. Needs 32 GB+ memory.",
    minMemoryGb: 32,
  },
];

// Files Skim used to suggest. Not offered any more, but a downloaded copy
// keeps working and is still shown by name.
const RETIRED_LOCAL_MODELS: Pick<LocalModelPreset, "file" | "name">[] = [
  { file: "Llama-3.2-1B-Instruct-Q4_K_M.gguf", name: "Llama 3.2 1B" },
  { file: "google_gemma-4-E2B-it-Q4_K_M.gguf", name: "Gemma 4 E2B" },
  { file: "google_gemma-4-E4B-it-Q4_K_M.gguf", name: "Gemma 4 E4B" },
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
