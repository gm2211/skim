import { useEffect, useId, useMemo, useRef, useState } from "react";
import type { RemoteModel } from "../../services/commands";
import { useRemoteModels } from "../../hooks/useRemoteModels";

/** Waits for typing in the key field to settle before asking the provider for models. */
function useSettled<T>(value: T, delayMs: number): T {
  const [settled, setSettled] = useState(value);
  useEffect(() => {
    if (Object.is(settled, value)) return;
    const timer = setTimeout(() => setSettled(value), delayMs);
    return () => clearTimeout(timer);
  }, [value, delayMs, settled]);
  return settled;
}

// Rows have a fixed height so the menu always ends on a whole row.
const ROW_HEIGHT = 50;
const VISIBLE_ROWS = 6;

const matches = (model: RemoteModel, query: string) => {
  const q = query.trim().toLowerCase();
  return !q || model.id.toLowerCase().includes(q) || model.display_name.toLowerCase().includes(q);
};

/**
 * Model field for providers that list their models. The list loads on its own
 * when Settings opens and again whenever the provider, key, or endpoint
 * changes, then shows as a menu under the field (friendly name first, id
 * beneath). Any model id can still be typed.
 */
export function RemoteModelPicker({ provider, apiKey, endpoint, value, onChange }: {
  provider: string; apiKey: string | null; endpoint: string | null;
  value: string; onChange: (value: string) => void;
}) {
  const listId = useId();
  const settledKey = useSettled(apiKey, 450);
  const settledEndpoint = useSettled(endpoint, 450);
  const query = useRemoteModels(provider, settledKey, settledEndpoint);
  const models = useMemo(() => query.data ?? [], [query.data]);
  const loading = query.isFetching;
  const error = query.isError ? String(query.error) : !loading && query.isSuccess && !models.length ? "No models returned." : null;

  const [open, setOpen] = useState(false);
  // Typing filters the menu; opening it shows everything.
  const [filter, setFilter] = useState("");
  const [active, setActive] = useState(-1);
  const inputRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLUListElement>(null);

  const visible = useMemo(() => models.filter((model) => matches(model, filter)), [models, filter]);
  const expanded = open && visible.length > 0;

  // Each time the menu appears (including when the list arrives while the
  // field already has focus), start on the current model.
  useEffect(() => {
    if (!expanded) return;
    setActive(Math.max(0, visible.findIndex((model) => model.id === value)));
    listRef.current?.scrollIntoView?.({ block: "nearest" });
  }, [expanded]);
  useEffect(() => {
    if (active < 0) return;
    listRef.current?.querySelector(`[data-index="${active}"]`)?.scrollIntoView?.({ block: "nearest" });
  }, [active]);

  const show = () => {
    setFilter("");
    setOpen(true);
  };
  const choose = (model: RemoteModel) => {
    onChange(model.id);
    setOpen(false);
  };
  const selected = models.find((model) => model.id === value);
  const hint = loading && !models.length ? "Loading models…"
    : selected && selected.display_name !== selected.id ? `${selected.display_name} · ${models.length} models available. You can also type any model ID.`
      : models.length ? `${models.length} models available. Pick one or type any model ID.` : null;

  return <div className="flex flex-col gap-2">
    <div className="relative">
      <input ref={inputRef} role="combobox" aria-label="Model" aria-autocomplete="list" aria-expanded={expanded}
        aria-controls={listId} aria-activedescendant={expanded && active >= 0 ? `${listId}-${active}` : undefined}
        value={value} placeholder="Default model" autoComplete="off" spellCheck={false}
        onChange={(event) => { onChange(event.target.value); setFilter(event.target.value); setActive(0); setOpen(true); }}
        onFocus={show} onClick={() => { if (!open) show(); }} onBlur={() => setOpen(false)}
        onKeyDown={(event) => {
          if (event.key === "ArrowDown" || event.key === "ArrowUp") {
            event.preventDefault();
            if (!open) { show(); return; }
            const step = event.key === "ArrowDown" ? 1 : -1;
            setActive((index) => (index + step + visible.length) % Math.max(visible.length, 1));
          } else if (event.key === "Enter" && expanded && visible[active]) {
            event.preventDefault();
            choose(visible[active]);
          } else if (event.key === "Escape" && expanded) {
            event.stopPropagation();
            setOpen(false);
          }
        }}
        className="w-full rounded-xl border border-border bg-bg-tertiary text-text-primary focus:outline-none focus:border-accent/60"
        style={{ padding: "10px 40px 10px 14px", fontSize: 14, minHeight: 44 }} />
      <button type="button" tabIndex={-1} aria-label={expanded ? "Hide models" : "Show models"}
        disabled={!models.length}
        onMouseDown={(event) => event.preventDefault()}
        onClick={() => { if (expanded) setOpen(false); else { inputRef.current?.focus(); show(); } }}
        className="absolute inset-y-0 right-0 flex items-center justify-center text-text-muted hover:text-text-primary disabled:hover:text-text-muted"
        style={{ width: 40 }}>
        {loading
          ? <span aria-hidden="true" className="block rounded-full border-2 border-current motion-safe:animate-spin" style={{ width: 14, height: 14, borderTopColor: "transparent" }} />
          : <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true" style={{ transform: expanded ? "rotate(180deg)" : undefined, transition: "transform 120ms" }}>
            <path d="M3 4.5 6 7.5 9 4.5" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
          </svg>}
      </button>
      {expanded && <div className="absolute left-0 right-0 z-50 overflow-hidden rounded-xl border border-border bg-bg-secondary shadow-2xl"
        style={{ top: "calc(100% + 6px)" }}>
      <ul ref={listRef} id={listId} role="listbox" aria-label="Available models"
        onMouseDown={(event) => event.preventDefault()}
        className="overflow-y-auto"
        style={{ maxHeight: ROW_HEIGHT * VISIBLE_ROWS + 12, padding: 6, overscrollBehavior: "contain" }}>
        {visible.map((model, index) => {
          const isSelected = model.id === value;
          const named = model.display_name && model.display_name !== model.id;
          return <li key={model.id} id={`${listId}-${index}`} data-index={index} role="option" aria-selected={isSelected}
            onMouseMove={() => { if (active !== index) setActive(index); }} onClick={() => choose(model)}
            className={`flex cursor-pointer items-center rounded-lg ${index === active ? "bg-white/[0.07]" : ""}`}
            style={{ gap: 10, padding: "0 10px", height: ROW_HEIGHT }}>
            <span className="flex min-w-0 flex-1 flex-col" style={{ gap: 2 }}>
              <span className={`truncate ${isSelected ? "text-accent" : "text-text-primary"}`} style={{ fontSize: 14, fontWeight: 500, lineHeight: "18px" }}>
                {named ? model.display_name : model.id}
              </span>
              {named && <span className="truncate text-text-muted" style={{ fontSize: 12, lineHeight: "16px" }}>{model.id}</span>}
            </span>
            <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true" className="shrink-0 text-accent" style={{ visibility: isSelected ? "visible" : "hidden" }}>
              <path d="M3.5 8.5 6.5 11.5 12.5 5" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" />
            </svg>
          </li>;
        })}
      </ul>
      </div>}
    </div>
    <span role="status" className="sr-only">{loading ? "Loading models…" : ""}</span>
    {!error && hint && <p className="text-text-secondary text-xs">{hint}</p>}
    {error && <p role="alert" className="text-text-secondary text-xs">
      {error} You can still enter a model ID.{" "}
      <button type="button" className="text-accent hover:underline" onClick={() => void query.refetch()}>Try again</button>
    </p>}
  </div>;
}
