import type { ChatEvent, ChatRequest } from '@byos/core';
import type { CloudEndpoint } from './endpoints.js';
import { iterateSseEvents } from './sse.js';

/** A provider's refusal, with the HTTP status so callers can tell "sign in again" (401/403) apart
 * from everything else. The message never includes the credential. */
export class ProviderRequestError extends Error {
  readonly status: number;
  constructor(message: string, status: number) {
    super(message);
    this.name = 'ProviderRequestError';
    this.status = status;
  }
}

/** Reads an error out of a failure body. xAI puts a bare string in `error`; others an object. */
export function providerErrorText(payload: unknown): string | undefined {
  if (!payload || typeof payload !== 'object') return undefined;
  const error = (payload as { error?: unknown }).error;
  if (typeof error === 'string' && error.trim()) return error.trim();
  if (error && typeof error === 'object') {
    const message = (error as { message?: unknown }).message;
    if (typeof message === 'string' && message.trim()) return message.trim();
  }
  return undefined;
}

export function redactProviderSecrets(text: string, secrets: readonly (string | undefined)[]): string {
  let safe = text;
  for (const secret of secrets) if (secret) safe = safe.split(secret).join('[redacted]');
  return safe;
}

export function safeProviderErrorText(payload: unknown, credential: string): string | undefined {
  const text = providerErrorText(payload);
  return text ? redactProviderSecrets(text, [credential]) : undefined;
}

type ChunkDelta = { content?: unknown; reasoning?: unknown; reasoning_content?: unknown };
type Chunk = {
  choices?: Array<{ delta?: ChunkDelta }>;
  usage?: { prompt_tokens?: unknown; completion_tokens?: unknown; cost?: unknown };
  error?: unknown;
};

const count = (value: unknown) => (typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : undefined);

/**
 * Streams an OpenAI-compatible `POST {baseUrl}/chat/completions` call straight from the browser to
 * the provider, as the kit's common ChatEvent shape. The effort goes out as `reasoning_effort` only
 * when the caller chose one; otherwise the provider applies its own default.
 */
export async function* streamChatCompletions(endpoint: CloudEndpoint, request: ChatRequest): AsyncGenerator<ChatEvent> {
  const response = await fetch(`${endpoint.baseUrl}/chat/completions`, {
    method: 'POST',
    signal: request.signal,
    redirect: 'error',
    headers: { Authorization: `Bearer ${endpoint.apiKey}`, 'Content-Type': 'application/json', ...endpoint.headers },
    body: JSON.stringify({
      model: request.model,
      messages: request.messages,
      stream: true,
      stream_options: { include_usage: true },
      ...(request.effort ? { reasoning_effort: request.effort } : {}),
    }),
  });
  if (!response.ok || !response.body) {
    const payload = await response.json().catch(() => undefined);
    throw new ProviderRequestError(safeProviderErrorText(payload, endpoint.apiKey) ?? `The provider answered ${response.status}.`, response.status);
  }
  const reader = response.body.getReader();
  try {
    for await (const event of iterateSseEvents(reader)) {
      if (event.type !== 'data') continue;
      let chunk: Chunk;
      try { chunk = JSON.parse(event.data) as Chunk; } catch { continue; }
      const error = safeProviderErrorText(chunk, endpoint.apiKey);
      if (error) throw new ProviderRequestError(error, 200);
      const delta = chunk.choices?.[0]?.delta;
      const reasoning = delta?.reasoning ?? delta?.reasoning_content;
      if (typeof reasoning === 'string' && reasoning) yield { type: 'reasoning', text: reasoning };
      if (typeof delta?.content === 'string' && delta.content) yield { type: 'text', text: delta.content };
      if (chunk.usage) {
        yield { type: 'usage', inputTokens: count(chunk.usage.prompt_tokens), outputTokens: count(chunk.usage.completion_tokens), costUsd: count(chunk.usage.cost) };
      }
    }
  } finally {
    await reader.cancel().catch(() => undefined);
    try { reader.releaseLock(); } catch { /* A pending read releases it when settled. */ }
  }
  yield { type: 'done' };
}
