import { useState, useEffect } from "react";
import { listen } from "@tauri-apps/api/event";
import { useSettings, useUpdateSettings } from "../../hooks/useSettings";
import { useUiStore } from "../../stores/uiStore";
import type { AppSettings, FeedlyConnectionStatus } from "../../services/types";
import {
  claudeOauthBeginPaste,
  claudeOauthExchangePaste,
  claudeOauthSignInLoopback,
  claudeOauthSignOut,
  claudeOauthStatus,
  disconnectFeedly,
  feedlyOauthAvailable,
  feedlyOauthLogin,
  fmIsAvailable,
  getFeedlyStatus,
  mlxDeleteModel,
  mlxDownloadModel,
  mlxIsAvailable,
  mlxIsModelDownloaded,
  MLX_DOWNLOAD_PROGRESS_EVENT,
  type MlxDownloadProgress,
} from "../../services/commands";
import { ModelBrowser } from "./ModelBrowser";
import { NumberInput } from "../ui/NumberInput";
import { AIDisclaimer } from "../common/AIDisclaimer";
import { isIOS } from "../../utils/platform";

const AI_PROVIDERS = [
  { value: "none", label: "None", description: "AI features disabled" },
  { value: "local", label: "Local (Embedded)", description: "Run AI locally with llama.cpp — no server needed" },
  { value: "mlx", label: "On-device (MLX)", description: "Qwen 2.5 3B running on-device via MLX. Offline. ~2GB download. iOS/macOS only." },
  { value: "foundation-models", label: "Apple Intelligence", description: "Apple's on-device model. No download. Requires iOS 26+ or macOS 15.1+ with Apple Intelligence." },
  { value: "ollama", label: "Ollama", description: "Local Ollama (default: localhost:11434)" },
  { value: "claude-subscription", label: "Claude Pro/Max (OAuth)", description: "Sign in with your Claude.ai account — no API key, no CLI. Works on desktop and iOS." },
  { value: "claude-cli", label: "Claude via CLI (legacy)", description: "Uses the local 'claude' CLI binary. Legacy path — prefer 'Claude Pro/Max (OAuth)'." },
  { value: "anthropic", label: "Claude (API Key)", description: "api.anthropic.com — requires API key with usage-based billing" },
  { value: "openai", label: "OpenAI", description: "api.openai.com" },
  { value: "openrouter", label: "OpenRouter", description: "openrouter.ai - access multiple models with one API key" },
  { value: "custom", label: "Custom", description: "Any OpenAI-compatible endpoint" },
];

type MlxModel = { repoId: string; label: string; sizeGb: number; phoneFriendly?: boolean };

// Sorted ascending by size — smallest models first so phone users see the
// recommended (small) options at the top of the dropdown.
const MLX_MODELS: MlxModel[] = [
  { repoId: "mlx-community/gemma-3-1b-it-4bit", label: "Gemma 3 1B (recommended for iPhone)", sizeGb: 0.7, phoneFriendly: true },
  { repoId: "mlx-community/Qwen2.5-1.5B-Instruct-4bit", label: "Qwen 2.5 1.5B", sizeGb: 1.0, phoneFriendly: true },
  { repoId: "mlx-community/Llama-3.2-1B-Instruct-4bit", label: "Llama 3.2 1B", sizeGb: 0.8, phoneFriendly: true },
  { repoId: "mlx-community/gemma-3-4b-it-4bit", label: "Gemma 3 4B", sizeGb: 2.4 },
  { repoId: "mlx-community/Qwen2.5-3B-Instruct-4bit", label: "Qwen 2.5 3B (desktop default)", sizeGb: 2.0 },
  { repoId: "mlx-community/Llama-3.2-3B-Instruct-4bit", label: "Llama 3.2 3B", sizeGb: 2.0 },
  { repoId: "mlx-community/Phi-3.5-mini-instruct-4bit", label: "Phi-3.5 Mini", sizeGb: 2.3 },
];

const needsApiKey = (provider: string) =>
  ["openai", "openrouter", "anthropic", "custom", "claude-cli"].includes(provider);

const needsEndpoint = (provider: string) =>
  ["ollama", "custom"].includes(provider);

type SettingsTab = "ai" | "sync" | "appearance";

const TABS: { id: SettingsTab; label: string; icon: React.ReactNode }[] = [
  {
    id: "ai",
    label: "AI Provider",
    icon: (
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5">
        <path d="M12 2a4 4 0 0 1 4 4v1a2 2 0 0 1 2 2v1a4 4 0 0 1-2.5 3.7M12 2a4 4 0 0 0-4 4v1a2 2 0 0 0-2 2v1a4 4 0 0 0 2.5 3.7M12 2v4M8.5 14.7A4 4 0 0 0 12 22a4 4 0 0 0 3.5-7.3" />
        <circle cx="12" cy="14" r="1" />
      </svg>
    ),
  },
  {
    id: "sync",
    label: "Sync",
    icon: (
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5">
        <path d="M21 2v6h-6M3 12a9 9 0 0 1 15-6.7L21 8M3 22v-6h6M21 12a9 9 0 0 1-15 6.7L3 16" />
      </svg>
    ),
  },
  {
    id: "appearance",
    label: "Appearance",
    icon: (
      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.5">
        <circle cx="12" cy="12" r="5" />
        <path d="M12 1v2M12 21v2M4.22 4.22l1.42 1.42M18.36 18.36l1.42 1.42M1 12h2M21 12h2M4.22 19.78l1.42-1.42M18.36 5.64l1.42-1.42" />
      </svg>
    ),
  },
];

function InputField({
  label,
  description,
  children,
}: {
  label: string;
  description?: string;
  children: React.ReactNode;
}) {
  return (
    <div style={{ marginBottom: 24 }}>
      <label className="block text-text-primary" style={{ fontSize: 14, fontWeight: 500, marginBottom: 6 }}>
        {label}
      </label>
      {children}
      {description && (
        <p className="text-text-muted" style={{ fontSize: 12, marginTop: 6 }}>
          {description}
        </p>
      )}
    </div>
  );
}

export function SettingsDialog() {
  const { data: settings } = useSettings();
  const updateSettings = useUpdateSettings();
  const setShowSettings = useUiStore((s) => s.setShowSettings);
  const isPhone = useUiStore((s) => s.isPhone);

  const [local, setLocal] = useState<AppSettings | null>(null);
  const [activeTab, setActiveTab] = useState<SettingsTab>("ai");

  useEffect(() => {
    if (settings && !local) {
      setLocal(settings);
    }
  }, [settings]);

  if (!local) return null;

  const handleSave = async () => {
    await updateSettings.mutateAsync(local);
    setShowSettings(false);
  };

  const updateAi = (patch: Partial<AppSettings["ai"]>) =>
    setLocal({ ...local, ai: { ...local.ai, ...patch } });

  const inputStyle = {
    background: "rgba(255, 255, 255, 0.05)",
    padding: "10px 14px",
    fontSize: 14,
  };

  const inputClass =
    "w-full border border-white/10 rounded-xl text-text-primary placeholder-text-muted focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/30 transition-colors";

  return (
    <div
      className={
        isPhone
          ? "fixed inset-0 z-50 flex flex-col bg-bg-primary"
          : "fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center z-50"
      }
      style={
        isPhone
          ? {
              paddingTop: "env(safe-area-inset-top)",
              paddingBottom: "env(safe-area-inset-bottom)",
              paddingLeft: "env(safe-area-inset-left)",
              paddingRight: "env(safe-area-inset-right)",
            }
          : undefined
      }
    >
      <div
        className={
          isPhone
            ? "flex flex-col flex-1 min-h-0 overflow-hidden"
            : "border border-white/10 rounded-2xl w-full max-w-2xl mx-4 shadow-2xl overflow-hidden flex flex-col backdrop-blur-xl backdrop-saturate-150"
        }
        style={
          isPhone
            ? undefined
            : { background: "rgba(22, 27, 34, 0.75)", height: local.ai.provider === "local" ? 640 : 520 }
        }
      >
        {/* Header */}
        <div className="flex items-center justify-between border-b border-white/5" style={{ padding: "16px 24px" }}>
          <h2 style={{ fontSize: 18, fontWeight: 600 }} className="text-text-primary">Settings</h2>
          <button
            onClick={() => setShowSettings(false)}
            className="text-text-muted hover:text-text-primary p-1.5 rounded-lg hover:bg-white/10 transition-colors"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M18 6L6 18M6 6l12 12" />
            </svg>
          </button>
        </div>

        {/* Body: sidebar tabs + content (or stacked on phone) */}
        <div className={`flex flex-1 min-h-0 ${isPhone ? "flex-col" : ""}`}>
          {/* Tab bar — vertical on desktop, horizontal scroller on phone */}
          <div
            className={
              isPhone
                ? "flex border-b border-white/5 overflow-x-auto"
                : "border-r border-white/5 flex flex-col"
            }
            style={isPhone ? { padding: "8px 8px" } : { width: 180, padding: "12px 8px" }}
          >
            {TABS.map((tab) => (
              <button
                key={tab.id}
                onClick={() => setActiveTab(tab.id)}
                className={`flex items-center gap-3 ${isPhone ? "flex-shrink-0" : "w-full"} rounded-lg text-left transition-colors ${
                  activeTab === tab.id
                    ? "bg-white/10 text-text-primary"
                    : "text-text-muted hover:text-text-primary hover:bg-white/5"
                }`}
                style={{ padding: "10px 12px", fontSize: 14 }}
              >
                <span className="opacity-70">{tab.icon}</span>
                <span>{tab.label}</span>
              </button>
            ))}
          </div>

          {/* Content pane */}
          <div className="flex-1 overflow-y-auto" style={{ padding: isPhone ? "16px 16px 24px" : "24px 28px" }}>
            {activeTab === "ai" && (
              <>
                <h3 className="text-text-primary" style={{ fontSize: 16, fontWeight: 600, marginBottom: 12 }}>
                  AI Provider
                </h3>

                <div style={{ marginBottom: 18 }}>
                  <AIDisclaimer variant="block" />
                </div>

                <InputField label="Provider">
                  <select
                    value={local.ai.provider}
                    onChange={(e) => updateAi({ provider: e.target.value })}
                    className={inputClass}
                    style={inputStyle}
                  >
                    {AI_PROVIDERS.filter((p) => {
                      // mlx + Apple Intelligence are only wired on the iOS
                      // bundle (Skim Swift plugin); hide on macOS/desktop.
                      if (!isIOS && ["mlx", "foundation-models"].includes(p.value)) return false;
                      // Phone: hide providers that need a desktop runtime
                      // (llama.cpp embedded, Ollama localhost, Claude CLI).
                      if (!isPhone) return true;
                      return !["local", "ollama", "claude-cli"].includes(p.value);
                    }).map((p) => (
                      <option key={p.value} value={p.value}>
                        {p.label}
                      </option>
                    ))}
                  </select>
                  <p className="text-text-muted" style={{ fontSize: 12, marginTop: 6 }}>
                    {AI_PROVIDERS.find((p) => p.value === local.ai.provider)?.description}
                  </p>
                  <details
                    className="text-text-muted"
                    style={{ fontSize: 12, marginTop: 8 }}
                  >
                    <summary
                      className="cursor-pointer hover:text-text-primary"
                      style={{ userSelect: "none" }}
                    >
                      How are on-device and cloud providers combined?
                    </summary>
                    <p style={{ marginTop: 6, lineHeight: 1.5 }}>
                      On-device tiers handle triage and summaries;
                      quality-sensitive tasks (chat, themes, auto-organize)
                      fall back to your cloud provider if both are configured.
                    </p>
                  </details>
                </InputField>

                {local.ai.provider === "local" && (
                  <ModelBrowser ai={local.ai} updateAi={updateAi} />
                )}

                {local.ai.provider === "mlx" && (
                  <OnDeviceTierSection ai={local.ai} updateAi={updateAi} />
                )}

                {local.ai.provider === "foundation-models" && (
                  <FoundationModelsSection />
                )}

                {needsApiKey(local.ai.provider) && (
                  <InputField
                    label={local.ai.provider === "claude-cli" ? "Setup Token (optional)" : "API Key"}
                    description={
                      local.ai.provider === "claude-cli"
                        ? "Leave blank to use your existing Claude Pro/Max subscription via 'claude -p'. Only paste a token here if you want to authenticate with an ANTHROPIC_API_KEY instead (run 'claude setup-token' to get one)."
                        : undefined
                    }
                  >
                    <input
                      type="password"
                      value={local.ai.api_key ?? ""}
                      onChange={(e) => updateAi({ api_key: e.target.value.trim() || null })}
                      placeholder={local.ai.provider === "claude-cli" ? "Leave blank for subscription auth" : "sk-..."}
                      className={inputClass}
                      style={inputStyle}
                    />
                  </InputField>
                )}

                {local.ai.provider === "claude-cli" && (
                  <div
                    className="rounded-lg border border-accent/30 bg-accent/5"
                    style={{ padding: "10px 12px", fontSize: 12, lineHeight: 1.5 }}
                  >
                    <p className="text-text-primary" style={{ fontWeight: 500, marginBottom: 4 }}>
                      How it works
                    </p>
                    <p className="text-text-muted">
                      Skim runs <code className="text-accent">claude -p "..."</code> under the hood. If the{" "}
                      <code className="text-accent">claude</code> CLI is already signed into your Pro/Max
                      account, nothing else is needed. Install with{" "}
                      <code className="text-accent">npm i -g @anthropic-ai/claude-code</code> then run{" "}
                      <code className="text-accent">claude</code> once to sign in.
                    </p>
                  </div>
                )}

                {local.ai.provider === "claude-subscription" && (
                  <div style={{ marginBottom: 20 }}>
                    <ClaudeOAuthSection />
                  </div>
                )}

                {needsEndpoint(local.ai.provider) && (
                  <InputField label="Endpoint URL">
                    <input
                      type="url"
                      value={local.ai.endpoint ?? ""}
                      onChange={(e) => updateAi({ endpoint: e.target.value || null })}
                      placeholder={
                        local.ai.provider === "ollama"
                          ? "http://localhost:11434"
                          : "https://api.example.com"
                      }
                      className={inputClass}
                      style={inputStyle}
                    />
                  </InputField>
                )}

                {local.ai.provider !== "none" && local.ai.provider !== "local" && (
                  <InputField
                    label="Model"
                    description="Leave blank for default model"
                  >
                    <input
                      type="text"
                      value={local.ai.model ?? ""}
                      onChange={(e) => updateAi({ model: e.target.value || null })}
                      placeholder={
                        local.ai.provider === "openai"
                          ? "gpt-4o-mini"
                          : local.ai.provider === "openrouter"
                            ? "anthropic/claude-3.5-sonnet"
                            : local.ai.provider === "ollama"
                              ? "llama3"
                              : local.ai.provider === "claude-cli"
                                ? "sonnet"
                                : "model-name"
                      }
                      className={inputClass}
                      style={inputStyle}
                    />
                  </InputField>
                )}

                {local.ai.provider !== "none" && (
                  <>
                    <div className="border-t border-white/5" style={{ margin: "24px 0" }} />
                    <h3 className="text-text-primary" style={{ fontSize: 16, fontWeight: 600, marginBottom: 20 }}>
                      Summary
                    </h3>

                    <div className="flex gap-4" style={{ marginBottom: 24 }}>
                      <InputField label="Length">
                        <select
                          value={local.ai.summary_length ?? "short"}
                          onChange={(e) => updateAi({ summary_length: e.target.value })}
                          className={inputClass}
                          style={{ ...inputStyle, width: 140 }}
                        >
                          <option value="short">Short (~30 words)</option>
                          <option value="medium">Medium (~150 words)</option>
                          <option value="long">Long (~300 words)</option>
                          <option value="custom">Custom...</option>
                        </select>
                        {local.ai.summary_length === "custom" && (
                          <NumberInput
                            min={20}
                            max={1000}
                            placeholder="Word count"
                            value={local.ai.summary_custom_word_count ?? null}
                            onChange={(n) => updateAi({ summary_custom_word_count: n } as any)}
                            className={inputClass}
                            style={{ ...inputStyle, width: 120, marginTop: 6 }}
                          />
                        )}
                      </InputField>

                      <InputField label="Tone">
                        <select
                          value={local.ai.summary_tone ?? "concise"}
                          onChange={(e) => updateAi({ summary_tone: e.target.value })}
                          className={inputClass}
                          style={{ ...inputStyle, width: 140 }}
                        >
                          <option value="concise">Concise</option>
                          <option value="detailed">Detailed</option>
                          <option value="casual">Casual</option>
                          <option value="technical">Technical</option>
                        </select>
                      </InputField>

                    </div>

                    <InputField
                      label="Custom prompt"
                      description="Override the default summary system prompt. Leave blank to use defaults."
                    >
                      <textarea
                        value={local.ai.summary_custom_prompt ?? ""}
                        onChange={(e) => updateAi({ summary_custom_prompt: e.target.value || null })}
                        placeholder="e.g. You summarize articles for a technical audience. Focus on data and methodology..."
                        className={inputClass}
                        style={{ ...inputStyle, minHeight: 72, resize: "vertical" }}
                        rows={3}
                      />
                    </InputField>

                    <div className="border-t border-white/5" style={{ margin: "24px 0" }} />
                    <h3 className="text-text-primary" style={{ fontSize: 16, fontWeight: 600, marginBottom: 20 }}>
                      AI Inbox — What you care about
                    </h3>

                    <InputField
                      label="Your interests"
                      description="This prompt runs alongside the preferences learned from your reading habits."
                    >
                      <textarea
                        value={local.ai.triage_user_prompt ?? ""}
                        onChange={(e) => updateAi({ triage_user_prompt: e.target.value || null })}
                        placeholder="e.g., Prioritize distributed systems, Rust/Go internals, Claude/Anthropic news. Deprioritize crypto drama and celebrity tech."
                        className={inputClass}
                        style={{ ...inputStyle, minHeight: 120, resize: "vertical" }}
                        rows={5}
                      />
                    </InputField>
                  </>
                )}
              </>
            )}

            {activeTab === "sync" && (
              <SyncTab local={local} setLocal={setLocal} inputClass={inputClass} inputStyle={inputStyle} />
            )}

            {activeTab === "appearance" && (
              <>
                <h3 className="text-text-primary" style={{ fontSize: 16, fontWeight: 600, marginBottom: 20 }}>
                  Appearance
                </h3>
                <label
                  className="flex items-start gap-3 cursor-pointer"
                  style={{ marginBottom: 16 }}
                >
                  <input
                    type="checkbox"
                    checked={local.appearance?.show_excerpt_in_list ?? false}
                    onChange={(e) =>
                      setLocal({
                        ...local,
                        appearance: {
                          ...local.appearance,
                          show_excerpt_in_list: e.target.checked,
                        },
                      })
                    }
                    className="accent-accent flex-shrink-0"
                    style={{ marginTop: 3 }}
                  />
                  <div>
                    <div className="text-text-primary" style={{ fontSize: 14, fontWeight: 500 }}>
                      Show excerpt under titles
                    </div>
                    <div className="text-text-muted" style={{ fontSize: 12, marginTop: 2 }}>
                      Renders a 2-line snippet from the article body in list
                      rows. Off by default — titles stay easier to scan.
                    </div>
                  </div>
                </label>
              </>
            )}
          </div>
        </div>

        {/* Footer */}
        <div className="flex justify-end gap-3 border-t border-white/5" style={{ padding: "14px 24px" }}>
          <button
            onClick={() => setShowSettings(false)}
            className="text-text-secondary hover:text-text-primary rounded-xl hover:bg-white/5 transition-colors"
            style={{ padding: "10px 20px", fontSize: 14 }}
          >
            Cancel
          </button>
          <button
            onClick={handleSave}
            disabled={updateSettings.isPending}
            className="bg-accent text-white rounded-xl hover:bg-accent-hover disabled:opacity-40 font-medium transition-colors"
            style={{ padding: "10px 24px", fontSize: 14 }}
          >
            {updateSettings.isPending ? "Saving..." : "Save"}
          </button>
        </div>
      </div>
    </div>
  );
}

function SyncTab({
  local,
  setLocal,
  inputClass,
  inputStyle,
}: {
  local: AppSettings;
  setLocal: (s: AppSettings) => void;
  inputClass: string;
  inputStyle: React.CSSProperties;
}) {
  const [feedlyStatus, setFeedlyStatus] = useState<FeedlyConnectionStatus | null | undefined>(undefined);
  const [connecting, setConnecting] = useState(false);
  const [feedlyError, setFeedlyError] = useState<string | null>(null);
  const [oauthAvailable, setOauthAvailable] = useState(false);

  useEffect(() => {
    getFeedlyStatus().then(setFeedlyStatus).catch(() => setFeedlyStatus(null));
    feedlyOauthAvailable().then(setOauthAvailable).catch(() => {});
  }, []);

  const handleLogin = async () => {
    setConnecting(true);
    setFeedlyError(null);
    try {
      const profile = await feedlyOauthLogin();
      setFeedlyStatus({
        connected: true,
        email: profile.email,
        full_name: profile.full_name,
      });
    } catch (e) {
      setFeedlyError(String(e instanceof Error ? e.message : e));
    } finally {
      setConnecting(false);
    }
  };

  const handleDisconnect = async () => {
    await disconnectFeedly();
    setFeedlyStatus(null);
  };

  const showFeedlySection = oauthAvailable || feedlyStatus?.connected;

  return (
    <>
      {showFeedlySection && (
        <>
          <h3 className="text-text-primary" style={{ fontSize: 16, fontWeight: 600, marginBottom: 20 }}>
            Feedly
          </h3>

          {feedlyStatus?.connected ? (
            <div style={{ marginBottom: 24 }}>
              <div
                className="rounded-xl border border-green-500/20"
                style={{ padding: "14px 16px", marginBottom: 12, background: "rgba(34, 197, 94, 0.06)" }}
              >
                <div className="flex items-center gap-2" style={{ marginBottom: 4 }}>
                  <div className="w-2 h-2 rounded-full bg-green-500" />
                  <span className="text-text-primary" style={{ fontSize: 14, fontWeight: 500 }}>Connected</span>
                </div>
                <p className="text-text-muted" style={{ fontSize: 13 }}>
                  {feedlyStatus.full_name || feedlyStatus.email || "Feedly account"}
                </p>
              </div>
              <button
                onClick={handleDisconnect}
                className="text-danger hover:text-red-400 rounded-xl hover:bg-red-500/10 transition-colors"
                style={{ padding: "8px 16px", fontSize: 13 }}
              >
                Disconnect Feedly
              </button>
            </div>
          ) : (
            <div style={{ marginBottom: 24 }}>
              <p className="text-text-muted" style={{ fontSize: 12, marginBottom: 12 }}>
                Connect your Feedly account to sync read state and stars.
              </p>
              <button
                onClick={handleLogin}
                disabled={connecting}
                className="bg-accent text-white rounded-xl hover:bg-accent-hover disabled:opacity-40 font-medium transition-colors flex items-center gap-2 w-fit"
                style={{ padding: "10px 20px", fontSize: 13, marginBottom: 12 }}
              >
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <path d="M15 3h6v6M10 14L21 3M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" />
                </svg>
                {connecting ? "Waiting for browser..." : "Sign in with Feedly"}
              </button>
              {feedlyError && (
                <div
                  className="rounded-xl border border-danger/30 text-danger"
                  style={{ padding: "10px 14px", fontSize: 13, background: "rgba(248, 81, 73, 0.1)" }}
                >
                  {feedlyError}
                </div>
              )}
            </div>
          )}

          <div className="border-t border-white/5" style={{ margin: "24px 0" }} />
        </>
      )}

      <h3 className="text-text-primary" style={{ fontSize: 16, fontWeight: 600, marginBottom: 20 }}>
        Refresh
      </h3>

      <InputField
        label="Auto-refresh interval"
        description="How often to check feeds for new articles (in minutes)"
      >
        <NumberInput
          min={5}
          max={1440}
          value={local.sync.refresh_interval_minutes}
          fallback={30}
          onChange={(n) =>
            setLocal({
              ...local,
              sync: {
                ...local.sync,
                refresh_interval_minutes: n,
              },
            })
          }
          className={inputClass}
          style={{ ...inputStyle, width: 120 }}
        />
      </InputField>

      <InputField
        label="Max articles per feed"
        description="Number of articles to keep per feed"
      >
        <NumberInput
          min={10}
          max={1000}
          value={local.sync.max_articles_per_feed}
          fallback={200}
          onChange={(n) =>
            setLocal({
              ...local,
              sync: {
                ...local.sync,
                max_articles_per_feed: n,
              },
            })
          }
          className={inputClass}
          style={{ ...inputStyle, width: 120 }}
        />
      </InputField>
    </>
  );
}

function ClaudeOAuthSection() {
  const [signedIn, setSignedIn] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [pasteCode, setPasteCode] = useState("");
  const [authorizeUrl, setAuthorizeUrl] = useState<string | null>(null);
  const isPhone = useUiStore((s) => s.isPhone);

  useEffect(() => {
    claudeOauthStatus().then(setSignedIn).catch(() => setSignedIn(false));
  }, []);

  const signInLoopback = async () => {
    setBusy(true);
    setError(null);
    try {
      await claudeOauthSignInLoopback();
      setSignedIn(true);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const beginPaste = async () => {
    setBusy(true);
    setError(null);
    try {
      const r = await claudeOauthBeginPaste();
      setAuthorizeUrl(r.authorizeUrl);
      const { openUrl } = await import("@tauri-apps/plugin-opener");
      try {
        await openUrl(r.authorizeUrl);
      } catch {
        window.open(r.authorizeUrl, "_blank");
      }
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const exchangePaste = async () => {
    setBusy(true);
    setError(null);
    try {
      await claudeOauthExchangePaste(pasteCode.trim());
      setSignedIn(true);
      setAuthorizeUrl(null);
      setPasteCode("");
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const signOut = async () => {
    await claudeOauthSignOut();
    setSignedIn(false);
  };

  if (signedIn) {
    return (
      <div
        className="rounded-lg border border-green-500/30 bg-green-500/5"
        style={{ padding: "10px 12px", fontSize: 12, lineHeight: 1.5 }}
      >
        <p className="text-text-primary" style={{ fontWeight: 500, marginBottom: 4 }}>
          Signed in with Claude
        </p>
        <p className="text-text-muted" style={{ marginBottom: 8 }}>
          Using your Claude Pro/Max subscription. No API key, no CLI.
        </p>
        <button
          type="button"
          onClick={signOut}
          className="rounded border border-red-500/40 text-red-400 hover:bg-red-500/10"
          style={{ padding: "4px 10px", fontSize: 12 }}
        >
          Sign out
        </button>
      </div>
    );
  }

  return (
    <div
      className="rounded-lg border border-accent/30 bg-accent/5"
      style={{ padding: "10px 12px", fontSize: 12, lineHeight: 1.5 }}
    >
      <p className="text-text-primary" style={{ fontWeight: 500, marginBottom: 4 }}>
        Sign in with Claude
      </p>
      <p className="text-text-muted" style={{ marginBottom: 8 }}>
        Uses your Claude.ai Pro or Max account via OAuth. No API key required.
      </p>
      <div style={{ display: "flex", gap: 8, marginBottom: 8, flexWrap: "wrap" }}>
        {!isPhone && (
          <button
            type="button"
            disabled={busy}
            onClick={signInLoopback}
            className="rounded border border-accent text-accent hover:bg-accent/10 disabled:opacity-40"
            style={{ padding: "4px 10px", fontSize: 12 }}
          >
            {busy ? "Signing in…" : "Sign in (desktop)"}
          </button>
        )}
        <button
          type="button"
          disabled={busy}
          onClick={beginPaste}
          className="rounded border border-accent/50 text-accent hover:bg-accent/10 disabled:opacity-40"
          style={{ padding: "4px 10px", fontSize: 12 }}
        >
          {isPhone ? (busy ? "Signing in…" : "Sign in") : "Sign in (copy-paste)"}
        </button>
      </div>
      {authorizeUrl && (
        <div style={{ marginTop: 8 }}>
          <p className="text-text-muted" style={{ marginBottom: 6 }}>
            Complete sign-in in the browser tab that opened, then paste the code shown on the success page here.
          </p>
          <input
            type="text"
            value={pasteCode}
            onChange={(e) => setPasteCode(e.target.value)}
            placeholder="code#state"
            className="w-full rounded border border-border bg-bg-secondary text-text-primary"
            style={{
              padding: "6px 10px",
              fontSize: 13,
              fontFamily: "ui-monospace, SFMono-Regular, monospace",
              marginBottom: 6,
            }}
          />
          <button
            type="button"
            disabled={busy || !pasteCode.trim()}
            onClick={exchangePaste}
            className="rounded border border-accent text-accent hover:bg-accent/10 disabled:opacity-40"
            style={{ padding: "4px 10px", fontSize: 12 }}
          >
            {busy ? "Exchanging…" : "Finish sign-in"}
          </button>
        </div>
      )}
      {error && (
        <p className="text-red-400" style={{ marginTop: 8 }}>
          {error}
        </p>
      )}
    </div>
  );
}

function OnDeviceTierSection({
  ai,
  updateAi,
}: {
  ai: AppSettings["ai"];
  updateAi: (patch: Partial<AppSettings["ai"]>) => void;
}) {
  const [available, setAvailable] = useState<boolean | null>(null);
  const [downloaded, setDownloaded] = useState(false);
  const [checking, setChecking] = useState(false);
  const [busy, setBusy] = useState(false);
  const [progress, setProgress] = useState<MlxDownloadProgress | null>(null);
  const [error, setError] = useState<string | null>(null);

  const isPhone = useUiStore((s) => s.isPhone);
  const defaultModel = isPhone
    ? MLX_MODELS.find((m) => m.phoneFriendly) ?? MLX_MODELS[0]
    : MLX_MODELS.find((m) => m.repoId === "mlx-community/Qwen2.5-3B-Instruct-4bit") ?? MLX_MODELS[0];
  const selectedRepoId = ai.model ?? defaultModel.repoId;
  const selectedModel =
    MLX_MODELS.find((m) => m.repoId === selectedRepoId) ?? defaultModel;

  useEffect(() => {
    mlxIsAvailable().then(setAvailable).catch(() => setAvailable(false));
  }, []);

  useEffect(() => {
    let cancelled = false;
    setChecking(true);
    mlxIsModelDownloaded(selectedRepoId)
      .then((v) => {
        if (!cancelled) setDownloaded(v);
      })
      .catch(() => {
        if (!cancelled) setDownloaded(false);
      })
      .finally(() => {
        if (!cancelled) setChecking(false);
      });
    return () => {
      cancelled = true;
    };
  }, [selectedRepoId]);

  useEffect(() => {
    // iOS plugin emits via window.dispatchEvent (CustomEvent) — listen to
    // it directly. Desktop emits via Tauri's event bus, so subscribe to
    // both and let whichever path fires drive the bar.
    const onCustom = (e: Event) => {
      const detail = (e as CustomEvent).detail as { repoId?: string; percent?: number } | undefined;
      if (!detail) return;
      if (detail.repoId !== selectedRepoId) return;
      const pct = (detail.percent ?? 0) * 100;
      setProgress({ repoId: detail.repoId, downloaded: 0, total: 0, percent: pct });
    };
    window.addEventListener(MLX_DOWNLOAD_PROGRESS_EVENT, onCustom as EventListener);

    let unlisten: (() => void) | undefined;
    listen<MlxDownloadProgress>(MLX_DOWNLOAD_PROGRESS_EVENT, (e) => {
      if (e.payload.repoId === selectedRepoId) {
        setProgress(e.payload);
      }
    })
      .then((fn) => {
        unlisten = fn;
      })
      .catch(() => {});
    return () => {
      window.removeEventListener(MLX_DOWNLOAD_PROGRESS_EVENT, onCustom as EventListener);
      if (unlisten) unlisten();
    };
  }, [selectedRepoId]);

  const handleDownload = async () => {
    setBusy(true);
    setError(null);
    setProgress({ repoId: selectedRepoId, downloaded: 0, total: 0, percent: 0 });
    try {
      await mlxDownloadModel(selectedRepoId);
      setDownloaded(true);
      setProgress(null);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : String(e));
      setProgress(null);
    } finally {
      setBusy(false);
    }
  };

  const handleDelete = async () => {
    setBusy(true);
    setError(null);
    try {
      await mlxDeleteModel(selectedRepoId);
      setDownloaded(false);
    } catch (e: unknown) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  };

  const availabilityLabel =
    available === null
      ? "Checking availability…"
      : available
        ? "On-device MLX runtime detected"
        : "Not available — MLX needs a real iPhone (Metal GPU). For the iOS Simulator, pick a cloud provider above (OpenAI / Claude / OpenRouter).";

  return (
    <div
      className="rounded-lg border border-accent/30 bg-accent/5"
      style={{ padding: "10px 12px", fontSize: 12, lineHeight: 1.5, marginBottom: 24 }}
    >
      <div className="flex items-center gap-2" style={{ marginBottom: 8 }}>
        <div
          className="w-2 h-2 rounded-full"
          style={{
            background:
              available === null
                ? "rgba(255,255,255,0.3)"
                : available
                  ? "#22c55e"
                  : "#f87171",
          }}
        />
        <span className="text-text-primary" style={{ fontWeight: 500 }}>
          {availabilityLabel}
        </span>
      </div>

      <div style={{ marginBottom: 8 }}>
        <label
          className="block text-text-primary"
          style={{ fontSize: 12, fontWeight: 500, marginBottom: 4 }}
        >
          Model
        </label>
        <select
          value={selectedRepoId}
          onChange={(e) => updateAi({ model: e.target.value })}
          className="w-full border border-white/10 rounded text-text-primary focus:outline-none focus:border-accent/50"
          style={{
            background: "rgba(255, 255, 255, 0.05)",
            padding: "6px 10px",
            fontSize: 12,
          }}
          disabled={!available || busy}
        >
          {MLX_MODELS.filter((m) => !isPhone || m.phoneFriendly).map((m) => (
            <option key={m.repoId} value={m.repoId}>
              {m.label} — ~{m.sizeGb.toFixed(1)} GB
            </option>
          ))}
        </select>
        <p className="text-text-muted" style={{ fontSize: 12, marginTop: 4 }}>
          Storage estimate: ~{selectedModel.sizeGb.toFixed(1)} GB on disk.
        </p>
      </div>

      <div style={{ display: "flex", gap: 8, marginBottom: 8 }}>
        {!downloaded && (
          <button
            type="button"
            disabled={!available || busy || checking}
            onClick={handleDownload}
            className="rounded border border-accent text-accent hover:bg-accent/10 disabled:opacity-40"
            style={{ padding: "4px 10px", fontSize: 12 }}
          >
            {busy ? "Downloading…" : "Download"}
          </button>
        )}
        {downloaded && (
          <>
            <span
              className="rounded text-text-primary"
              style={{
                padding: "4px 10px",
                fontSize: 12,
                background: "rgba(34, 197, 94, 0.15)",
                border: "1px solid rgba(34, 197, 94, 0.3)",
              }}
            >
              Downloaded
            </span>
            <button
              type="button"
              disabled={busy}
              onClick={handleDelete}
              className="rounded border border-red-500/40 text-red-400 hover:bg-red-500/10 disabled:opacity-40"
              style={{ padding: "4px 10px", fontSize: 12 }}
            >
              {busy ? "Deleting…" : "Delete"}
            </button>
          </>
        )}
      </div>

      {progress && busy && (
        <div style={{ marginTop: 8 }}>
          <div
            className="w-full rounded"
            style={{
              height: 6,
              background: "rgba(255,255,255,0.08)",
              overflow: "hidden",
            }}
          >
            <div
              className="bg-accent"
              style={{
                height: "100%",
                width: `${Math.max(0, Math.min(100, progress.percent))}%`,
                transition: "width 120ms linear",
              }}
            />
          </div>
          <p className="text-text-muted" style={{ fontSize: 12, marginTop: 4 }}>
            {progress.percent.toFixed(1)}%
            {progress.total > 0 && (
              <>
                {" "}
                — {(progress.downloaded / 1e9).toFixed(2)} /{" "}
                {(progress.total / 1e9).toFixed(2)} GB
              </>
            )}
          </p>
        </div>
      )}

      {error && (
        <p className="text-red-400" style={{ marginTop: 8 }}>
          {error}
        </p>
      )}
    </div>
  );
}

function FoundationModelsSection() {
  const [available, setAvailable] = useState<boolean | null>(null);

  useEffect(() => {
    fmIsAvailable().then(setAvailable).catch(() => setAvailable(false));
  }, []);

  if (available === null) {
    return (
      <div
        className="rounded-lg border border-accent/30 bg-accent/5"
        style={{ padding: "10px 12px", fontSize: 12, lineHeight: 1.5, marginBottom: 24 }}
      >
        <p className="text-text-muted">Checking Apple Intelligence availability…</p>
      </div>
    );
  }

  if (!available) {
    return (
      <div
        className="rounded-lg border border-red-500/30 bg-red-500/5"
        style={{ padding: "10px 12px", fontSize: 12, lineHeight: 1.5, marginBottom: 24 }}
      >
        <p className="text-text-primary" style={{ fontWeight: 500, marginBottom: 4 }}>
          Not available on this device/OS
        </p>
        <p className="text-text-muted">
          Apple Intelligence requires iOS 26+ or macOS 15.1+ on supported hardware,
          with Apple Intelligence enabled in System Settings.
        </p>
      </div>
    );
  }

  return (
    <div
      className="rounded-lg border border-green-500/30 bg-green-500/5"
      style={{ padding: "10px 12px", fontSize: 12, lineHeight: 1.5, marginBottom: 24 }}
    >
      <div className="flex items-center gap-2" style={{ marginBottom: 4 }}>
        <div className="w-2 h-2 rounded-full bg-green-500" />
        <span className="text-text-primary" style={{ fontWeight: 500 }}>
          Available — Apple Intelligence enabled
        </span>
      </div>
      <p className="text-text-muted">
        Skim will use Apple's on-device Foundation Models for triage and
        summaries. No configuration or download needed — the model is managed
        by the system.
      </p>
    </div>
  );
}
