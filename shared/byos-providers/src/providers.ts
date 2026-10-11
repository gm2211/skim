import type { ByosProvider, CatalogModel, SignInMethod } from '@byos/core';
import { listModelsForEndpoint, listOpenRouterModels } from './catalog.js';
import { streamChatCompletions } from './chat.js';
import { endpointFor, type EndpointOptions } from './endpoints.js';

/**
 * Ready-made ByosProvider adapters for the three browser-direct providers. Each lists models live
 * from the provider and streams chat straight from the browser. TOKEN RULE: the token passed in is
 * sent only to the provider's own host.
 */
const toCatalog = (models: Array<{ id: string; name: string; analysisFit?: string }>): CatalogModel[] =>
  models.map(model => ({ id: model.id, name: model.name, ...(model.analysisFit === 'recommended' ? { recommended: true } : {}) }));

export function openrouter(options: EndpointOptions = {}): ByosProvider {
  return {
    id: 'openrouter',
    displayName: 'OpenRouter',
    // PKCE runs entirely in the browser: OpenRouter's key exchange answers CORS.
    signIn: [{ kind: 'pkce', handshakeViaSite: false }] satisfies SignInMethod[],
    availability: () => ({ available: true }),
    listModels: async (token, signal) => toCatalog(await listOpenRouterModels(token, signal)),
    stream: (token, request) => streamChatCompletions(endpointFor('openrouter', token, options), request),
  };
}

export function grok(options: { deviceCodeViaSite?: boolean } = {}): ByosProvider {
  return {
    id: 'xai',
    displayName: 'Grok',
    signIn: [
      // auth.x.ai sends no CORS headers, so the device-code start/poll needs the site's server once.
      ...(options.deviceCodeViaSite === false ? [] : [{ kind: 'device-code', handshakeViaSite: true } as const]),
      { kind: 'api-key', hint: 'An xAI API key from console.x.ai' },
    ],
    availability: () => ({ available: true }),
    listModels: async (token, signal) => toCatalog(await listModelsForEndpoint(endpointFor('xai', token), signal)),
    stream: (token, request) => streamChatCompletions(endpointFor('xai', token), request),
  };
}

export function groq(): ByosProvider {
  return {
    id: 'groq',
    displayName: 'Groq',
    signIn: [{ kind: 'api-key', hint: 'A Groq API key from console.groq.com' }],
    availability: () => ({ available: true }),
    listModels: async (token, signal) => toCatalog(await listModelsForEndpoint(endpointFor('groq', token), signal)),
    stream: (token, request) => streamChatCompletions(endpointFor('groq', token), request),
  };
}

/** Hugging Face Inference Providers: OpenAI-compatible, billed against the caller's own HF account
 * (free tier / PRO credits, then pay-as-you-go). `clientId` enables browser PKCE sign-in
 * ("Sign in with Hugging Face") -- omit it and only the pasted-access-token path is offered, since
 * PKCE sign-in needs an OAuth client id only the site owner can provision (or a Client ID Metadata
 * Document the site serves itself; see huggingface-sign-in.ts). */
export function huggingface(options: { clientId?: string } = {}): ByosProvider {
  return {
    id: 'huggingface',
    displayName: 'Hugging Face',
    signIn: [
      ...(options.clientId ? [{ kind: 'pkce', handshakeViaSite: false } as const] : []),
      { kind: 'api-key', hint: 'A fine-grained access token from huggingface.co/settings/tokens' },
    ],
    availability: () => ({ available: true }),
    listModels: async (token, signal) => toCatalog(await listModelsForEndpoint(endpointFor('huggingface', token), signal)),
    stream: (token, request) => streamChatCompletions(endpointFor('huggingface', token), request),
  };
}
