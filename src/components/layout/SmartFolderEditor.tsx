import { useEffect, useMemo, useRef, useState } from "react";
import { previewSmartFolder } from "../../services/commands";
import type { Feed, Folder, SmartRule, SmartRules } from "../../services/types";
import { parseRules } from "../../lib/smartFolder";
import { useDialogFocus } from "../../hooks/useDialogFocus";

type Props = {
  feeds: Feed[];
  folder?: Folder;
  mode: "create" | "edit" | "convert";
  onCancel: () => void;
  onCreate: (name: string, rules: SmartRules) => Promise<void>;
  onUpdate: (folderId: string, rules: SmartRules) => Promise<void>;
  onConvert?: (folder: Folder, rules: SmartRules, name: string) => Promise<void>;
};

const emptyRule = (): SmartRule => ({ type: "regex_title", pattern: "" });

function initialRules(folder?: Folder): SmartRules {
  return parseRules(folder ?? ({} as Folder)) ?? { mode: "any", rules: [emptyRule()] };
}

function ruleLabel(rule: SmartRule): string {
  switch (rule.type) {
    case "regex_title": return "Feed title matches";
    case "regex_url": return "Feed URL matches";
    case "opml_category": return "OPML category is";
  }
}

function rulePlaceholder(rule: SmartRule): string {
  switch (rule.type) {
    case "regex_title": return "e.g. machine learning|AI";
    case "regex_url": return "e.g. github\\.com|arxiv";
    case "opml_category": return "e.g. Technology";
  }
}

export function SmartFolderEditor({
  feeds,
  folder,
  mode,
  onCancel,
  onCreate,
  onUpdate,
  onConvert,
}: Props) {
  const [name, setName] = useState(folder?.name ?? "");
  const [rules, setRules] = useState<SmartRules>(() => initialRules(folder));
  const [matches, setMatches] = useState<string[] | null>(null);
  const [previewError, setPreviewError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const dialogRef = useRef<HTMLDivElement>(null);
  useDialogFocus(dialogRef, onCancel);

  const validRules = useMemo(
    () => rules.rules.filter((rule) => {
      const value = "pattern" in rule ? rule.pattern : rule.value;
      return value.trim().length > 0;
    }),
    [rules.rules],
  );

  useEffect(() => {
    let cancelled = false;
    if (validRules.length === 0) {
      setMatches(null);
      setPreviewError(null);
      return;
    }
    const nextRules = { ...rules, rules: validRules };
    const timer = window.setTimeout(() => {
      previewSmartFolder(nextRules)
        .then((ids) => {
          if (!cancelled) {
            setMatches(ids);
            setPreviewError(null);
          }
        })
        .catch((cause) => {
          if (!cancelled) {
            setMatches(null);
            setPreviewError(cause instanceof Error ? cause.message : String(cause));
          }
        });
    }, 180);
    return () => {
      cancelled = true;
      window.clearTimeout(timer);
    };
  }, [rules, validRules]);

  const matchingFeeds = useMemo(
    () => (matches ? feeds.filter((feed) => matches.includes(feed.id)) : []),
    [feeds, matches],
  );

  const updateRule = (index: number, next: SmartRule) => {
    setRules((current) => ({
      ...current,
      rules: current.rules.map((rule, ruleIndex) => ruleIndex === index ? next : rule),
    }));
  };

  const save = async () => {
    const trimmedName = name.trim();
    if (!trimmedName) {
      setError("Folder name is required.");
      return;
    }
    if (validRules.length === 0) {
      setError("Add at least one rule with a value.");
      return;
    }
    setSaving(true);
    setError(null);
    try {
      const nextRules = { ...rules, rules: validRules };
      if (mode === "create") {
        await onCreate(trimmedName, nextRules);
      } else if (mode === "edit" && folder) {
        await onUpdate(folder.id, nextRules);
      } else if (mode === "convert" && folder && onConvert) {
        await onConvert(folder, nextRules, trimmedName);
      }
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setSaving(false);
    }
  };

  const title = mode === "create" ? "New smart folder" : mode === "convert" ? "Convert to smart folder" : `Edit smart folder`;
  const description = mode === "edit"
    ? "Change the rules that decide which feeds belong here."
    : "Feeds are included dynamically whenever they match these rules.";

  return (
    <div className="fixed inset-0 bg-black/60 backdrop-blur-sm flex items-center justify-center z-50" onClick={onCancel}>
      <div
        ref={dialogRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby="smart-folder-editor-title"
        className="border border-white/10 rounded-2xl shadow-2xl flex flex-col"
        style={{ background: "rgba(22, 27, 34, 0.98)", maxWidth: 560, width: "calc(100% - 32px)", maxHeight: "88vh" }}
        onClick={(event) => event.stopPropagation()}
      >
        <div className="flex items-start justify-between border-b border-white/5" style={{ padding: "18px 22px 14px" }}>
          <div>
            <h3 id="smart-folder-editor-title" className="text-text-primary" style={{ fontSize: 17, fontWeight: 600 }}>{title}</h3>
            <p className="text-text-muted" style={{ fontSize: 12, marginTop: 5 }}>{description}</p>
          </div>
          <button onClick={onCancel} className="tap-target text-text-muted hover:text-text-primary rounded-lg hover:bg-white/10" aria-label="Close smart folder editor">×</button>
        </div>

        <div className="overflow-y-auto" style={{ padding: "18px 22px 20px" }}>
          <label className="block text-text-primary" style={{ fontSize: 13, fontWeight: 500, marginBottom: 6 }} htmlFor="smart-folder-name">Folder name</label>
          <input id="smart-folder-name" autoFocus value={name} onChange={(event) => setName(event.target.value)} className="w-full border border-white/10 rounded-xl text-text-primary placeholder-text-muted focus:outline-none focus:border-accent/50" style={{ background: "rgba(255,255,255,0.05)", padding: "10px 12px", fontSize: 14, marginBottom: 18 }} placeholder="e.g. AI & ML" />

          <div className="flex items-center justify-between" style={{ marginBottom: 8 }}>
            <span className="text-text-primary" style={{ fontSize: 13, fontWeight: 500 }}>Match rules</span>
            <select aria-label="Rule matching mode" value={rules.mode} onChange={(event) => setRules((current) => ({ ...current, mode: event.target.value as SmartRules["mode"] }))} className="border border-white/10 rounded-lg text-text-primary" style={{ background: "rgba(255,255,255,0.05)", padding: "6px 8px", fontSize: 12 }}>
              <option value="any">Match any rule</option>
              <option value="all">Match all rules</option>
            </select>
          </div>

          <div className="flex flex-col gap-2">
            {rules.rules.map((rule, index) => (
              <div key={index} className="flex items-center gap-2">
                <select aria-label={`Rule ${index + 1} type`} value={rule.type} onChange={(event) => updateRule(index, event.target.value === "regex_title" ? { type: "regex_title", pattern: "" } : event.target.value === "regex_url" ? { type: "regex_url", pattern: "" } : { type: "opml_category", value: "" })} className="border border-white/10 rounded-lg text-text-primary" style={{ background: "rgba(255,255,255,0.05)", padding: "9px 8px", fontSize: 12, minWidth: 150 }}>
                  <option value="regex_title">{ruleLabel({ type: "regex_title", pattern: "" })}</option>
                  <option value="regex_url">{ruleLabel({ type: "regex_url", pattern: "" })}</option>
                  <option value="opml_category">{ruleLabel({ type: "opml_category", value: "" })}</option>
                </select>
                <input aria-label={`Rule ${index + 1} value`} value={"pattern" in rule ? rule.pattern : rule.value} onChange={(event) => updateRule(index, "pattern" in rule ? { ...rule, pattern: event.target.value } : { ...rule, value: event.target.value })} placeholder={rulePlaceholder(rule)} className="flex-1 min-w-0 border border-white/10 rounded-lg text-text-primary placeholder-text-muted focus:outline-none focus:border-accent/50" style={{ background: "rgba(255,255,255,0.05)", padding: "9px 10px", fontSize: 13 }} />
                <button onClick={() => setRules((current) => ({ ...current, rules: current.rules.filter((_, ruleIndex) => ruleIndex !== index) }))} disabled={rules.rules.length === 1} className="tap-target text-text-muted hover:text-danger disabled:opacity-30" aria-label={`Remove rule ${index + 1}`}>×</button>
              </div>
            ))}
          </div>
          <button onClick={() => setRules((current) => ({ ...current, rules: [...current.rules, emptyRule()] }))} className="text-accent hover:text-accent-hover" style={{ fontSize: 12, marginTop: 10 }}>+ Add rule</button>

          <div className="border border-white/5 rounded-xl" style={{ marginTop: 20, padding: "12px 14px", minHeight: 70 }}>
            <div className="flex items-center justify-between" style={{ marginBottom: 6 }}>
              <span className="text-text-muted" style={{ fontSize: 11, textTransform: "uppercase", letterSpacing: 0.6 }}>Live preview</span>
              {matches && <span className="text-text-secondary" style={{ fontSize: 11 }}>{matchingFeeds.length} matching feed{matchingFeeds.length === 1 ? "" : "s"}</span>}
            </div>
            {previewError ? <p className="text-danger" style={{ fontSize: 12 }}>{previewError}</p> : matchingFeeds.length > 0 ? <p className="text-text-secondary" style={{ fontSize: 12, lineHeight: 1.5 }}>{matchingFeeds.slice(0, 6).map((feed) => feed.title).join(" · ")}{matchingFeeds.length > 6 ? " …" : ""}</p> : <p className="text-text-muted" style={{ fontSize: 12 }}>{validRules.length === 0 ? "Add a rule value to preview matches." : "No feeds match yet."}</p>}
          </div>
          {error && <p className="text-danger" style={{ fontSize: 12, marginTop: 10 }}>{error}</p>}
        </div>

        <div className="flex justify-end gap-2 border-t border-white/5" style={{ padding: "12px 18px" }}>
          <button onClick={onCancel} className="text-text-secondary hover:text-text-primary rounded-lg hover:bg-white/5" style={{ padding: "8px 14px", fontSize: 13 }}>Cancel</button>
          <button onClick={save} disabled={saving} className="bg-accent text-white rounded-lg hover:bg-accent-hover disabled:opacity-40 font-medium" style={{ padding: "8px 16px", fontSize: 13 }}>{saving ? "Saving…" : mode === "edit" ? "Save rules" : "Create smart folder"}</button>
        </div>
      </div>
    </div>
  );
}
