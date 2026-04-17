import { useState, useEffect } from "react";
import { useSettings, useUpdateSettings } from "../../hooks/useSettings";
import { useUiStore } from "../../stores/uiStore";
import type { AppSettings, FeedlyConnectionStatus } from "../../services/types";
import {
  connectFeedly,
  disconnectFeedly,
  feedlyOauthLogin,
  getFeedlyOauthConfig,
  getFeedlyStatus,
} from "../../services/commands";
import { ModelBrowser } from "./ModelBrowser";

const AI_PROVIDERS = [
  { value: "none", label: "None", description: "AI features disabled" },
  { value: "local", label: "Local (Embedded)", description: "Run AI locally with llama.cpp — no server needed" },
  { value: "ollama", label: "Ollama", description: "Local Ollama (default: localhost:11434)" },
  { value: "claude-cli", label: "Claude (Subscription)", description: "Uses Claude Code CLI — works with Pro/Max subscriptions" },
  { value: "anthropic", label: "Claude (API Key)", description: "api.anthropic.com — requires API key with usage-based billing" },
  { value: "openai", label: "OpenAI", description: "api.openai.com" },
  { value: "openrouter", label: "OpenRouter", description: "openrouter.ai - access multiple models with one API key" },
  { value: "custom", label: "Custom", description: "Any OpenAI-compatible endpoint" },
];

const needsApiKey = (provider: string) =>
  ["openai", "openrouter", "anthropic", "custom"].includes(provider);

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
    <div className="fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center z-50">
      <div
        className="border border-white/10 rounded-2xl w-full max-w-2xl mx-4 shadow-2xl overflow-hidden flex flex-col backdrop-blur-xl backdrop-saturate-150"
        style={{ background: "rgba(22, 27, 34, 0.75)", height: local.ai.provider === "local" ? 640 : 520 }}
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

        {/* Body: sidebar tabs + content */}
        <div className="flex flex-1 min-h-0">
          {/* Tab sidebar */}
          <div className="border-r border-white/5 flex flex-col" style={{ width: 180, padding: "12px 8px" }}>
            {TABS.map((tab) => (
              <button
                key={tab.id}
                onClick={() => setActiveTab(tab.id)}
                className={`flex items-center gap-3 w-full rounded-lg text-left transition-colors ${
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
          <div className="flex-1 overflow-y-auto" style={{ padding: "24px 28px" }}>
            {activeTab === "ai" && (
              <>
                <h3 className="text-text-primary" style={{ fontSize: 16, fontWeight: 600, marginBottom: 20 }}>
                  AI Provider
                </h3>

                <InputField label="Provider">
                  <select
                    value={local.ai.provider}
                    onChange={(e) => updateAi({ provider: e.target.value })}
                    className={inputClass}
                    style={inputStyle}
                  >
                    {AI_PROVIDERS.map((p) => (
                      <option key={p.value} value={p.value}>
                        {p.label}
                      </option>
                    ))}
                  </select>
                  <p className="text-text-muted" style={{ fontSize: 12, marginTop: 6 }}>
                    {AI_PROVIDERS.find((p) => p.value === local.ai.provider)?.description}
                  </p>
                </InputField>

                {local.ai.provider === "local" && (
                  <ModelBrowser ai={local.ai} updateAi={updateAi} />
                )}

                {needsApiKey(local.ai.provider) && (
                  <InputField
                    label={local.ai.provider === "claude-cli" ? "Setup Token" : "API Key"}
                    description={local.ai.provider === "claude-cli" ? "Run 'claude setup-token' in your terminal to get a token." : undefined}
                  >
                    <input
                      type="password"
                      value={local.ai.api_key ?? ""}
                      onChange={(e) => updateAi({ api_key: e.target.value.trim() || null })}
                      placeholder={local.ai.provider === "claude-cli" ? "Paste token from 'claude setup-token' (optional)" : "sk-..."}
                      className={inputClass}
                      style={inputStyle}
                    />
                  </InputField>
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
                          <input
                            type="number"
                            min={20}
                            max={1000}
                            placeholder="Word count"
                            value={local.ai.summary_custom_word_count ?? ""}
                            onChange={(e) => updateAi({ summary_custom_word_count: parseInt(e.target.value) || null } as any)}
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
                <p className="text-text-muted" style={{ fontSize: 14 }}>
                  More appearance options coming soon.
                </p>
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
  const [feedlyToken, setFeedlyToken] = useState("");
  const [connecting, setConnecting] = useState(false);
  const [feedlyError, setFeedlyError] = useState<string | null>(null);
  const [hasBakedCreds, setHasBakedCreds] = useState(false);

  useEffect(() => {
    getFeedlyStatus().then(setFeedlyStatus).catch(() => setFeedlyStatus(null));
    getFeedlyOauthConfig()
      .then((cfg) => setHasBakedCreds(cfg.has_baked_credentials))
      .catch(() => {});
  }, []);

  const handleLogin = async () => {
    setConnecting(true);
    setFeedlyError(null);
    try {
      const profile = await feedlyOauthLogin(null, null);
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

  const handleConnectWithToken = async () => {
    if (!feedlyToken.trim()) return;
    setConnecting(true);
    setFeedlyError(null);
    try {
      const profile = await connectFeedly(feedlyToken.trim());
      setFeedlyStatus({
        connected: true,
        email: profile.email,
        full_name: profile.full_name,
      });
      setFeedlyToken("");
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

  return (
    <>
      <h3 className="text-text-primary" style={{ fontSize: 16, fontWeight: 600, marginBottom: 20 }}>
        Feedly
      </h3>

      {feedlyStatus === undefined ? (
        <p className="text-text-muted" style={{ fontSize: 13 }}>Checking connection...</p>
      ) : feedlyStatus?.connected ? (
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
            <p className="text-text-muted" style={{ fontSize: 12, marginTop: 4 }}>
              Feeds imported from Feedly sync articles, read state, and stars through Feedly's API.
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
            Connect your Feedly account to sync articles, read state, and stars.
          </p>

          {hasBakedCreds ? (
            <>
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
            </>
          ) : (
            <div style={{ marginBottom: 12 }}>
              <p className="text-text-muted" style={{ fontSize: 12, marginBottom: 8 }}>
                Paste a developer token from{" "}
                <a
                  href="https://feedly.com/v3/auth/dev"
                  target="_blank"
                  rel="noopener noreferrer"
                  className="text-accent"
                >
                  feedly.com/v3/auth/dev
                </a>
                . One-click sign-in coming soon.
              </p>
              <div className="flex gap-2">
                <input
                  type="password"
                  value={feedlyToken}
                  onChange={(e) => { setFeedlyToken(e.target.value); setFeedlyError(null); }}
                  placeholder="Feedly developer token"
                  className={inputClass}
                  style={{ ...inputStyle, flex: 1, fontSize: 13 }}
                />
                <button
                  onClick={handleConnectWithToken}
                  disabled={connecting || !feedlyToken.trim()}
                  className="bg-accent text-white rounded-xl hover:bg-accent-hover disabled:opacity-40 font-medium transition-colors flex-shrink-0"
                  style={{ padding: "10px 20px", fontSize: 13 }}
                >
                  {connecting ? "..." : "Connect"}
                </button>
              </div>
            </div>
          )}

          {feedlyError && (
            <div
              className="rounded-xl border border-danger/30 text-danger"
              style={{ padding: "10px 14px", fontSize: 13, background: "rgba(248, 81, 73, 0.1)", marginBottom: 12 }}
            >
              {feedlyError}
            </div>
          )}
        </div>
      )}

      <div className="border-t border-white/5" style={{ margin: "24px 0" }} />

      <h3 className="text-text-primary" style={{ fontSize: 16, fontWeight: 600, marginBottom: 20 }}>
        Refresh
      </h3>

      <InputField
        label="Auto-refresh interval"
        description="How often to check feeds for new articles (in minutes)"
      >
        <input
          type="number"
          min={5}
          max={1440}
          value={local.sync.refresh_interval_minutes}
          onChange={(e) =>
            setLocal({
              ...local,
              sync: {
                ...local.sync,
                refresh_interval_minutes: parseInt(e.target.value) || 30,
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
        <input
          type="number"
          min={10}
          max={1000}
          value={local.sync.max_articles_per_feed}
          onChange={(e) =>
            setLocal({
              ...local,
              sync: {
                ...local.sync,
                max_articles_per_feed: parseInt(e.target.value) || 200,
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
