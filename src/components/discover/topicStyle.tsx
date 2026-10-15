// A colour and a line glyph per catalog topic, so the Discover cards read at a
// glance without shipping photographs. Unknown topics fall back to RSS.

const STYLES: Record<string, { gradient: string; glyph: string }> = {
  tech: { gradient: "linear-gradient(140deg, #f2706a 0%, #c43d5a 100%)", glyph: "M4 6h16v10H4zM2 19h20M9 16v3M15 16v3" },
  programming: { gradient: "linear-gradient(140deg, #3b82f6 0%, #1e3a8a 100%)", glyph: "m8 7-5 5 5 5M16 7l5 5-5 5M14 4l-4 16" },
  ai: { gradient: "linear-gradient(140deg, #a78bfa 0%, #5b21b6 100%)", glyph: "M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8zM19 15l.8 2.2L22 18l-2.2.8L19 21l-.8-2.2L16 18l2.2-.8z" },
  science: { gradient: "linear-gradient(140deg, #34d399 0%, #047857 100%)", glyph: "M9 3h6M10 3v6l-5 9a2 2 0 0 0 1.8 3h10.4a2 2 0 0 0 1.8-3l-5-9V3M7.5 14h9" },
  space: { gradient: "linear-gradient(140deg, #6366f1 0%, #0f172a 100%)", glyph: "M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM3 16c3-1 15-7 18-10M18 3l.6 1.4L20 5l-1.4.6L18 7l-.6-1.4L16 5l1.4-.6zM5 4l.4 1L6.5 5.5l-1.1.4L5 7l-.4-1.1L3.5 5.5l1.1-.5z" },
  news: { gradient: "linear-gradient(140deg, #f59e0b 0%, #b45309 100%)", glyph: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM3 12h18M12 3c2.5 2.7 3.8 5.7 3.8 9s-1.3 6.3-3.8 9c-2.5-2.7-3.8-5.7-3.8-9S9.5 5.7 12 3z" },
  business: { gradient: "linear-gradient(140deg, #14b8a6 0%, #115e59 100%)", glyph: "M3 20h18M6 16v-5M10 16V8M14 16v-3M18 16V5" },
  design: { gradient: "linear-gradient(140deg, #f472b6 0%, #be185d 100%)", glyph: "M12 21a9 9 0 1 1 9-9c0 2.5-2 3.5-3.5 3.5H15a2 2 0 0 0-1.5 3.3c.6.7.2 2.2-1.5 2.2zM7.5 11.5h.01M10.5 7.5h.01M15 8h.01" },
  apple: { gradient: "linear-gradient(140deg, #94a3b8 0%, #334155 100%)", glyph: "M12 7c1.5-1.5 4-1.6 5.6.2-1.6 1-2.1 2.7-1.6 4.3.4 1.4 1.4 2.3 2.5 2.7-.7 2.7-2.6 5.8-4.4 5.8-1.2 0-1.6-.7-3.1-.7s-2 .7-3.1.7C6 20 3.5 15.6 3.5 12.3 3.5 9.2 5.5 7 8 7c1.4 0 2.6.9 4 0zM12 7c0-2 1.2-3.6 3-4" },
  gaming: { gradient: "linear-gradient(140deg, #ef4444 0%, #7f1d1d 100%)", glyph: "M6 11h4M8 9v4M15 12h.01M18 10h.01M17.3 5H6.7a4 4 0 0 0-4 3.6l-.6 6.2A2.8 2.8 0 0 0 7 17l2-2h6l2 2a2.8 2.8 0 0 0 4.9-2.2l-.6-6.2A4 4 0 0 0 17.3 5z" },
};

const FALLBACK = { gradient: "linear-gradient(140deg, #58a6ff 0%, #1f4b8f 100%)", glyph: "M4 11a9 9 0 0 1 9 9M4 4a16 16 0 0 1 16 16M5 20a1 1 0 1 0 0-2 1 1 0 0 0 0 2z" };

export function topicStyle(id: string) {
  return STYLES[id] ?? FALLBACK;
}

export function TopicGlyph({ id, size, className }: { id: string; size: number; className?: string }) {
  return (
    <svg className={className} width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor"
      strokeWidth={size > 40 ? 1.1 : 1.8} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
      <path d={topicStyle(id).glyph} />
    </svg>
  );
}
