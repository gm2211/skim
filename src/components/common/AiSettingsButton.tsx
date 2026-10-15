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

/** An AI error, with the button that opens AI provider settings to fix it. */
export function AiErrorText({ error, stacked = false, style, className = "" }: {
  error: string;
  /** Button under the message, for narrow columns such as the sidebar. */
  stacked?: boolean;
  style?: CSSProperties;
  className?: string;
}) {
  return (
    <div role="alert" className={`flex ${stacked ? "flex-col items-start gap-2" : "items-start gap-3"} ${className}`} style={{ fontSize: 12, ...style }}>
      <p className={`text-danger min-w-0 break-words ${stacked ? "" : "flex-1"}`} style={{ lineHeight: 1.5 }}>{error}</p>
      <button
        type="button"
        onClick={openAiSettings}
        className="inline-flex flex-none items-center gap-1.5 rounded-lg border border-white/10 text-text-primary hover:bg-white/10 transition-colors whitespace-nowrap"
        style={{ padding: "4px 10px", fontSize: 12 }}
      >
        <CogIcon size={13} />
        AI settings
      </button>
    </div>
  );
}
