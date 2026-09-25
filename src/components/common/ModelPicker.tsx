import { useRef, useState } from "react";
import { useSettings, useSelectModel } from "../../hooks/useSettings";
import { useModelChoices, type ModelSurface } from "../../hooks/useModelChoices";
import { useUiStore } from "../../stores/uiStore";
import { modelPatch } from "../../lib/aiModels";
import { Select } from "../ui/Select";
import type { AiSettings } from "../../services/types";

interface Props {
  surface: ModelSurface;
  /** Disable while the surface that owns this picker is already working. */
  disabled?: boolean;
  /** Narrower styling for toolbars and headers. */
  compact?: boolean;
  /** Overrides the default "AI model" aria-label. */
  label?: string;
}

const SETTINGS_VALUE = "__settings__";

// Used only while settings have not loaded yet, so the hooks below always run
// with a real AiSettings shape. The component itself renders nothing until
// real settings arrive (see the early return below).
const FALLBACK_AI: AiSettings = {
  provider: "none",
  api_key: null,
  model: null,
  endpoint: null,
  local_model_path: null,
  local_gpu_layers: null,
  local_preload: null,
  local_idle_evict_minutes: null,
  local_power_mode: null,
  models_directory: null,
  summary_length: null,
  summary_tone: null,
  summary_format: null,
  summary_custom_prompt: null,
  summary_custom_word_count: null,
  chat_provider: null,
  chat_model: null,
  chat_api_key: null,
  chat_endpoint: null,
};

/**
 * Inline model picker shared by every AI surface (Quick Catch-up, Ask Skim,
 * the article chat drawer, the Summarize menu, Today). It reads and writes
 * the same AppSettings blob Settings uses, changing only the model — never
 * the provider, which stays a Settings-only decision — and never re-runs
 * anything on its own; the caller decides whether a change should trigger
 * work. A trailing "AI settings…" entry is always present as an escape hatch.
 */
export function ModelPicker({ surface, disabled, compact, label }: Props) {
  const { data: settings } = useSettings();
  const isPhone = useUiStore((s) => s.isPhone);
  const selectModel = useSelectModel();
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const selectRef = useRef<HTMLSelectElement>(null);

  const ai = settings?.ai ?? FALLBACK_AI;
  const choices = useModelChoices(ai, { isPhone, surface });

  if (!settings || ai.provider === "none") return null;

  const options =
    choices.mode === "fixed"
      ? [{ value: choices.current, label: choices.currentLabel, disabled: true }]
      : choices.choices;

  const handleChange = async (event: React.ChangeEvent<HTMLSelectElement>) => {
    const value = event.target.value;
    if (value === SETTINGS_VALUE) {
      useUiStore.getState().setShowSettings(true);
      // This option is an action, not a selection — snap the control back to
      // the model that is actually active instead of leaving it showing
      // "AI settings…".
      event.target.value = choices.current;
      return;
    }
    setError(null);
    setSaving(true);
    try {
      const patch: Partial<AiSettings> = { ...modelPatch(ai.provider, value) };
      if (surface === "chat") patch.chat_model = null;
      await selectModel(patch);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 4, minWidth: 0 }}>
      <Select
        ref={selectRef}
        aria-label={label ?? "AI model"}
        value={choices.current}
        onChange={handleChange}
        disabled={disabled || saving}
        fullWidth={!compact}
        style={compact ? { maxWidth: 200, minHeight: 40, fontSize: 13 } : undefined}
      >
        {options.map((choice) => (
          <option key={choice.value} value={choice.value} disabled={choice.disabled}>
            {choice.label}
            {choice.hint ? ` (${choice.hint})` : ""}
          </option>
        ))}
        <option value={SETTINGS_VALUE}>AI settings…</option>
      </Select>
      {error && (
        <p role="alert" className="text-danger" style={{ fontSize: 11 }}>
          {error}
        </p>
      )}
    </div>
  );
}
