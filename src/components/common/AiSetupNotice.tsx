import { useUiStore } from "../../stores/uiStore";

export function isAiSetupError(error: string | null): boolean {
  if (!error) return false;
  const message = error.toLowerCase();
  return ["[configure-ai]", "no ai provider configured", "no local model selected",
    "api key not set", "not signed in", "sign in again", "[claude-reauth]"].some((text) => message.includes(text));
}

export function AiSetupNotice({ error }: { error?: string | null }) {
  const openSettings = useUiStore((s) => s.setShowSettings);
  const reconnect = !!error && /not signed in|sign in again|reauth/i.test(error);
  const missingModel = !!error && /not downloaded/i.test(error);
  const detail = error?.replace(/\[(?:configure-ai|claude-reauth)\]\s*/gi, "").trim();
  return (
    <section className="rounded-xl border border-border bg-bg-tertiary" style={{ padding: 24 }} aria-label="AI setup" role={error ? "alert" : "status"}>
      <h4 className="text-text-primary" style={{ fontSize: 18, fontWeight: 600, marginBottom: 8 }}>
        {missingModel ? "Download your selected model" : reconnect ? "Reconnect your AI provider" : error ? "AI needs attention" : "Set up AI to continue"}
      </h4>
      <p className="text-text-secondary" style={{ fontSize: 14, lineHeight: 1.6, maxWidth: 440, marginBottom: 20 }}>
        {missingModel ? "Your AI provider is configured, but the selected model is not downloaded. Open AI settings, download the model, then return here to retry."
          : reconnect ? "Your sign-in needs attention. Open AI settings to reconnect, then return here."
          : error ? "Open AI settings to resolve the issue below, then return here to retry."
          : "Choose a provider and model in AI settings. When you close settings, you’ll return here to continue."}
      </p>
      {detail && <p className="text-text-secondary break-words" style={{ fontSize: 12, marginBottom: 16 }}>{detail}</p>}
      <button onClick={() => openSettings(true)} className="rounded-lg bg-accent text-bg-primary hover:bg-accent-hover focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-accent" style={{ minHeight: 44, padding: "10px 16px", fontSize: 14, fontWeight: 600 }}>
        Open AI settings
      </button>
    </section>
  );
}
