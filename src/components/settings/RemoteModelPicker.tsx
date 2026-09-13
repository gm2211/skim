import { useEffect, useId, useRef, useState } from "react";
import { listRemoteModels, type RemoteModel } from "../../services/commands";

export function RemoteModelPicker({ provider, apiKey, endpoint, value, onChange }: {
  provider: string; apiKey: string | null; endpoint: string | null;
  value: string; onChange: (value: string) => void;
}) {
  const id = useId();
  const generation = useRef(0);
  const [models, setModels] = useState<RemoteModel[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    generation.current += 1;
    setModels([]); setError(null); setLoading(false);
    return () => { generation.current += 1; };
  }, [provider, apiKey, endpoint]);
  const load = async () => {
    const request = ++generation.current;
    setLoading(true); setError(null);
    try {
      const next = await listRemoteModels(provider, apiKey, endpoint);
      if (generation.current === request) {
        setModels(next);
        if (!next.length) setError("No models returned. Enter a model ID below.");
      }
    } catch (caught) {
      if (generation.current === request) setError(String(caught));
    } finally {
      if (generation.current === request) setLoading(false);
    }
  };
  return <div className="flex flex-col gap-2">
    <input aria-label="Model" list={id} value={value} onChange={(event) => onChange(event.target.value)}
      placeholder="Default model" className="w-full rounded-xl border border-border bg-bg-tertiary text-text-primary"
      style={{ padding: "10px 14px", fontSize: 14, minHeight: 44 }} />
    <datalist id={id}>{models.map((model) => <option key={model.id} value={model.id}>{model.display_name}</option>)}</datalist>
    <button type="button" disabled={loading} onClick={load}
      className="self-start rounded-lg border border-border text-accent hover:bg-bg-hover disabled:opacity-50"
      style={{ padding: "8px 12px", minHeight: 40, fontSize: 13 }}>
      {loading ? "Loading models…" : "Load available models"}
    </button>
    {models.length > 0 && <p role="status" className="text-text-secondary text-xs">{models.length} models available. Choose a suggestion or enter any model ID.</p>}
    {error && <p role="alert" className="text-text-secondary text-xs">{error} You can still enter a model ID.</p>}
  </div>;
}
