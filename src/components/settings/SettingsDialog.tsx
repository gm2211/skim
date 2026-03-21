import { useState, useEffect } from "react";
import { useSettings, useUpdateSettings } from "../../hooks/useSettings";
import { useUiStore } from "../../stores/uiStore";
import type { AppSettings } from "../../services/types";

const AI_PROVIDERS = [
  { value: "none", label: "None", description: "AI features disabled" },
  { value: "openrouter", label: "OpenRouter", description: "openrouter.ai - access multiple models with one API key" },
  { value: "openai", label: "OpenAI", description: "api.openai.com" },
  { value: "litellm", label: "LiteLLM", description: "Local LiteLLM proxy (default: localhost:4000)" },
  { value: "ollama", label: "Ollama", description: "Local Ollama (default: localhost:11434)" },
  { value: "lmstudio", label: "LM Studio", description: "Local LM Studio (default: localhost:1234)" },
  { value: "llamacpp", label: "llama.cpp", description: "Local llama.cpp server (default: localhost:8080)" },
  { value: "custom", label: "Custom", description: "Any OpenAI-compatible endpoint" },
];

const needsApiKey = (provider: string) =>
  ["openai", "openrouter", "litellm", "custom"].includes(provider);

const needsEndpoint = (provider: string) =>
  ["litellm", "ollama", "lmstudio", "llamacpp", "custom"].includes(provider);

export function SettingsDialog() {
  const { data: settings } = useSettings();
  const updateSettings = useUpdateSettings();
  const setShowSettings = useUiStore((s) => s.setShowSettings);

  const [local, setLocal] = useState<AppSettings | null>(null);

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

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50">
      <div className="bg-bg-secondary border border-border rounded-xl w-full max-w-lg mx-4 shadow-2xl max-h-[80vh] flex flex-col">
        <div className="flex items-center justify-between px-5 py-4 border-b border-border-light">
          <h2 className="font-semibold text-base">Settings</h2>
          <button
            onClick={() => setShowSettings(false)}
            className="text-text-muted hover:text-text-primary p-1"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M18 6L6 18M6 6l12 12" />
            </svg>
          </button>
        </div>

        <div className="flex-1 overflow-y-auto p-5 space-y-6">
          {/* AI Provider */}
          <section>
            <h3 className="text-sm font-medium text-text-primary mb-3">
              AI Provider
            </h3>
            <div className="space-y-3">
              <div>
                <label className="block text-xs text-text-secondary mb-1">
                  Provider
                </label>
                <select
                  value={local.ai.provider}
                  onChange={(e) => updateAi({ provider: e.target.value })}
                  className="w-full bg-bg-tertiary border border-border rounded-lg px-3 py-2 text-sm text-text-primary focus:outline-none focus:border-accent"
                >
                  {AI_PROVIDERS.map((p) => (
                    <option key={p.value} value={p.value}>
                      {p.label}
                    </option>
                  ))}
                </select>
                <p className="text-xs text-text-muted mt-1">
                  {AI_PROVIDERS.find((p) => p.value === local.ai.provider)
                    ?.description}
                </p>
              </div>

              {needsApiKey(local.ai.provider) && (
                <div>
                  <label className="block text-xs text-text-secondary mb-1">
                    API Key
                  </label>
                  <input
                    type="password"
                    value={local.ai.api_key ?? ""}
                    onChange={(e) =>
                      updateAi({
                        api_key: e.target.value || null,
                      })
                    }
                    placeholder="sk-..."
                    className="w-full bg-bg-tertiary border border-border rounded-lg px-3 py-2 text-sm text-text-primary placeholder-text-muted focus:outline-none focus:border-accent"
                  />
                </div>
              )}

              {needsEndpoint(local.ai.provider) && (
                <div>
                  <label className="block text-xs text-text-secondary mb-1">
                    Endpoint URL
                  </label>
                  <input
                    type="url"
                    value={local.ai.endpoint ?? ""}
                    onChange={(e) =>
                      updateAi({
                        endpoint: e.target.value || null,
                      })
                    }
                    placeholder={
                      local.ai.provider === "ollama"
                        ? "http://localhost:11434"
                        : local.ai.provider === "lmstudio"
                          ? "http://localhost:1234"
                          : local.ai.provider === "llamacpp"
                            ? "http://localhost:8080"
                            : "http://localhost:4000"
                    }
                    className="w-full bg-bg-tertiary border border-border rounded-lg px-3 py-2 text-sm text-text-primary placeholder-text-muted focus:outline-none focus:border-accent"
                  />
                </div>
              )}

              {local.ai.provider !== "none" && (
                <div>
                  <label className="block text-xs text-text-secondary mb-1">
                    Model
                  </label>
                  <input
                    type="text"
                    value={local.ai.model ?? ""}
                    onChange={(e) =>
                      updateAi({ model: e.target.value || null })
                    }
                    placeholder={
                      local.ai.provider === "openai"
                        ? "gpt-4o-mini"
                        : local.ai.provider === "openrouter"
                          ? "anthropic/claude-3.5-sonnet"
                          : local.ai.provider === "ollama"
                            ? "llama3"
                            : "model-name"
                    }
                    className="w-full bg-bg-tertiary border border-border rounded-lg px-3 py-2 text-sm text-text-primary placeholder-text-muted focus:outline-none focus:border-accent"
                  />
                </div>
              )}
            </div>
          </section>

          {/* Sync */}
          <section>
            <h3 className="text-sm font-medium text-text-primary mb-3">
              Sync
            </h3>
            <div className="space-y-3">
              <div>
                <label className="block text-xs text-text-secondary mb-1">
                  Auto-refresh interval (minutes)
                </label>
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
                  className="w-24 bg-bg-tertiary border border-border rounded-lg px-3 py-2 text-sm text-text-primary focus:outline-none focus:border-accent"
                />
              </div>
              <div>
                <label className="block text-xs text-text-secondary mb-1">
                  Max articles per feed
                </label>
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
                  className="w-24 bg-bg-tertiary border border-border rounded-lg px-3 py-2 text-sm text-text-primary focus:outline-none focus:border-accent"
                />
              </div>
            </div>
          </section>
        </div>

        {/* Footer */}
        <div className="px-5 py-4 border-t border-border-light flex justify-end gap-2">
          <button
            onClick={() => setShowSettings(false)}
            className="px-4 py-2 text-sm text-text-secondary hover:text-text-primary rounded-lg hover:bg-bg-hover"
          >
            Cancel
          </button>
          <button
            onClick={handleSave}
            disabled={updateSettings.isPending}
            className="px-4 py-2 text-sm bg-accent text-white rounded-lg hover:bg-accent-hover disabled:opacity-50 font-medium"
          >
            {updateSettings.isPending ? "Saving..." : "Save"}
          </button>
        </div>
      </div>
    </div>
  );
}
