import { useRef, useState } from "react";
import { useSettings, useSelectModel } from "../../hooks/useSettings";
import { useModelChoices, type ModelSurface } from "../../hooks/useModelChoices";
import { offlineFallbackNote, useOfflineAi } from "../../hooks/useOfflineAi";
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
  /** Extra styling for the control itself, e.g. to match a toolbar's height. */
  controlStyle?: React.CSSProperties;
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
 * Inline model picker shared by every AI surface (Today, Ask Skim,
 * the article chat drawer, the Summarize menu, Today). It reads and writes
 * the same AppSettings blob Settings uses, changing only the model — never
 * the provider, which stays a Settings-only decision — and never re-runs
 * anything on its own; the caller decides whether a change should trigger
 * work. A trailing "AI settings…" entry is always present as an escape hatch.
 */
export function ModelPicker({ surface, disabled, compact, label, controlStyle }: Props) {
  const { data: settings } = useSettings();
  const isPhone = useUiStore((s) => s.isPhone);
  const selectModel = useSelectModel();
  const [error, setError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const selectRef = useRef<HTMLSelectElement>(null);

  const ai = settings?.ai ?? FALLBACK_AI;
  const choices = useModelChoices(ai, { isPhone, surface });
  const offlineNote = offlineFallbackNote(useOfflineAi(!!settings && ai.provider !== "none"));

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
      <div style={{ display: "flex", alignItems: "center", gap: 6, minWidth: 0 }}>
        {offlineNote && compact && <OfflineBadge note={offlineNote} showText={false} />}
        <Select
          ref={selectRef}
          aria-label={label ?? "AI model"}
          value={choices.current}
          onChange={handleChange}
          disabled={disabled || saving}
          fullWidth={!compact}
          style={{ ...(compact ? { width: 220, maxWidth: "100%", height: 32, minHeight: 32, fontSize: 12.5, padding: "0 28px 0 10px" } : {}), ...controlStyle }}
        >
          {options.map((choice) => (
            <option key={choice.value} value={choice.value} disabled={choice.disabled}>
              {choice.label}
              {choice.hint ? ` (${choice.hint})` : ""}
            </option>
          ))}
          <option value={SETTINGS_VALUE}>AI settings…</option>
        </Select>
      </div>
      {offlineNote && !compact && <OfflineBadge note={offlineNote} showText />}
      {error && (
        <p role="alert" className="text-danger" style={{ fontSize: 11 }}>
          {error}
        </p>
      )}
    </div>
  );
}

/**
 * A quiet marker beside the model picker while requests go to an on-device
 * model because the configured provider can't be reached.
 */
function OfflineBadge({ note, showText }: { note: string; showText: boolean }) {
  return (
    <span
      role="status"
      title={`${note}. Your chosen model is back as soon as you are online.`}
      aria-label={note}
      className="text-text-muted"
      style={{ display: "inline-flex", alignItems: "center", gap: 5, flexShrink: 0, minWidth: 18, height: 18, fontSize: 12, whiteSpace: "nowrap" }}
    >
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
        <path d="M12 20h.01" />
        <path d="M8.5 16.43a5 5 0 0 1 7 0" />
        <path d="M5 12.86a10 10 0 0 1 5.17-2.69" />
        <path d="M19 12.86a10 10 0 0 0-2-1.5" />
        <path d="M2 8.82a15 15 0 0 1 4.18-2.65" />
        <path d="M22 8.82a15 15 0 0 0-11.29-3.76" />
        <path d="m2 2 20 20" />
      </svg>
      {showText && <span>{note}</span>}
    </span>
  );
}
