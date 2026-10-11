/**
 * Where each browser-direct provider lives. All three answer a browser origin (CORS measured live
 * from Motive) and speak the OpenAI-compatible chat-completions shape, so the page calls them
 * directly with the user's own credential. TOKEN RULE: nothing here routes through the site's server.
 */
export type WebSearchMechanism =
  /** OpenRouter's `plugins: [{ id: 'web', ... }]` request field; search runs on OpenRouter's side. */
  | 'openrouter-plugin'
  /** xAI's built-in `tools: [{ type: 'web_search' }]`, which exists only on `${baseUrl}/responses`
   * (sending it to /chat/completions answers 422; the old `search_parameters` answers 410). */
  | 'xai-responses-web-search'
  /** No server-side search on this provider; callers must not claim a search happened. */
  | 'none';

export type CloudEndpoint = {
  baseUrl: string;
  apiKey: string;
  /** Extra headers beyond Authorization/Content-Type. Only OpenRouter uses them (attribution). */
  headers?: Record<string, string>;
  webSearch: WebSearchMechanism;
};

export type DirectProviderId = 'openrouter' | 'xai' | 'groq' | 'huggingface';

export const PROVIDER_BASE_URLS: Record<DirectProviderId, string> = {
  openrouter: 'https://openrouter.ai/api/v1',
  xai: 'https://api.x.ai/v1',
  groq: 'https://api.groq.com/openai/v1',
  // Hugging Face Inference Providers, OpenAI-compatible: GET /models, POST /chat/completions.
  // Billed against the caller's own HF account (free tier, PRO credits, then pay-as-you-go).
  huggingface: 'https://router.huggingface.co/v1',
};

export type EndpointOptions = {
  /** Shown in OpenRouter's usage dashboard as the calling app. */
  appTitle?: string;
  /** Defaults to the page origin. */
  referer?: string;
};

export function endpointFor(provider: DirectProviderId, credential: string, options: EndpointOptions = {}): CloudEndpoint {
  switch (provider) {
    case 'openrouter': {
      const referer = options.referer ?? (typeof window !== 'undefined' ? window.location.origin : '');
      return {
        baseUrl: PROVIDER_BASE_URLS.openrouter,
        apiKey: credential,
        headers: { 'HTTP-Referer': referer, ...(options.appTitle ? { 'X-OpenRouter-Title': options.appTitle } : {}) },
        webSearch: 'openrouter-plugin',
      };
    }
    case 'xai':
      return { baseUrl: PROVIDER_BASE_URLS.xai, apiKey: credential, webSearch: 'xai-responses-web-search' };
    case 'groq':
      return { baseUrl: PROVIDER_BASE_URLS.groq, apiKey: credential, webSearch: 'none' };
    case 'huggingface':
      // No server-side search hook on Inference Providers' chat-completions route; callers must
      // not claim a search happened (see WebSearchMechanism's 'none' doc above).
      return { baseUrl: PROVIDER_BASE_URLS.huggingface, apiKey: credential, webSearch: 'none' };
  }
}
