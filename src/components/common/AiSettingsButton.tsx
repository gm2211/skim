import type { CSSProperties } from "react";
import { useUiStore } from "../../stores/uiStore";
import { IconButton } from "./IconButton";
import { CogIcon } from "../ui/icons";

/** Opens Settings on the AI provider tab, over whatever is open, so closing it returns here. */
export const openAiSettings = () => useUiStore.getState().setShowSettings(true, "ai");

/** A cog for the header of any surface that calls AI: opens AI provider settings. */
export function AiSettingsButton({ size = 16, className = "", tooltipAlign }: {
  size?: number;
  className?: string;
  tooltipAlign?: "left" | "right";
}) {
  return (
    <IconButton
      label="AI settings"
      tooltipAlign={tooltipAlign}
      onClick={openAiSettings}
      className={`text-text-muted hover:text-text-primary hover:bg-white/10 ${className}`}
    >
      <CogIcon size={size} />
    </IconButton>
  );
}

/** A rate limit or overload: asking again later is the fix, not settings. */
export function isBusyAiError(error: string): boolean {
  const lower = error.toLowerCase();
  return ["rate limit", "usage limit", "overloaded"].some((marker) => lower.includes(marker));
}

/** An AI error, with the button that opens AI provider settings to fix it. */
export function AiErrorText({ error, stacked = false, style, className = "", onRetry }: {
  error: string;
  /** Button under the message, for narrow columns such as the sidebar. */
  stacked?: boolean;
  style?: CSSProperties;
  className?: string;
  /** Shows "Try again" first, for an error that asking again can fix. */
  onRetry?: () => void;
}) {
  return (
    <div role="alert" className={`flex ${stacked ? "flex-col items-start gap-2" : `items-start gap-3 ${onRetry ? "flex-wrap" : ""}`} ${className}`} style={{ fontSize: 12, ...style }}>
      {/* With two buttons, a narrow column puts them under the message rather than squeezing it. */}
      <p className={`${onRetry ? "text-text-primary" : "text-danger"} min-w-0 break-words ${stacked ? "" : "flex-1"}`} style={{ lineHeight: 1.5, minWidth: onRetry && !stacked ? "min(16rem, 100%)" : undefined }}>{error}</p>
      {onRetry ? (
        <div className="flex flex-none items-start gap-2">
          <button
            type="button"
            onClick={onRetry}
            className="inline-flex flex-none items-center gap-1.5 rounded-lg bg-accent/20 text-accent hover:bg-accent/30 transition-colors whitespace-nowrap"
            style={{ padding: "4px 10px", fontSize: 12 }}
          >
            Try again
          </button>
          <AiSettingsTextButton />
        </div>
      ) : (
        <AiSettingsTextButton />
      )}
    </div>
  );
}

function AiSettingsTextButton() {
  return (
    <button
      type="button"
      onClick={openAiSettings}
      className="inline-flex flex-none items-center gap-1.5 rounded-lg border border-white/10 text-text-primary hover:bg-white/10 transition-colors whitespace-nowrap"
      style={{ padding: "4px 10px", fontSize: 12 }}
    >
      <CogIcon size={13} />
      AI settings
    </button>
  );
}
