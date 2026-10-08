import assert from 'node:assert/strict';
import test from 'node:test';
// Built output: sources use NodeNext `.js` imports.
import { endpointFor, grok, groq, NOT_RECOMMENDED_REASON, openrouter, orderServices, parseSseLine, parseXaiResponsesPayload, streamChatCompletions, type ServiceKey } from '../dist/index.js';

type Call = { url: string; init?: RequestInit };
function fakeFetch(respond: (call: Call) => Response): Call[] {
  const calls: Call[] = [];
  globalThis.fetch = (async (url: string | URL, init?: RequestInit) => {
    const call = { url: String(url), init };
    calls.push(call);
    return respond(call);
  }) as typeof fetch;
  return calls;
}

function sse(lines: string[]): Response {
  return new Response(new Blob([lines.map(line => `${line}\n`).join('')]).stream(), { status: 200 });
}

test('endpoints are browser-direct provider hosts; OpenRouter carries the site title', () => {
  const or = endpointFor('openrouter', 'k', { appTitle: 'Garden', referer: 'https://garden.example' });
  assert.equal(or.baseUrl, 'https://openrouter.ai/api/v1');
  assert.deepEqual(or.headers, { 'HTTP-Referer': 'https://garden.example', 'X-OpenRouter-Title': 'Garden' });
  assert.equal(endpointFor('xai', 'k').webSearch, 'xai-responses-web-search');
  assert.equal(endpointFor('groq', 'k').webSearch, 'none');
});

test('chat streams text, reasoning and usage, and sends the token only to the provider', async () => {
  const calls = fakeFetch(() => sse([
    ': keepalive',
    'data: {"choices":[{"delta":{"reasoning":"thinking"}}]}',
    'data: {"choices":[{"delta":{"content":"Hel"}}]}',
    'data: {"choices":[{"delta":{"content":"lo"}}]}',
    'data: {"choices":[],"usage":{"prompt_tokens":3,"completion_tokens":2}}',
    'data: [DONE]',
  ]));
  const events = [];
  for await (const event of groq().stream('secret', { model: 'm', messages: [{ role: 'user', content: 'hi' }], effort: 'low' })) events.push(event);
  assert.deepEqual(events, [
    { type: 'reasoning', text: 'thinking' },
    { type: 'text', text: 'Hel' },
    { type: 'text', text: 'lo' },
    { type: 'usage', inputTokens: 3, outputTokens: 2, costUsd: undefined },
    { type: 'done' },
  ]);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://api.groq.com/openai/v1/chat/completions');
  assert.equal((calls[0].init?.headers as Record<string, string>).Authorization, 'Bearer secret');
  assert.equal(calls[0].init?.redirect, 'error');
  assert.equal(JSON.parse(String(calls[0].init?.body)).reasoning_effort, 'low');
});

test('chat surfaces a provider refusal with its status and redacts an echoed credential', async () => {
  fakeFetch(() => new Response(JSON.stringify({ code: 'x', error: 'Incorrect API key: bad-secret' }), { status: 401 }));
  await assert.rejects(async () => {
    for await (const _ of streamChatCompletions(endpointFor('xai', 'bad-secret'), { model: 'm', messages: [] })) { /* drain */ }
  }, (error: Error & { status?: number }) => error.message === 'Incorrect API key: [redacted]' && error.status === 401);
});

test('chat cancels provider stream when consumer stops early', async () => {
  let canceled = false;
  globalThis.fetch = (async () => new Response(new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(new TextEncoder().encode('data: {"choices":[{"delta":{"content":"first"}}]}\n\n'));
    },
    cancel() { canceled = true; },
  }))) as typeof fetch;
  for await (const _event of streamChatCompletions(endpointFor('groq', 'key'), { model: 'm', messages: [] })) break;
  assert.equal(canceled, true);
});

test('model lists come from the provider', async () => {
  const calls = fakeFetch(({ url }) => url.endsWith('/models') && url.includes('x.ai')
    ? new Response(JSON.stringify({ data: [{ id: 'grok-b' }, { id: 'grok-a', name: 'Grok A' }] }))
    : new Response(JSON.stringify({ data: [{ id: 'good', name: 'GPT-5.6', supported_parameters: ['tools'] }, { id: 'no-tools' }] })));
  assert.deepEqual(await grok().listModels('k'), [{ id: 'grok-a', name: 'Grok A' }, { id: 'grok-b', name: 'grok-b' }]);
  assert.deepEqual(await openrouter().listModels('k'), [{ id: 'good', name: 'GPT-5.6', recommended: true }]);
  assert.ok(calls.every(call => call.init?.redirect === 'error'));
});

test('provider model discovery forwards cancellation signal', async () => {
  const calls = fakeFetch(() => new Response(JSON.stringify({ data: [{ id: 'm' }] })));
  const controller = new AbortController();
  await groq().listModels('k', controller.signal);
  assert.equal(calls[0].init?.signal, controller.signal);
  assert.equal(calls[0].init?.redirect, 'error');
});

test('model discovery redacts credentials echoed in provider errors', async () => {
  fakeFetch(() => new Response(JSON.stringify({ error: { message: 'Rejected secret-key' } }), { status: 401 }));
  await assert.rejects(() => grok().listModels('secret-key'), /Rejected \[redacted\]/);
});

test('sign-in methods disclose when the site server is involved', () => {
  assert.deepEqual(openrouter().signIn, [{ kind: 'pkce', handshakeViaSite: false }]);
  assert.equal(grok().signIn[0].kind, 'device-code');
  assert.equal(grok({ deviceCodeViaSite: false }).signIn[0].kind, 'api-key');
});

test('moved helpers keep their behavior', () => {
  assert.equal(parseSseLine('data: [DONE]'), null);
  const parsed = parseXaiResponsesPayload({ output: [{ type: 'message', content: [{ type: 'output_text', text: '{}', annotations: [{ url: 'https://a.example/x', title: '1' }] }] }] });
  assert.deepEqual(parsed.sources, [{ url: 'https://a.example/x', title: 'a.example' }]);
});

test('Claude: API key only while subscriptions are paused; models and effort come from Anthropic', async () => {
  const { claude, claudeCredentialAllowed, CLAUDE_SUBSCRIPTIONS_PAUSED_NOTE } = await import('../dist/index.js');
  assert.equal(claudeCredentialAllowed('sk-ant-api03-x'), true);
  assert.equal(claudeCredentialAllowed('sk-ant-oat01-x'), false);
  assert.equal(claudeCredentialAllowed('sk-ant-oat01-x', false), true);
  assert.deepEqual(claude().signIn.map(method => method.kind), ['api-key']);
  const calls = fakeFetch(() => new Response(JSON.stringify({ data: [
    { id: 'claude-opus-5-5', display_name: 'Claude Opus 5.5', capabilities: { effort: { supported: true, low: { supported: true }, max: { supported: true } } } },
  ] })));
  assert.deepEqual(await claude().listModels('sk-ant-api03-x'), [{ id: 'claude-opus-5-5', name: 'Claude Opus 5.5', reasoningEfforts: [{ effort: 'low' }, { effort: 'max' }] }]);
  assert.equal(calls[0].url.startsWith('https://api.anthropic.com/v1/models'), true);
  assert.equal((calls[0].init?.headers as Record<string, string>)['anthropic-dangerous-direct-browser-access'], 'true');
  assert.equal(calls[0].init?.redirect, 'error');
  await assert.rejects(() => claude().listModels('sk-ant-oat01-x'), (error: Error) => error.message === CLAUDE_SUBSCRIPTIONS_PAUSED_NOTE);
  assert.equal(calls.length, 1);
});

test('Claude streams text, thinking and usage from the Messages API', async () => {
  const { claude } = await import('../dist/index.js');
  const calls = fakeFetch(() => sse([
    'event: message_start', 'data: {"type":"message_start","message":{"usage":{"input_tokens":9}}}',
    'data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}',
    'data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hi"}}',
    'data: {"type":"message_delta","usage":{"output_tokens":4}}',
  ]));
  const events = [];
  for await (const event of claude().stream('sk-ant-api03-x', { model: 'm', messages: [{ role: 'system', content: 'be brief' }, { role: 'user', content: 'hi' }], effort: 'low' })) events.push(event);
  assert.deepEqual(events, [
    { type: 'reasoning', text: 'hmm' }, { type: 'text', text: 'Hi' }, { type: 'usage', inputTokens: 9, outputTokens: 4 }, { type: 'done' },
  ]);
  assert.equal(calls[0].init?.redirect, 'error');
  const body = JSON.parse(String(calls[0].init?.body));
  assert.equal(body.system, 'be brief');
  assert.deepEqual(body.messages, [{ role: 'user', content: 'hi' }]);
  assert.deepEqual(body.output_config, { effort: 'low' });
});

test('orderServices puts Grok, ChatGPT, OpenRouter, then Claude by default, and a site order wins', () => {
  const ids = ['claude', 'chatgpt', 'grok', 'openrouter', 'other'] as const;
  const keyOf = (id: string) => (id === 'other' ? undefined : id as ServiceKey);
  assert.deepEqual(orderServices(ids, keyOf), ['grok', 'chatgpt', 'openrouter', 'claude', 'other']);
  assert.deepEqual(orderServices(ids, keyOf, ['openrouter', 'grok']), ['openrouter', 'grok', 'claude', 'chatgpt', 'other']);
  assert.ok(NOT_RECOMMENDED_REASON.claude);
});
