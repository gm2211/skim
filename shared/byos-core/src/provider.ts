import type { CatalogModel } from './model-catalog.js';
import type { ReasoningEffort } from './effort.js';

/**
 * The contract every provider adapter implements (Codex, Grok, OpenRouter, Groq, Claude...). Types
 * only for now: Motive's adapters move behind it in later PRs.
 *
 * TOKEN RULE: `signIn` may use the site's backend once for the handshake (`handshakeViaSite: true`
 * must be disclosed in the UI). `listModels` and `stream` run in the browser and talk to the
 * provider directly, or through the ciphertext-only relay for providers that need browser TLS.
 */
export type SignInMethod =
  /** OAuth device code: show a code, the user approves on the provider's site. */
  | { kind: 'device-code'; handshakeViaSite: boolean }
  /** OAuth PKCE redirect or popup. */
  | { kind: 'pkce'; handshakeViaSite: boolean }
  /** User pastes a token they generated themselves (CLI or provider console). Never leaves the browser. */
  | { kind: 'paste-token'; hint: string }
  /** User pastes a pay-as-you-go API key. Offered beside a subscription path, never instead of it. */
  | { kind: 'api-key'; hint: string };

export type ProviderAvailability =
  | { available: true }
  /** Shown to the user as-is, e.g. a provider policy pause. */
  | { available: false; reason: string };

export type ChatMessage = { role: 'system' | 'user' | 'assistant'; content: string };

export type ChatRequest = {
  model: string;
  messages: ChatMessage[];
  effort?: ReasoningEffort;
  signal?: AbortSignal;
};

export type ChatEvent =
  | { type: 'text'; text: string }
  | { type: 'reasoning'; text: string }
  | { type: 'usage'; inputTokens?: number; outputTokens?: number; costUsd?: number }
  | { type: 'done' };

export interface ByosProvider {
  id: string;
  displayName: string;
  signIn: SignInMethod[];
  availability(): ProviderAvailability;
  /** Always from the provider; never a hard-coded list. */
  listModels(token: string, signal?: AbortSignal): Promise<CatalogModel[]>;
  stream(token: string, request: ChatRequest): AsyncIterable<ChatEvent>;
}
