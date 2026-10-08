import { useState, type ButtonHTMLAttributes } from "react";

type Props = ButtonHTMLAttributes<HTMLButtonElement> & {
  label: string;
  tooltip?: string;
  tooltipAlign?: "left" | "right";
  tooltipSide?: "top" | "bottom";
};

/** Compact action with a full touch target and a hover/keyboard label. */
export function IconButton({ label, tooltip = label, tooltipAlign = "right", tooltipSide = "bottom", className = "", children, ...props }: Props) {
  const [dismissed, setDismissed] = useState(false);
  return (
    <span className="group/icon relative inline-flex shrink-0"
      onMouseLeave={() => setDismissed(false)}
      onBlur={() => setDismissed(false)}
      onKeyDown={(event) => {
        if (event.key === "Escape" && !dismissed) {
          event.stopPropagation();
          setDismissed(true);
        }
      }}>

      <button
        type="button"
        {...props}
        aria-label={label}
        className={`tap-target rounded-lg transition-colors focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-accent disabled:opacity-50 ${className}`}
      >
        {children}
      </button>
      <span aria-hidden="true" className={`${dismissed ? "hidden" : "opacity-0 pointer-events-none group-hover/icon:opacity-100 group-hover/icon:pointer-events-auto group-focus-within/icon:opacity-100 group-focus-within/icon:pointer-events-auto"} absolute ${tooltipAlign === "left" ? "left-0" : "right-0"} ${tooltipSide === "top" ? "bottom-full pb-1" : "top-full pt-1"} z-50 w-max max-w-56`}>
        <span className="block rounded-md border border-border bg-bg-tertiary px-2 py-1 text-xs text-text-primary shadow-lg">{tooltip}</span>
      </span>
    </span>
  );
}

export function RefreshIcon({ spinning = false }: { spinning?: boolean }) {
  return <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true" className={spinning ? "motion-safe:animate-spin" : undefined}>
    <path d="M20 7v5h-5M4 17v-5h5" />
    <path d="M6.1 7a7 7 0 0 1 11.5-1L20 9M4 15l2.4 3A7 7 0 0 0 17.9 17" />
  </svg>;
}
