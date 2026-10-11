const PATHS = {
  check: <path d="m5 12 5 5 9-10"/>,
  close: <path d="m6 6 12 12M18 6 6 18"/>,
  copy: <><rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V4a1 1 0 0 0-1-1H4a1 1 0 0 0-1 1v11a1 1 0 0 0 1 1h4"/></>,
  external: <><path d="M15 4h5v5M13 11l7-7"/><path d="M18 13v6a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h6"/></>,
};

export type ByosIconName = keyof typeof PATHS;

/** Stroke icons drawn in currentColor, so they follow the site's text colors. */
export function ByosIcon({ name, size = 16 }: { name: ByosIconName; size?: number }) {
  return <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.8} strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" focusable="false">{PATHS[name]}</svg>;
}
