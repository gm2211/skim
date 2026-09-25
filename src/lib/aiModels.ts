import type { AiSettings } from "../services/types";

export const AI_PROVIDERS = [
  { value: "none", label: "None", description: "AI features disabled" },
  { value: "local", label: "Local (Embedded)", description: "Run AI locally with llama.cpp — no server needed" },
  { value: "mlx", label: "On-device (MLX)", description: "Run a downloaded MLX model on-device. Offline. iOS/macOS only." },
  { value: "foundation-models", label: "Apple Intelligence", description: "Apple's on-device model. Requires macOS 26+ or iOS 26+ on Apple Intelligence hardware." },
  { value: "ollama", label: "Ollama", description: "Local Ollama (default: localhost:11434)" },
  { value: "claude-subscription", label: "Claude Pro/Max (OAuth)", description: "Sign in with your Claude.ai account — no API key, no CLI. Works on desktop and iOS." },
  { value: "claude-cli", label: "Claude via CLI (legacy)", description: "Uses the local 'claude' CLI binary. Legacy path — prefer 'Claude Pro/Max (OAuth)'." },
  { value: "anthropic", label: "Claude (API Key)", description: "api.anthropic.com — requires API key with usage-based billing" },
  { value: "openai", label: "OpenAI", description: "api.openai.com" },
  { value: "xai", label: "Grok (xAI)", description: "api.x.ai — requires an xAI API key" },
  { value: "ds4", label: "DeepSeek (DS4)", description: "Dedicated local DeepSeek V4 Flash runtime — Mac with 96 GB+ recommended" },
  { value: "openrouter", label: "OpenRouter", description: "openrouter.ai - access multiple models with one API key" },
  { value: "custom", label: "Custom", description: "Any OpenAI-compatible endpoint" },
];

export type MlxModel = { repoId: string; label: string; sizeGb: number; phoneFriendly?: boolean };

// Sorted ascending by size. Every repo id here is either one Skim already
// shipped or one listed in the pinned mlx-swift-examples LLMRegistry, and every
// architecture is one that release's LLMModelFactory can load.
export const MLX_MODELS: MlxModel[] = [
  { repoId: "mlx-community/gemma-3-1b-it-4bit", label: "Gemma 3 1B (iPhone, fastest)", sizeGb: 0.7, phoneFriendly: true },
  { repoId: "mlx-community/LFM2-1.2B-4bit", label: "LFM2 1.2B (iPhone, fast)", sizeGb: 0.7, phoneFriendly: true },
  { repoId: "mlx-community/Qwen3-1.7B-4bit", label: "Qwen3 1.7B (iPhone, best quality)", sizeGb: 1.0, phoneFriendly: true },
  { repoId: "mlx-community/Qwen3-4B-Instruct-2507-4bit", label: "Qwen3 4B Instruct (Mac, recommended)", sizeGb: 2.3 },
  { repoId: "mlx-community/gemma-3-4b-it-4bit", label: "Gemma 3 4B (Mac)", sizeGb: 2.4 },
  { repoId: "mlx-community/Qwen3-8B-4bit", label: "Qwen3 8B (Mac, 16 GB+)", sizeGb: 4.6 },
  { repoId: "mlx-community/Qwen3-30B-A3B-4bit", label: "Qwen3 30B-A3B (Mac, 32 GB+, best quality)", sizeGb: 17.2 },
];

// Models Skim used to offer. Not listed for new picks, but a saved selection
// keeps working (and stays visible in the picker) so nobody is silently moved
// to a different model and made to re-download.
export const RETIRED_MLX_MODELS: MlxModel[] = [
  { repoId: "mlx-community/Llama-3.2-1B-Instruct-4bit", label: "Llama 3.2 1B (retired)", sizeGb: 0.8, phoneFriendly: true },
  { repoId: "mlx-community/SmolLM3-3B-4bit", label: "SmolLM3 3B (retired)", sizeGb: 1.8 },
  { repoId: "mlx-community/Llama-3.2-3B-Instruct-4bit", label: "Llama 3.2 3B (retired)", sizeGb: 1.8 },
  { repoId: "mlx-community/Phi-4-mini-instruct-4bit", label: "Phi-4 Mini (retired)", sizeGb: 2.2 },
  { repoId: "mlx-community/gemma-3n-E2B-it-lm-4bit", label: "Gemma 3n E2B (retired)", sizeGb: 2.6 },
];

/**
 * MLX models offered on this device — phones only see the phone-friendly tier.
 * A retired model stays in the list while it is the saved selection.
 */
export function mlxModelsFor(isPhone: boolean, selectedRepoId?: string | null): MlxModel[] {
  const fits = (m: MlxModel) => !isPhone || !!m.phoneFriendly;
  const models = MLX_MODELS.filter(fits);
  const retired = RETIRED_MLX_MODELS.find((m) => m.repoId === selectedRepoId && fits(m));
  return retired ? [...models, retired] : models;
}

/** The model an MLX picker preselects before the user has chosen one. */
export function defaultMlxModel(isPhone: boolean): MlxModel {
  return isPhone
    ? MLX_MODELS.find((m) => m.phoneFriendly) ?? MLX_MODELS[0]
    : MLX_MODELS.find((m) => m.repoId === "mlx-community/Qwen3-4B-Instruct-2507-4bit") ?? MLX_MODELS[0];
}

/** The MLX repo id saved settings resolve to, falling back to the device default. */
export function resolveMlxRepoId(
  ai: Pick<AiSettings, "model" | "local_model_path">,
  isPhone: boolean,
): string {
  const defaultModel = defaultMlxModel(isPhone);
  const savedRepoId = ai.model ?? ai.local_model_path ?? defaultModel.repoId;
  const models = mlxModelsFor(isPhone, savedRepoId);
  const selectedModel = models.find((m) => m.repoId === savedRepoId) ?? defaultModel;
  return selectedModel.repoId;
}

/** Human-readable label for a provider value, falling back to the raw value. */
export function providerLabel(provider: string): string {
  return AI_PROVIDERS.find((p) => p.value === provider)?.label ?? provider;
}

/** Providers whose models are looked up via the `list_remote_models` command. */
export const REMOTE_LIST_PROVIDERS = ["openai", "xai", "openrouter", "anthropic", "custom"] as const;

/** Whether chat has its own provider override distinct from the main AI provider. */
export function hasChatOverride(ai: Pick<AiSettings, "chat_provider">): boolean {
  return !!ai.chat_provider && ai.chat_provider !== "same";
}

/**
 * The settings patch to apply when the user picks model `id` under `provider`.
 * Model meaning differs per provider: MLX stores the repo id in both `model`
 * and `local_model_path`; local (llama.cpp) only cares about the file path;
 * everything else keyed by `ai.model` alone.
 */
export function modelPatch(provider: string, id: string): Partial<AiSettings> {
  if (provider === "mlx") return { model: id, local_model_path: id };
  if (provider === "local") return { local_model_path: id };
  return { model: id || null };
}
