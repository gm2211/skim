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
  security: { gradient: "linear-gradient(140deg, #64748b 0%, #0f766e 100%)", glyph: "M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6zM9 12l2 2 4-4" },
  android: { gradient: "linear-gradient(140deg, #4ade80 0%, #15803d 100%)", glyph: "M7 2h10a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zM11 18h2" },
  climate: { gradient: "linear-gradient(140deg, #86efac 0%, #166534 100%)", glyph: "M11 20A7 7 0 0 1 4 13c0-6 6-9 16-9 0 10-3 16-9 16zM4 21c3-5 6-8 10-10" },
  startups: { gradient: "linear-gradient(140deg, #fb923c 0%, #c2410c 100%)", glyph: "M3 3v18h18M7 15l4-4 3 3 6-7M15 7h5v5" },
  finance: { gradient: "linear-gradient(140deg, #2dd4bf 0%, #0e7490 100%)", glyph: "M3 6h18v12H3zM12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6zM6 9v.01M18 15v.01" },
  crypto: { gradient: "linear-gradient(140deg, #fbbf24 0%, #a16207 100%)", glyph: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM10 8h3.5a2 2 0 0 1 0 4H10zM10 12h4a2 2 0 0 1 0 4h-4zM10 7v10M12 6v2M12 16v2" },
  photography: { gradient: "linear-gradient(140deg, #a8a29e 0%, #44403c 100%)", glyph: "M4 7h3l2-3h6l2 3h3a1 1 0 0 1 1 1v11a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V8a1 1 0 0 1 1-1zM12 17a4 4 0 1 0 0-8 4 4 0 0 0 0 8z" },
  "film-tv": { gradient: "linear-gradient(140deg, #f87171 0%, #991b1b 100%)", glyph: "M3 4h18v16H3zM7 4v16M17 4v16M3 8h4M3 12h4M3 16h4M17 8h4M17 12h4M17 16h4" },
  music: { gradient: "linear-gradient(140deg, #e879f9 0%, #86198f 100%)", glyph: "M9 18V5l12-2v13M9 18a3 3 0 1 1-6 0 3 3 0 0 1 6 0zM21 16a3 3 0 1 1-6 0 3 3 0 0 1 6 0z" },
  books: { gradient: "linear-gradient(140deg, #d6a76c 0%, #7c4a1e 100%)", glyph: "M4 19.5A2.5 2.5 0 0 1 6.5 17H20V3H6.5A2.5 2.5 0 0 0 4 5.5zM4 19.5A2.5 2.5 0 0 0 6.5 22H20v-5" },
  history: { gradient: "linear-gradient(140deg, #c4a484 0%, #57534e 100%)", glyph: "M3 21h18M5 21V10M9 21V10M15 21V10M19 21V10M2 10l10-6 10 6z" },
  food: { gradient: "linear-gradient(140deg, #fca5a5 0%, #c2410c 100%)", glyph: "M4 3v7a3 3 0 0 0 6 0V3M7 3v18M17 21V3c-2.5 1-4 4-4 8h4" },
  travel: { gradient: "linear-gradient(140deg, #38bdf8 0%, #0369a1 100%)", glyph: "M2 16l20-8-6 12-3-5zM13 15l9-7" },
  sports: { gradient: "linear-gradient(140deg, #a3e635 0%, #3f6212 100%)", glyph: "M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18zM5.6 5.6c3.5 3.5 3.5 9.3 0 12.8M18.4 5.6c-3.5 3.5-3.5 9.3 0 12.8" },
  cars: { gradient: "linear-gradient(140deg, #93c5fd 0%, #1e40af 100%)", glyph: "M3 17v-4l2-5h14l2 5v4zM3 13h18M7 17a2 2 0 1 0 0 .01M17 17a2 2 0 1 0 0 .01" },
  diy: { gradient: "linear-gradient(140deg, #fdba74 0%, #9a3412 100%)", glyph: "M14.7 6.3a4 4 0 0 1 5 5l-2.2-.6-1.4 1.4.6 2.2a4 4 0 0 1-5-5zM12 12l-8 8" },
  style: { gradient: "linear-gradient(140deg, #f9a8d4 0%, #9d174d 100%)", glyph: "M20.4 6.6 16 4a4 4 0 0 1-8 0L3.6 6.6l1.5 4.9H7V21h10v-9.5h1.9z" },
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
