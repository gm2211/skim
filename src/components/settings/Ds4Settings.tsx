import { useEffect, useMemo, useState } from "react";
import { ds4Start, ds4Status, ds4Stop } from "../../services/commands";
import { useCancelDownload, useDownloadModel, useDownloadProgress, useLocalModels, useSystemInfo } from "../../hooks/useModels";
import type { AiSettings, Ds4Status } from "../../services/types";

export const DS4_MODEL_PRESET = {
  repoId: "antirez/deepseek-v4-gguf",
  filename: "DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf",
  modelId: "deepseek-v4-flash",
  sizeGb: 81,
  estimatedRamGb: 96,
};

export function Ds4Settings({ ai, updateAi }: { ai: AiSettings; updateAi: (patch: Partial<AiSettings>) => void }) {
  const localModels = useLocalModels();
  const systemInfo = useSystemInfo();
  const downloadModel = useDownloadModel();
  const cancelDownload = useCancelDownload();
  const progress = useDownloadProgress();
  const [status, setStatus] = useState<Ds4Status | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [downloadHidden, setDownloadHidden] = useState(false);

  const installed = useMemo(
    () => localModels.data?.find((model) => model.filename === DS4_MODEL_PRESET.filename && !model.is_partial),
    [localModels.data],
  );
  const partial = useMemo(
    () => localModels.data?.find((model) => model.filename === DS4_MODEL_PRESET.filename && model.is_partial),
    [localModels.data],
  );

  useEffect(() => {
    if (installed && ai.local_model_path !== installed.path) {
      updateAi({ model: DS4_MODEL_PRESET.modelId, local_model_path: installed.path });
    }
  }, [ai.local_model_path, installed, updateAi]);

  useEffect(() => {
    let active = true;
    ds4Status().then((next) => active && setStatus(next)).catch((cause) => active && setError(String(cause)));
    return () => { active = false; };
  }, []);

  useEffect(() => {
    if (progress?.filename === DS4_MODEL_PRESET.filename) setDownloadHidden(false);
  }, [progress]);

  const download = async () => {
    setBusy(true); setError(null);
    try {
      await downloadModel.mutateAsync({ repoId: DS4_MODEL_PRESET.repoId, filename: DS4_MODEL_PRESET.filename });
      await localModels.refetch();
    } catch (cause) { setError(cause instanceof Error ? cause.message : String(cause)); setDownloadHidden(true); }
    finally { setBusy(false); }
  };

  const start = async () => {
    const path = installed?.path ?? ai.local_model_path;
    if (!path) return;
    setBusy(true); setError(null);
    try { setStatus(await ds4Start(path)); updateAi({ model: DS4_MODEL_PRESET.modelId, local_model_path: path }); }
    catch (cause) { setError(cause instanceof Error ? cause.message : String(cause)); }
    finally { setBusy(false); }
  };

  const stop = async () => {
    setBusy(true); setError(null);
    try { setStatus(await ds4Stop()); }
    catch (cause) { setError(cause instanceof Error ? cause.message : String(cause)); }
    finally { setBusy(false); }
  };

  const ramText = DS4_MODEL_PRESET.estimatedRamGb > 0
    ? `Plan for about ${DS4_MODEL_PRESET.estimatedRamGb} GB RAM while it runs.`
    : "The runtime reports memory requirements when the model is started.";
  const enoughMemory = !systemInfo.data || systemInfo.data.total_memory_gb >= DS4_MODEL_PRESET.estimatedRamGb;
  const downloadingDs4 = !downloadHidden && progress?.filename === DS4_MODEL_PRESET.filename;
  const formatGiB = (bytes: number) => Math.round(bytes / (1024 ** 3));

  return (
    <section className="rounded-xl border border-accent/25 bg-accent/5" style={{ padding: 16, marginBottom: 20 }} aria-label="DeepSeek DS4 setup">
      <h4 className="text-text-primary" style={{ fontSize: 15, fontWeight: 600, marginBottom: 6 }}>DeepSeek (DS4)</h4>
      <p className="text-text-secondary" style={{ fontSize: 12, lineHeight: 1.5, marginBottom: 12 }}>
        Dedicated local runtime for DeepSeek V4 Flash. Download: about {DS4_MODEL_PRESET.sizeGb} GiB. {ramText}
      </p>
      {systemInfo.data && <p className="text-text-muted" style={{ fontSize: 11, marginBottom: 10 }}>This Mac reports {systemInfo.data.total_memory_gb} GB unified memory.</p>}
      {!enoughMemory && <p className="text-amber-300" style={{ fontSize: 12, marginBottom: 10 }}>This model is recommended for Macs with at least 96 GB unified memory.</p>}
      {status && <p className="text-text-muted" style={{ fontSize: 11, marginBottom: 10 }} role="status">{status.running ? "Runtime running" : status.runtime_available ? "Runtime ready" : "Runtime unavailable"}{status.error ? ` · ${status.error}` : ""}</p>}
      {error && <p className="text-danger" role="alert" style={{ fontSize: 12, marginBottom: 10 }}>{error}</p>}
      {downloadingDs4 && (
        <div className="rounded-lg border border-white/10" style={{ padding: "8px 10px", marginBottom: 10 }} role="status">
          <div className="flex items-center justify-between" style={{ fontSize: 11, marginBottom: 6 }}>
            <span>{progress.downloaded >= progress.total ? "Verifying DS4" : "Downloading DS4"}</span><span>{Math.round(progress.percent)}% · {formatGiB(progress.downloaded)} / {formatGiB(progress.total)} GiB</span>
          </div>
          <div className="rounded-full overflow-hidden" style={{ height: 4, background: "rgba(255,255,255,0.1)" }}><div className="h-full bg-accent" style={{ width: `${progress.percent}%` }} /></div>
          <button type="button" className="text-text-muted hover:text-danger" style={{ fontSize: 11, marginTop: 6 }} onClick={() => { setDownloadHidden(true); cancelDownload.mutate(); }}>Cancel download</button>
        </div>
      )}
      <div className="flex flex-wrap gap-2">
        {!installed && !downloadingDs4 && <button type="button" className="rounded-lg bg-accent text-bg-primary" style={{ minHeight: 40, padding: "8px 12px", fontSize: 12 }} disabled={busy || downloadModel.isPending || !enoughMemory} onClick={() => void download()}>{partial ? "Resume download" : "Download model"}</button>}
        {installed && !status?.running && <button type="button" className="rounded-lg bg-accent text-bg-primary" style={{ minHeight: 40, padding: "8px 12px", fontSize: 12 }} disabled={busy} onClick={() => void start()}>{busy ? "Starting…" : "Start DS4"}</button>}
        {status?.running && <button type="button" className="rounded-lg border border-white/15 text-text-primary" style={{ minHeight: 40, padding: "8px 12px", fontSize: 12 }} disabled={busy} onClick={() => void stop()}>Stop DS4</button>}
      </div>
    </section>
  );
}
