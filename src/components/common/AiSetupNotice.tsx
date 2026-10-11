import { useUiStore } from "../../stores/uiStore";

export function isAiSetupError(error: string | null): boolean {
  if (!error) return false;
  const message = error.toLowerCase();
  return ["[configure-ai]", "no ai provider configured", "no local model selected",
    "api key not set", "not signed in", "sign in again", "[claude-reauth]"].some((text) => message.includes(text));
}

export function AiSetupNotice({ error }: { error?: string | null }) {
  const isPhone = useUiStore((s) => s.isPhone);
  const openSettings = useUiStore((s) => s.setShowSettings);
  const reconnect = !!error && /not signed in|sign in again|reauth/i.test(error);
  const missingModel = !!error && /not downloaded/i.test(error);
  const detail = error?.replace(/\[(?:configure-ai|claude-reauth)\]\s*/gi, "").trim();
  return (
    <section className={isPhone ? "rounded-xl border border-border bg-bg-tertiary" : "flex items-start justify-between flex-wrap"} style={{ padding: isPhone ? 24 : 0, gap: 16 }} aria-label="AI setup" role={error ? "alert" : "status"}>
      <div style={{ flex: isPhone ? undefined : "1 1 280px", minWidth: 0 }}>
        <h4 className="text-text-primary" style={{ fontSize: isPhone ? 18 : 14, fontWeight: 600, marginBottom: isPhone ? 8 : 4 }}>
          {missingModel ? "Download your selected model" : reconnect ? "Reconnect your AI provider" : error ? "AI needs attention" : "Set up AI to continue"}
        </h4>
        <p className="text-text-secondary" style={{ fontSize: isPhone ? 14 : 13, lineHeight: 1.5, maxWidth: 440, marginBottom: isPhone ? 20 : 0 }}>
          {missingModel ? "Your AI provider is configured, but the selected model is not downloaded. Open AI settings, download the model, then return here to retry."
            : reconnect ? "Your sign-in needs attention. Open AI settings to reconnect, then return here."
            : error ? "Open AI settings to resolve the issue below, then return here to retry."
            : "Choose a provider and model to get started."}
        </p>
        {detail && <p className="text-text-secondary break-words" style={{ fontSize: 12, marginTop: 8, marginBottom: isPhone ? 16 : 0 }}>{detail}</p>}
      </div>
      <button
        onClick={() => openSettings(true)}
        aria-label="Open AI settings"
        title="Open AI settings"
        className="inline-flex items-center justify-center rounded-lg text-text-secondary hover:text-text-primary hover:bg-white/10 focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-accent"
        style={{ width: "var(--skim-control-height, 44px)", height: "var(--skim-control-height, 44px)", flexShrink: 0 }}
      >
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
          <path d="m9.5 3-.6 2.4-2.1 1.2-2.4-.7-2.5 4.2 1.8 1.8v2.4l-1.8 1.8 2.5 4.2 2.4-.7 2.1 1.2.6 2.4h5l.6-2.4 2.1-1.2 2.4.7 2.5-4.2-1.8-1.8v-2.4l1.8-1.8-2.5-4.2-2.4.7-2.1-1.2L14.5 3Z" transform="translate(0 -1.1)" />
          <circle cx="12" cy="12" r="3" />
        </svg>
      </button>
    </section>
  );
}
