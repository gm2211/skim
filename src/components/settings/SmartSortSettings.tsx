import { useEffect, useState } from "react";
import { getSmartSortPrompts, learnPreferencesNow, saveLearnedPreferences } from "../../services/commands";
import type { LearnedPreferences, SmartSortPrompts } from "../../services/types";

export type LearnedDraft = Pick<LearnedPreferences, "text" | "learning">;

/**
 * The Smart sort tab's learned note, loaded once and edited as a draft that
 * Settings' Save commits with everything else.
 */
export function useSmartSortDraft() {
  const [prompts, setPrompts] = useState<SmartSortPrompts | null>(null);
  const [draft, setDraft] = useState<LearnedDraft | null>(null);
  const [loadError, setLoadError] = useState(false);

  useEffect(() => {
    getSmartSortPrompts()
      .then((p) => { setPrompts(p); setDraft({ text: p.learned.text, learning: p.learned.learning }); })
      .catch(() => setLoadError(true));
  }, []);

  const changed = !!prompts && !!draft
    && (draft.text.trim() !== prompts.learned.text || draft.learning !== prompts.learned.learning);

  /** Save the draft when it differs from what is stored. */
  const commit = async () => {
    if (!changed || !draft) return;
    const saved = await saveLearnedPreferences(draft.text, draft.learning);
    setPrompts(saved);
  };

  /** The model rewrote the note: show it, keeping the learning switch draft. */
  const replace = (next: SmartSortPrompts) => {
    setPrompts(next);
    setDraft((d) => ({ text: next.learned.text, learning: d?.learning ?? next.learned.learning }));
  };

  return { prompts, draft, setDraft, loadError, changed, commit, replace };
}

function ago(seconds: number): string {
  const mins = Math.max(0, Math.round((Date.now() / 1000 - seconds) / 60));
  if (mins < 2) return "just now";
  if (mins < 60) return `${mins} minutes ago`;
  const hours = Math.round(mins / 60);
  if (hours < 24) return `${hours} hour${hours === 1 ? "" : "s"} ago`;
  const days = Math.round(hours / 24);
  return `${days} day${days === 1 ? "" : "s"} ago`;
}

function Layer({ step, title, badge, description, children }: {
  step: number;
  title: string;
  badge?: string;
  description: string;
  children: React.ReactNode;
}) {
  return (
    <section className="rounded-xl border border-border bg-bg-tertiary" style={{ padding: 16, marginBottom: 12 }} aria-label={title}>
      <div className="flex items-center gap-2 min-w-0">
        <span aria-hidden className="flex-none rounded-full bg-white/10 text-text-secondary text-center"
          style={{ width: 20, height: 20, lineHeight: "20px", fontSize: 11, fontWeight: 600 }}>{step}</span>
        <h4 className="text-text-primary truncate" style={{ fontSize: 14, fontWeight: 600 }}>{title}</h4>
        {badge && (
          <span className="flex-none rounded-full border border-white/10 text-text-muted" style={{ padding: "1px 8px", fontSize: 11 }}>
            {badge}
          </span>
        )}
      </div>
      <p className="text-text-muted" style={{ fontSize: 12, lineHeight: 1.5, margin: "6px 0 10px" }}>{description}</p>
      {children}
    </section>
  );
}

const buttonClass = "inline-flex items-center gap-1.5 rounded-lg border border-white/10 text-text-primary hover:bg-white/10 transition-colors whitespace-nowrap disabled:opacity-50";

/**
 * Smart sort's three prompt layers, in the order the model reads them: the
 * built-in base prompt (read-only), the reader's own prompt, and the
 * preferences learned from their reading, which they can edit or delete.
 */
export function SmartSortSettings({ interests, onInterestsChange, state, modelLabel, onChangeModel, inputClass, inputStyle }: {
  interests: string;
  onInterestsChange: (value: string) => void;
  state: ReturnType<typeof useSmartSortDraft>;
  /** The AI model smart sort rates with, or null when none is chosen. */
  modelLabel: string | null;
  onChangeModel: () => void;
  inputClass: string;
  inputStyle: React.CSSProperties;
}) {
  const { prompts, draft, setDraft, loadError, commit, replace } = state;
  const [learning, setLearning] = useState(false);
  const [message, setMessage] = useState<{ text: string; error?: boolean } | null>(null);

  const learnNow = async () => {
    setLearning(true);
    setMessage(null);
    try {
      // Learn on top of the reader's edits, not the note they replaced.
      await commit();
      replace(await learnPreferencesNow());
      setMessage({ text: "Updated from your latest reading." });
    } catch (e) {
      setMessage({ text: e instanceof Error ? e.message : String(e), error: true });
    } finally {
      setLearning(false);
    }
  };

  const stored = prompts?.learned;
  const deleting = !!stored?.text && draft?.text.trim() === "";
  const status = !stored ? null
    : deleting ? "Deleted when you save. Smart sort then learns again only from what you read next."
    : stored.updated_at
      ? `Updated ${ago(stored.updated_at)}${prompts.new_signals > 0 ? ` · ${prompts.new_signals} new article${prompts.new_signals === 1 ? "" : "s"} read since` : ""}`
      : prompts.new_signals > 0
        ? `${prompts.new_signals} article${prompts.new_signals === 1 ? "" : "s"} read so far. Smart sort writes this note once it has about 20.`
        : null;

  return (
    <>
      <h3 className="text-text-primary" style={{ fontSize: 16, fontWeight: 600 }}>Smart sort</h3>
      <p className="text-text-secondary" style={{ fontSize: 13, lineHeight: 1.5, margin: "6px 0 16px" }}>
        Smart sort ranks unread articles by importance and by fit with you. The model reads these three prompts in
        order; your prompt outweighs what it learns.
      </p>
      <div className="flex items-center gap-2 flex-wrap text-text-muted" style={{ fontSize: 12, marginBottom: 16 }}>
        <span className="min-w-0">{modelLabel ? <>Rates with <span className="text-text-secondary">{modelLabel}</span></> : "No AI model chosen yet: ranking uses only what you read."}</span>
        <button type="button" onClick={onChangeModel} className={buttonClass} style={{ padding: "3px 10px", fontSize: 12 }}>
          {modelLabel ? "Change model" : "Choose a model"}
        </button>
      </div>

      <Layer step={1} title="Base prompt" badge="Built in" description="How every article is rated for importance and relevance. It is the same for everyone and cannot be edited.">
        <details className="group">
          <summary className="cursor-pointer list-none text-accent" style={{ fontSize: 12 }}>
            <span className="group-open:hidden">Show the base prompt</span>
            <span className="hidden group-open:inline">Hide the base prompt</span>
          </summary>
          <pre className="text-text-secondary rounded-lg bg-black/20 border border-white/5 overflow-y-auto whitespace-pre-wrap break-words"
            style={{ fontSize: 12, lineHeight: 1.55, padding: "10px 12px", marginTop: 8, maxHeight: 220, fontFamily: "inherit" }}>
            {prompts?.base_prompt ?? (loadError ? "Could not load the base prompt." : "Loading…")}
          </pre>
        </details>
      </Layer>

      <Layer step={2} title="Your prompt" badge="Optional" description="Tell smart sort what to favor or skip, in your own words.">
        <textarea
          aria-label="Your prompt"
          value={interests}
          onChange={(e) => onInterestsChange(e.target.value)}
          placeholder="e.g. Prioritize AI infrastructure, Rust and databases. Deprioritize sports and celebrity tech."
          className={inputClass}
          style={{ ...inputStyle, minHeight: 88, resize: "vertical" }}
          rows={4}
        />
      </Layer>

      <Layer step={3} title="Learned preferences" badge="From your reading" description="What smart sort has noticed you read, chat about and skip. Edit it to correct it; your edits are kept as it learns.">
        <textarea
          aria-label="Learned preferences"
          value={draft?.text ?? ""}
          disabled={!draft}
          onChange={(e) => draft && setDraft({ ...draft, text: e.target.value })}
          placeholder={loadError ? "Could not load learned preferences." : "Nothing learned yet. After about 20 articles, smart sort writes down what you seem to like and skip here."}
          className={inputClass}
          style={{ ...inputStyle, minHeight: 150, resize: "vertical" }}
          rows={6}
        />
        {status && <p className="text-text-muted" style={{ fontSize: 12, marginTop: 6 }}>{status}</p>}
        {message && (
          <p role={message.error ? "alert" : "status"} className={message.error ? "text-danger" : "text-text-secondary"} style={{ fontSize: 12, marginTop: 6 }}>
            {message.text}
          </p>
        )}
        <div className="flex items-center gap-x-2 gap-y-3 flex-wrap" style={{ marginTop: 10 }}>
          <label className="flex items-center gap-2 cursor-pointer text-text-primary mr-auto" style={{ fontSize: 13 }}>
            <input
              type="checkbox"
              checked={draft?.learning ?? true}
              disabled={!draft}
              onChange={(e) => draft && setDraft({ ...draft, learning: e.target.checked })}
              className="accent-accent"
            />
            Keep learning from my reading
          </label>
          <span className="flex items-center gap-2">
          <button type="button" onClick={learnNow} disabled={!draft || learning || !modelLabel} className={buttonClass} style={{ padding: "4px 10px", fontSize: 12 }}>
            {learning ? "Learning…" : "Learn now"}
          </button>
          <button
            type="button"
            onClick={() => draft && setDraft({ ...draft, text: "" })}
            disabled={!draft?.text}
            className={`${buttonClass} hover:text-danger`}
            style={{ padding: "4px 10px", fontSize: 12 }}
          >
            Delete
          </button>
          </span>
        </div>
      </Layer>
    </>
  );
}
