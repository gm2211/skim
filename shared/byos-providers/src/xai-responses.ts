/**
 * xAI's Responses API (`POST https://api.x.ai/v1/responses`) — the only endpoint where Grok's
 * built-in `web_search` tool actually exists.
 *
 * WHY THIS MODULE EXISTS
 * ---------------------
 * The browser-direct cloud path (endpoints.ts) speaks one wire format for all three
 * providers: OpenAI-compatible `POST {baseUrl}/chat/completions`. That is correct for OpenRouter and
 * Groq, and it is correct for Grok's plain chat too. It is NOT where Grok searches the web.
 *
 * An earlier pass got half of this right and then drew the wrong conclusion. It found that
 * `tools: [{ type: 'web_search' }]` answers HTTP 422 from `/v1/chat/completions`, correctly
 * identified that xAI documents that endpoint's `tools` field as function-calling only, and then
 * downgraded Grok to "cannot search the web at all". The tool SHAPE was right the whole time; it was
 * being posted to the wrong endpoint. xAI's tools documentation states the endpoint for server-side
 * tools as `"https://api.x.ai/v1/responses"` and gives the tools array as
 * `"tools": [ { "type": "web_search" }, { "type": "x_search" }, { "type": "code_interpreter" } ]`.
 * So this module implements that second endpoint rather than removing the capability.
 *
 * REQUEST SHAPE, FIELD BY FIELD (each justified by a specific xAI doc statement)
 * -----------------------------------------------------------------------------
 *  - `model` — top-level field, listed in xAI's REST reference for POST /v1/responses.
 *  - `instructions` — the system prompt. xAI's REST reference documents this top-level field as
 *    "String for system prompt; cannot be used with previous_response_id". Nothing here ever sends
 *    previous_response_id, so the restriction does not apply. Chosen over threading a
 *    `{role:'system'}` entry through `input`: `instructions` is the field xAI's own reference names
 *    for this purpose, so it needs no inference about which roles the `input` array admits.
 *  - `input` — the user turn, as a plain string. xAI's structured-outputs page shows exactly this
 *    form verbatim (`input="Find the latest machine-checked proof of the four color theorem."`).
 *    The array-of-messages form is also accepted, but the string form is the one the docs show
 *    literally, and this path only ever has user content to send once `instructions` has taken the
 *    system prompt. Callers with more than one user message join them (see joinUserInput).
 *  - `text.format` — structured output. xAI's structured-outputs page documents `text.format` (NOT
 *    chat/completions' `response_format`) and states of the format parameter: "The parameter also
 *    accepts `"json_object"` for any well-formed JSON when you don't need a specific structure, or
 *    `"text"` (the default) for free-form text." `json_object` is the exact counterpart of the
 *    `response_format: { type: 'json_object' }` the chat/completions path already sends, and it is
 *    the only usable choice here: every caller of this module supplies a prompt-described shape
 *    rather than a JSON Schema (see Motive's research-mission.ts callCloudEndpoint, which takes a
 *    system/user prompt pair and no schema at all), so `json_schema` + `strict` has nothing to be
 *    strict against.
 *  - `tools: [{ type: 'web_search' }]` — the whole point. Sent only when the caller asked for
 *    search, so the no-search retry drops it rather than re-sending a field that may be what failed.
 *  - `include: ['no_inline_citations']` — sent alongside the tool. xAI's citations page: "Inline
 *    citations are enabled by default. Disable by passing `"include": ["no_inline_citations"]`."
 *    Left on, Grok writes `[[1]](url)` markdown INTO its answer text — which, for a caller that is
 *    about to `JSON.parse` that text, means citation markup smeared through every field value. The
 *    citations still arrive out of band in `annotations` (without positional indices, since there is
 *    no longer any inline span for them to point at), which is where this module reads them from
 *    anyway.
 *  - `temperature`, `max_output_tokens` — both listed as top-level fields in xAI's REST reference;
 *    max_output_tokens is documented there as including reasoning as well as output tokens, the same
 *    accounting chat/completions' max_completion_tokens has.
 *
 * NOT SENT: `stream`. See the streaming note on parseXaiResponsesPayload below.
 *
 * RESPONSE SHAPE
 * --------------
 * xAI's structured-outputs page gives the read-back path verbatim:
 *   const message = response.output.find((item) => item.type === "message");
 *   const textContent = message?.content?.find((c) => c.type === "output_text");
 *   const parsed = JSON.parse(textContent.text);
 * and its citations page places annotations at `output` → `content` → `annotations`, each shaped
 *   { "type": "url_citation", "url": "https://example.com", "start_index": 208, "end_index": 235, "title": "1" }
 * That is a FLAT annotation — `url`/`title` directly on the item, not nested under a `url_citation`
 * key the way OpenRouter's chat/completions annotations are. Both shapes matter downstream; see
 * sourcesFromAnnotations for why the flat one needs its `title` treated with suspicion.
 *
 * DOC-VERIFIED vs INFERRED: everything above is quoted from xAI's live documentation. What is NOT
 * doc-verified, and is read defensively for that reason: the `usage` field names on a Responses
 * reply (read as input_tokens/output_tokens with prompt_tokens/completion_tokens accepted as a
 * fallback), and the `status`/`incomplete_details` fields used to tell a truncated answer from a
 * complete one. Both degrade to "no billing recorded" / "not known to be truncated" when absent,
 * which is why they are safe to guess at; the request shape, which is not safe to guess at, is not
 * guessed at anywhere.
 */
import type { CloudEndpoint } from './endpoints.js';

/** A citation Grok reported for its answer, normalized to the `{title, url}` pair every source
 * consumer in this app already speaks. */
export type XaiResponsesSource = { title: string; url: string };

export type XaiResponsesResult = {
  /** The concatenated text of every `output_text` block, i.e. the model's actual answer. */
  text: string;
  /** Citations pulled out of the answer's annotations, de-duplicated by URL, in first-seen order. */
  sources: XaiResponsesSource[];
  /** True when xAI reported the answer as cut short rather than finished — the Responses-API
   * counterpart of chat/completions' `finish_reason: 'length'`, which callers already surface as
   * "the model spent its whole output budget before answering". */
  truncated: boolean;
  /** Token counts, in chat/completions' own field names so existing billing code can consume them
   * unchanged. Undefined when the reply carried no usage block. */
  usage?: { prompt_tokens?: number; completion_tokens?: number; total_tokens?: number };
  /** An error the provider reported inside an otherwise-2xx body. */
  errorMessage?: string;
};

export function xaiResponsesUrl(endpoint: CloudEndpoint): string {
  return `${endpoint.baseUrl}/responses`;
}

/** Joins several user turns into the single `input` string this module sends. Only the vehicle
 * follow-up path needs it (context turn + question turn); everything else passes one string. */
export function joinUserInput(...parts: string[]): string {
  return parts.filter(part => part.trim()).join('\n\n');
}

export function buildXaiResponsesBody(options: {
  model: string;
  system: string;
  user: string;
  maxOutputTokens: number;
  temperature: number;
  webSearch: boolean;
  /** Whether to ask for a JSON object rather than free text. Every caller in this app does today;
   * the flag exists because the vehicle follow-up has one mode that deliberately does not. */
  structuredOutput: boolean;
}): Record<string, unknown> {
  return {
    model: options.model,
    instructions: options.system,
    input: options.user,
    temperature: options.temperature,
    max_output_tokens: options.maxOutputTokens,
    ...(options.structuredOutput ? { text: { format: { type: 'json_object' } } } : {}),
    // Both fields belong to the search request, so both are dropped together on a no-search retry.
    ...(options.webSearch ? { tools: [{ type: 'web_search' }], include: ['no_inline_citations'] } : {}),
  };
}

/** A citation title xAI actually meant as a display name, as opposed to the bare ordinal its
 * citations page shows ("title": "1"). A source card reading "1" is worse than one reading the
 * host it came from, so an ordinal-looking title is discarded in favour of the URL's hostname. */
const ORDINAL_TITLE = /^\[?\d+\]?$/;

function displayTitle(rawTitle: unknown, url: string): string {
  const title = typeof rawTitle === 'string' ? rawTitle.trim() : '';
  if (title && !ORDINAL_TITLE.test(title)) return title;
  try {
    return new URL(url).hostname.replace(/^www\./, '') || url;
  } catch {
    return url;
  }
}

/**
 * Pulls `{type:'url_citation', url, title}` entries out of an annotations array. xAI's shape is
 * FLAT (url/title on the annotation itself), unlike OpenRouter's nested
 * `{type:'url_citation', url_citation:{url,title}}` — both are read here so this one helper covers
 * whichever a provider sends, and so a shape change on either side degrades to "no sources shown"
 * rather than throwing mid-answer.
 */
export function sourcesFromAnnotations(annotations: unknown, seen: Set<string> = new Set()): XaiResponsesSource[] {
  if (!Array.isArray(annotations)) return [];
  const sources: XaiResponsesSource[] = [];
  for (const item of annotations) {
    if (!item || typeof item !== 'object') continue;
    const nested = (item as { url_citation?: { url?: unknown; title?: unknown } }).url_citation;
    const flatUrl = (item as { url?: unknown }).url;
    const url = typeof nested?.url === 'string' ? nested.url : typeof flatUrl === 'string' ? flatUrl : undefined;
    if (!url || seen.has(url)) continue;
    seen.add(url);
    const rawTitle = typeof nested?.title === 'string' ? nested.title : (item as { title?: unknown }).title;
    sources.push({ url, title: displayTitle(rawTitle, url) });
  }
  return sources;
}

function finiteCount(value: unknown): number | undefined {
  return typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : undefined;
}

type ResponsesUsage = {
  input_tokens?: unknown; output_tokens?: unknown; total_tokens?: unknown;
  prompt_tokens?: unknown; completion_tokens?: unknown;
};

function usageFrom(raw: unknown): XaiResponsesResult['usage'] {
  if (!raw || typeof raw !== 'object') return undefined;
  const usage = raw as ResponsesUsage;
  const prompt_tokens = finiteCount(usage.input_tokens) ?? finiteCount(usage.prompt_tokens);
  const completion_tokens = finiteCount(usage.output_tokens) ?? finiteCount(usage.completion_tokens);
  const total_tokens = finiteCount(usage.total_tokens);
  if (prompt_tokens === undefined && completion_tokens === undefined && total_tokens === undefined) return undefined;
  return { prompt_tokens, completion_tokens, total_tokens };
}

/**
 * Reads an error out of a Responses body. xAI's failure bodies are not uniformly shaped — the
 * browser-direct chat path already had to learn that (`{"code": "...", "error": "<reason string>"}`
 * puts a bare STRING where every other OpenAI-compatible provider puts an object), so the same two
 * shapes are accepted here. Exported so callers can run it over a failure body without duplicating
 * the shape knowledge; Motive's research-mission.ts routes failures through its own extractCloudErrorMessage
 * instead, which already handles both and more (HTML bodies, empty bodies).
 */
export function xaiResponsesErrorText(payload: unknown): string | undefined {
  if (!payload || typeof payload !== 'object') return undefined;
  const error = (payload as { error?: unknown }).error;
  if (typeof error === 'string' && error.trim()) return error.trim();
  if (error && typeof error === 'object') {
    const message = (error as { message?: unknown }).message;
    if (typeof message === 'string' && message.trim()) return message.trim();
  }
  return undefined;
}

/**
 * Turns a parsed `/v1/responses` reply into text + citations.
 *
 * STREAMING: deliberately absent. The Responses API does support `stream: true`, and xAI's tools
 * documentation names one event type (`response.output_text.delta`) in an SDK example — but the SSE
 * frame shape behind that name (which field of the event carries the incremental text, how
 * annotations arrive mid-stream, how the run terminates) is not documented on xAI's site, and the
 * streaming pages that would carry it describe the chat/completions format instead. A guessed SSE
 * parser fails in the worst possible way here: it yields an empty answer on a 200 response, which
 * reads to a buyer as "Grok returned nothing" rather than as a bug. So every call this module makes
 * is non-streaming, and callers narrate the wait with a note instead of a live token feed. Sources
 * still reach the live feed — they are forwarded the moment the reply lands, before the answer is
 * parsed. If xAI ever documents the event shape, this is the one function that has to change.
 */
export function parseXaiResponsesPayload(payload: unknown): XaiResponsesResult {
  const errorMessage = xaiResponsesErrorText(payload);
  const root = (payload && typeof payload === 'object' ? payload : {}) as {
    output?: unknown;
    output_text?: unknown;
    status?: unknown;
    incomplete_details?: { reason?: unknown };
    usage?: unknown;
  };

  const seen = new Set<string>();
  const sources: XaiResponsesSource[] = [];
  let text = '';

  // output → items of type 'message' → content blocks of type 'output_text' → text + annotations.
  // Non-message items (a web_search_call record, reasoning) are skipped rather than concatenated:
  // only output_text carries the answer.
  const output = Array.isArray(root.output) ? root.output : [];
  for (const item of output) {
    if (!item || typeof item !== 'object') continue;
    const message = item as { type?: unknown; content?: unknown };
    if (message.type !== 'message' || !Array.isArray(message.content)) continue;
    for (const rawBlock of message.content) {
      if (!rawBlock || typeof rawBlock !== 'object') continue;
      const block = rawBlock as { type?: unknown; text?: unknown; annotations?: unknown };
      if (block.type !== 'output_text') continue;
      if (typeof block.text === 'string') text += block.text;
      sources.push(...sourcesFromAnnotations(block.annotations, seen));
    }
  }

  // `output_text` is the aggregate convenience field the OpenAI-compatible SDKs expose. Used only as
  // a fallback: a reply that carried a message item is read from the item, so a provider that sends
  // both cannot double-count. A reply that carried only the aggregate still produces an answer.
  if (!text && typeof root.output_text === 'string') text = root.output_text;

  // Inferred, not doc-verified — see this module's header. `status: 'incomplete'` with
  // `incomplete_details.reason === 'max_output_tokens'` is the Responses-API way of saying what
  // chat/completions says with `finish_reason: 'length'`; when neither field is present this stays
  // false and callers fall back to their generic "unexpected format" wording.
  const truncated = root.status === 'incomplete'
    && (root.incomplete_details?.reason === 'max_output_tokens' || root.incomplete_details?.reason === undefined);

  return { text, sources, truncated, usage: usageFrom(root.usage), errorMessage };
}
