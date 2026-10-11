import type { ByosProvider, CatalogModel, ChatEvent, ChatRequest, ReasoningEffort } from '@byos/core';
import { ProviderRequestError, safeProviderErrorText } from './chat.js';
import { iterateSseEvents } from './sse.js';

/**
 * Claude (Anthropic) adapter. Browser-direct to api.anthropic.com with the user's API key.
 *
 * SUBSCRIPTIONS ARE PAUSED. Anthropic's terms (https://code.claude.com/docs/en/legal-and-compliance,
 * "Authentication and credential use") do not permit third-party apps to offer Claude.ai login or to
 * route requests through Free/Pro/Max plan credentials. So this adapter offers an API key only and
 * treats a subscription (OAuth) token as unusable while `subscriptionsPaused` is true. Pass `false`
 * only if that policy changes.
 *
 * TOKEN RULE: the key goes only to api.anthropic.com, from the browser.
 */
export const ANTHROPIC_POLICY_URL = 'https://code.claude.com/docs/en/legal-and-compliance';
export const CLAUDE_SUBSCRIPTIONS_PAUSED_NOTE = 'Claude subscriptions are momentarily unavailable because of Anthropic’s policy. Use an API key, or pick another service.';

const API = 'https://api.anthropic.com/v1';
const ANTHROPIC_VERSION = '2023-06-01';
const EFFORT_ORDER: ReasoningEffort[] = ['low', 'medium', 'high', 'xhigh', 'max'];
const MAX_PAGES = 5;

/** Anything that is not an `sk-ant-api…` key is a subscription (OAuth) credential. */
export function isClaudeSubscriptionCredential(raw: string): boolean {
  const token = raw.trim();
  return Boolean(token) && !(token.startsWith('sk-ant-') && !token.startsWith('sk-ant-oat'));
}

export function claudeCredentialAllowed(raw: string, subscriptionsPaused = true): boolean {
  return !(subscriptionsPaused && isClaudeSubscriptionCredential(raw));
}

function headers(key: string, json: boolean): Record<string, string> {
  return {
    'x-api-key': key,
    'anthropic-version': ANTHROPIC_VERSION,
    // Anthropic requires this opt-in for calls made straight from a browser page.
    'anthropic-dangerous-direct-browser-access': 'true',
    ...(json ? { 'content-type': 'application/json' } : {}),
  };
}

type AnthropicModelRow = {
  id?: unknown;
  display_name?: unknown;
  capabilities?: { effort?: Record<string, unknown> & { supported?: unknown } };
};

/** One page of GET /v1/models to picker rows, with each model's supported effort levels. */
export function parseAnthropicModels(rows: unknown): CatalogModel[] {
  if (!Array.isArray(rows)) return [];
  const models: CatalogModel[] = [];
  for (const raw of rows as AnthropicModelRow[]) {
    if (!raw || typeof raw.id !== 'string' || !raw.id.trim() || /\s/.test(raw.id)) continue;
    const effort = raw.capabilities?.effort;
    const efforts = effort && effort.supported === true
      ? EFFORT_ORDER.filter(level => (effort[level] as { supported?: unknown } | undefined)?.supported === true)
      : [];
    models.push({
      id: raw.id,
      name: typeof raw.display_name === 'string' && raw.display_name.trim() ? raw.display_name : raw.id,
      ...(efforts.length ? { reasoningEfforts: efforts.map(level => ({ effort: level })) } : {}),
    });
  }
  return models;
}

function requireKey(key: string, paused: boolean): void {
  if (!claudeCredentialAllowed(key, paused)) throw new ProviderRequestError(CLAUDE_SUBSCRIPTIONS_PAUSED_NOTE, 403);
}

export async function listClaudeModels(key: string, signal?: AbortSignal, subscriptionsPaused = true): Promise<CatalogModel[]> {
  requireKey(key, subscriptionsPaused);
  const models: CatalogModel[] = [];
  let after = '';
  for (let page = 0; page < MAX_PAGES; page += 1) {
    const response = await fetch(`${API}/models?limit=100${after ? `&after_id=${encodeURIComponent(after)}` : ''}`, { headers: headers(key, false), signal, redirect: 'error' });
    const payload = await response.json().catch(() => ({})) as { data?: unknown; has_more?: unknown; last_id?: unknown };
    if (!response.ok) throw new ProviderRequestError(safeProviderErrorText(payload, key) ?? `Claude model list failed (${response.status}).`, response.status);
    models.push(...parseAnthropicModels(payload.data));
    if (payload.has_more !== true || typeof payload.last_id !== 'string') break;
    after = payload.last_id;
  }
  return models;
}

/** Streams POST /v1/messages as ChatEvents. System messages become the top-level `system`. */
export async function* streamClaude(key: string, request: ChatRequest, subscriptionsPaused = true): AsyncGenerator<ChatEvent> {
  requireKey(key, subscriptionsPaused);
  const system = request.messages.filter(message => message.role === 'system').map(message => message.content).join('\n\n');
  const response = await fetch(`${API}/messages`, {
    method: 'POST',
    signal: request.signal,
    redirect: 'error',
    headers: headers(key, true),
    body: JSON.stringify({
      model: request.model,
      max_tokens: 16_000,
      stream: true,
      ...(system ? { system } : {}),
      messages: request.messages.filter(message => message.role !== 'system').map(({ role, content }) => ({ role, content })),
      // Effort only when chosen and listed for the model; some models reject the field outright.
      ...(request.effort ? { thinking: { type: 'adaptive' }, output_config: { effort: request.effort } } : {}),
    }),
  });
  if (!response.ok || !response.body) {
    const payload = await response.json().catch(() => undefined);
    throw new ProviderRequestError(safeProviderErrorText(payload, key) ?? `Claude answered ${response.status}.`, response.status);
  }
  let inputTokens: number | undefined;
  const reader = response.body.getReader();
  try {
    for await (const event of iterateSseEvents(reader)) {
      if (event.type !== 'data') continue;
      let data: { type?: string; delta?: { type?: string; text?: unknown; thinking?: unknown }; message?: { usage?: { input_tokens?: unknown } }; usage?: { output_tokens?: unknown }; error?: unknown };
      try { data = JSON.parse(event.data); } catch { continue; }
      if (data.type === 'error') throw new ProviderRequestError(safeProviderErrorText(data, key) ?? 'Claude stopped with an error.', 200);
      if (data.type === 'message_start' && typeof data.message?.usage?.input_tokens === 'number') inputTokens = data.message.usage.input_tokens;
      if (data.type === 'content_block_delta') {
        if (data.delta?.type === 'text_delta' && typeof data.delta.text === 'string') yield { type: 'text', text: data.delta.text };
        if (data.delta?.type === 'thinking_delta' && typeof data.delta.thinking === 'string') yield { type: 'reasoning', text: data.delta.thinking };
      }
      if (data.type === 'message_delta' && typeof data.usage?.output_tokens === 'number') {
        yield { type: 'usage', inputTokens, outputTokens: data.usage.output_tokens };
      }
    }
  } finally {
    await reader.cancel().catch(() => undefined);
    try { reader.releaseLock(); } catch { /* A pending read releases it when settled. */ }
  }
  yield { type: 'done' };
}

export function claude(options: { subscriptionsPaused?: boolean } = {}): ByosProvider {
  const paused = options.subscriptionsPaused ?? true;
  return {
    id: 'claude',
    displayName: 'Claude',
    signIn: [{ kind: 'api-key', hint: 'An Anthropic API key from console.anthropic.com' }],
    // API keys work; the note tells users why there is no subscription button.
    availability: () => ({ available: true }),
    listModels: (token, signal) => listClaudeModels(token, signal, paused),
    stream: (token, request) => streamClaude(token, request, paused),
  };
}
