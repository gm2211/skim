import type { TodayWindow } from "./todayEdition";

/** The paper's name, on the nameplate and wherever the app links to it. */
export const PAPER_NAME = "The Briefing";
/** The short form, for tight spots such as a sidebar row or a tab. */
export const PAPER_SHORT_NAME = "Briefing";

export const DISPATCH_DAY_CHOICES = [1, 3, 7] as const;
export type DispatchDays = (typeof DISPATCH_DAY_CHOICES)[number];

/** The reader's setting, or the default of three days. */
export function dispatchDays(value: number | null | undefined): DispatchDays {
  return (DISPATCH_DAY_CHOICES as readonly number[]).includes(value ?? 0) ? (value as DispatchDays) : 3;
}

/**
 * The window one edition reads. The front page ends at the coming local
 * midnight and reaches back `days` whole days, so a three-day paper opened on
 * Thursday covers Tuesday to Thursday. Each page turned is the edition
 * before: the `days` days before the page after it. Local midnights
 * throughout, so a DST day is still a whole day.
 */
export function dispatchWindow(now: Date, page: number, days: number): TodayWindow {
  const turn = Math.max(1, Math.floor(page)) - 1;
  const end = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1 - turn * days);
  const start = new Date(end.getFullYear(), end.getMonth(), end.getDate() - days);
  return { startsAt: Math.floor(start.getTime() / 1000), endsAt: Math.floor(end.getTime() / 1000) };
}

/** "Last 3 days", "Today", or how the window reads on an earlier page. */
export function spanLabel(days: number, page: number): string {
  if (page > 1) return days === 1 ? "Daily edition" : `${days}-day edition`;
  return days === 1 ? "Today" : `Last ${days} days`;
}

export type BodyPart = { text: string } | { cites: number[] };

/** Splits a paragraph into its words and its `[1, 3]` citations. */
export function splitCitations(paragraph: string): BodyPart[] {
  const parts: BodyPart[] = [];
  const pattern = /\s*\[(\d+(?:\s*,\s*\d+)*)\]/g;
  let last = 0;
  for (const match of paragraph.matchAll(pattern)) {
    const index = match.index ?? 0;
    if (index > last) parts.push({ text: paragraph.slice(last, index) });
    parts.push({ cites: match[1].split(",").map((n) => Number(n.trim())) });
    last = index + match[0].length;
  }
  if (last < paragraph.length) parts.push({ text: paragraph.slice(last) });
  return parts;
}

/** A paragraph without its citations, for a chat's context. */
export function withoutCitations(paragraph: string): string {
  return splitCitations(paragraph).map((part) => ("text" in part ? part.text : "")).join("").trim();
}
