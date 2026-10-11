/**
 * Server-Sent-Events framing for streaming AI responses. Same behavior as Motive's
 * @motive/ai-protocol sse.ts (kept separate so the kit has no Motive dependency).
 */
export type SseEvent = { type: 'data'; data: string } | { type: 'comment'; text: string };

/** Classifies one SSE line. `null` for blank lines, non-data lines, empty payloads and `[DONE]`. */
export function parseSseLine(rawLine: string): SseEvent | null {
  const line = rawLine.trim();
  if (!line) return null;
  if (line.startsWith(':')) return { type: 'comment', text: line.slice(1).trim() };
  if (!line.startsWith('data:')) return null;
  const data = line.slice('data:'.length).trim();
  if (!data || data === '[DONE]') return null;
  return { type: 'data', data };
}

/** Reads an SSE body and yields classified events, carrying partial lines across chunks. */
export async function* iterateSseEvents(
  reader: ReadableStreamDefaultReader<Uint8Array>,
  options: { decoder?: TextDecoder; seed?: string } = {},
): AsyncGenerator<SseEvent> {
  const decoder = options.decoder ?? new TextDecoder();
  let buffer = options.seed ?? '';
  while (true) {
    const { value, done } = await reader.read();
    buffer += decoder.decode(value, { stream: !done });
    const lines = buffer.split(/\r?\n/);
    buffer = lines.pop() ?? '';
    for (const line of lines) {
      const event = parseSseLine(line);
      if (event) yield event;
    }
    if (done) break;
  }
  if (buffer) {
    const event = parseSseLine(buffer);
    if (event) yield event;
  }
}
