import type { CloudEndpoint } from './endpoints.js';
import { PROVIDER_BASE_URLS } from './endpoints.js';
import { safeProviderErrorText } from './chat.js';

export type OpenRouterKeyInfo = {
  label?: string;
  usage?: number;
  limit?: number | null;
};

/** A model as the picker lists it. */
export type ProviderModel = {
  id: string;
  name: string;
  analysisFit: 'recommended' | 'balanced' | 'lightweight' | 'standard';
  /** USD per million tokens, from OpenRouter's per-token pricing. Undefined when no usable price. */
  promptPerMillion?: number;
  completionPerMillion?: number;
  contextLength?: number;
  /** Whether the model accepts a reasoning effort at request time (from supported_parameters). */
  reasoning: boolean;
};
/** Motive's historical name for ProviderModel. */
export type OpenRouterModel = ProviderModel;

export class OpenRouterAuthenticationError extends Error {
  constructor() {
    super('OpenRouter rejected this key. Reconnect your OpenRouter account.');
    this.name = 'OpenRouterAuthenticationError';
  }
}

function rejectInvalidCredential(status: number): void {
  if (status === 401 || status === 403) throw new OpenRouterAuthenticationError();
}

const API_ROOT = PROVIDER_BASE_URLS.openrouter;

/** OpenRouter quotes prices per token as strings ("0.000001"). Anything non-numeric or negative is
 * treated as "no usable price" rather than shown as $0, which would read as free. */
function perMillion(value: unknown): number | undefined {
  const perToken = typeof value === 'string' ? Number(value) : typeof value === 'number' ? value : NaN;
  return Number.isFinite(perToken) && perToken >= 0 ? perToken * 1_000_000 : undefined;
}

function analysisFit(id: string, name: string): OpenRouterModel['analysisFit'] {
  const value = `${id} ${name}`.toLowerCase();
  if (/gpt-5\.[2-9]|claude.*(?:opus|sonnet).*4|gemini.*(?:3|3\.1).*pro|grok-4|sonar-pro|deep-research/.test(value)) return 'recommended';
  if (/gpt-5|claude.*sonnet|gemini.*flash(?!.*lite)|o3|o4-mini|sonar/.test(value)) return 'balanced';
  if (/lite|nano|haiku|flash-lite|\bfree\b/.test(value)) return 'lightweight';
  return 'standard';
}

function fitRank(fit: OpenRouterModel['analysisFit']): number {
  return { recommended: 0, balanced: 1, standard: 2, lightweight: 3 }[fit];
}

export async function readOpenRouterKeyInfo(key: string, signal?: AbortSignal): Promise<OpenRouterKeyInfo> {
  const response = await fetch(`${API_ROOT}/key`, { signal, redirect: 'error', headers: { Authorization: `Bearer ${key}` } });
  rejectInvalidCredential(response.status);
  const payload = await response.json().catch(() => ({})) as { data?: OpenRouterKeyInfo; error?: { message?: string } };
  if (!response.ok) throw new Error(safeProviderErrorText(payload, key) || 'OpenRouter rejected this key.');
  return payload.data ?? {};
}

export async function listOpenRouterModels(key: string, signal?: AbortSignal): Promise<OpenRouterModel[]> {
  const response = await fetch(`${API_ROOT}/models`, { signal, redirect: 'error', headers: { Authorization: `Bearer ${key}` } });
  rejectInvalidCredential(response.status);
  const payload = await response.json().catch(() => ({})) as {
    data?: Array<{
      id?: string;
      name?: string;
      supported_parameters?: string[];
      context_length?: number;
      pricing?: { prompt?: string | number; completion?: string | number };
    }>;
    error?: { message?: string };
  };
  if (!response.ok) throw new Error(safeProviderErrorText(payload, key) || 'Could not load OpenRouter models.');
  return (payload.data ?? [])
    .filter(model => model.id && model.supported_parameters?.includes('tools'))
    .map(model => {
      const name = model.name || model.id!;
      return {
        id: model.id!,
        name,
        analysisFit: analysisFit(model.id!, name),
        promptPerMillion: perMillion(model.pricing?.prompt),
        completionPerMillion: perMillion(model.pricing?.completion),
        contextLength: typeof model.context_length === 'number' && model.context_length > 0 ? model.context_length : undefined,
        reasoning: Boolean(model.supported_parameters?.includes('reasoning')),
      };
    })
    .sort((a, b) => fitRank(a.analysisFit) - fitRank(b.analysisFit) || a.name.localeCompare(b.name));
}

/**
 * listOpenRouterModels' sibling for xAI and Groq: the same `GET {baseUrl}/models` OpenAI-compatible
 * route every browser-direct endpoint answers (see endpoints.ts). Deliberately simpler than
 * listOpenRouterModels above rather than sharing its body: xAI/Groq's `/models` responses carry
 * neither OpenRouter's `supported_parameters` (so there is nothing to filter "tools support" or
 * "reasoning" on) nor its per-token `pricing` block, so guessing either would just be fabricating a
 * number this response never sent. Every model that answers with an id is kept and sorted by name;
 * `analysisFit` stays 'standard' across the board rather than reusing OpenRouter's name-sniffing
 * heuristic, which was tuned against OpenRouter's own model-name conventions (e.g. "sonar-pro") that
 * do not apply to xAI's or Groq's catalog.
 */
export async function listModelsForEndpoint(endpoint: CloudEndpoint, signal?: AbortSignal): Promise<OpenRouterModel[]> {
  const response = await fetch(`${endpoint.baseUrl}/models`, { signal, redirect: 'error', headers: { Authorization: `Bearer ${endpoint.apiKey}`, ...endpoint.headers } });
  const payload = await response.json().catch(() => ({})) as {
    data?: Array<{ id?: string; name?: string }>;
    error?: { message?: string };
  };
  if (!response.ok) throw new Error(safeProviderErrorText(payload, endpoint.apiKey) || 'Could not load models.');
  return (payload.data ?? [])
    .filter((model): model is { id: string; name?: string } => Boolean(model.id))
    .map(model => ({ id: model.id, name: model.name || model.id, analysisFit: 'standard' as const, reasoning: false }))
    .sort((a, b) => a.name.localeCompare(b.name));
}
