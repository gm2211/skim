import { useState, useEffect, useCallback } from "react";
import {
  useSearchHfModels,
  useHfModelFiles,
  useLocalModels,
  useDownloadModel,
  useCancelDownload,
  useDeleteModel,
  useDownloadProgress,
  useSystemInfo,
} from "../../hooks/useModels";
import type { AiSettings, HfModelFile } from "../../services/types";

function formatBytes(bytes: number | null): string {
  if (!bytes) return "";
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)} KB`;
  if (bytes < 1024 * 1024 * 1024)
    return `${(bytes / (1024 * 1024)).toFixed(0)} MB`;
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`;
}

function formatNumber(n: number | null): string {
  if (!n) return "0";
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`;
  return String(n);
}

// Show only these quantization levels, in order. Users don't need 20 options.
const ALL_QUANTS: { pattern: string; label: string; recommended?: boolean; defaultOn?: boolean }[] = [
  { pattern: "Q3_K_S", label: "Tiny — lowest usable quality" },
  { pattern: "Q3_K_M", label: "Compact — fast, lower quality", defaultOn: true },
  { pattern: "Q3_K_L", label: "Compact+ — slightly better than Q3_K_M" },
  { pattern: "Q4_K_S", label: "Smaller — slightly lower quality", defaultOn: true },
  { pattern: "Q4_K_M", label: "Balanced — good quality, moderate size", recommended: true, defaultOn: true },
  { pattern: "Q4_0",   label: "Basic 4-bit — simple quantization" },
  { pattern: "Q5_K_S", label: "Good — slightly better than Q4" },
  { pattern: "Q5_K_M", label: "High quality — larger download", defaultOn: true },
  { pattern: "Q5_0",   label: "Basic 5-bit — simple quantization" },
  { pattern: "Q6_K",   label: "Very high quality — large" },
  { pattern: "Q8_0",   label: "Best quality — largest download", defaultOn: true },
  { pattern: "IQ2_XXS", label: "Ultra-tiny 2-bit — experimental" },
  { pattern: "IQ2_XS", label: "Tiny 2-bit — experimental" },
  { pattern: "IQ3_XXS", label: "Tiny 3-bit — experimental" },
  { pattern: "IQ3_S",  label: "Small 3-bit — experimental" },
  { pattern: "IQ4_NL", label: "Small 4-bit — experimental" },
  { pattern: "IQ4_XS", label: "Small 4-bit — experimental" },
  { pattern: "F16",    label: "Full 16-bit — no quantization, huge" },
];

const DEFAULT_QUANTS = new Set(ALL_QUANTS.filter((q) => q.defaultOn).map((q) => q.pattern));

function filterAndSortFiles(files: HfModelFile[], enabledQuants: Set<string>) {
  const results: (HfModelFile & { tier: typeof ALL_QUANTS[0] })[] = [];
  for (const tier of ALL_QUANTS) {
    if (!enabledQuants.has(tier.pattern)) continue;
    const match = files.find((f) => f.filename.includes(tier.pattern));
    if (match) results.push({ ...match, tier });
  }
  return results;
}

// Clean up repo name into a human-friendly model name
function friendlyName(repoId: string): string {
  const name = repoId.split("/").pop() ?? repoId;
  return name
    .replace(/-GGUF$/i, "")
    .replace(/-Q\d.*$/i, "") // strip quantization suffix like -Q8_0
    .replace(/[-_]/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

// Extract parameter count from model name (e.g. "8B", "1.5B", "500M")
function extractParams(repoId: string): string | null {
  const name = repoId.split("/").pop() ?? repoId;
  const match = name.match(/(\d+\.?\d*)\s*[BbMm](?:\b|-)/);
  if (!match) return null;
  return match[0].replace(/-$/, "").toUpperCase();
}

function getParamBillions(model: { id: string; params_billions?: number | null }): number | null {
  return model.params_billions ?? paramBillions(extractParams(model.id));
}

function estSizeGb(b: number): number {
  return b * 0.6; // Q4_K_M ≈ 0.6 GB per billion params
}

function passesParamFilter(model: { id: string; params_billions?: number | null }, filter: "all" | "tiny" | "small" | "medium" | "large"): boolean {
  if (filter === "all") return true;
  const b = getParamBillions(model);
  if (!b) return false;
  if (filter === "tiny") return b <= 3;
  if (filter === "small") return b > 3 && b <= 8;
  if (filter === "medium") return b > 8 && b <= 30;
  return b > 30;
}

function passesSizeFilter(model: { id: string; params_billions?: number | null; recommended_file_size?: number | null }, filter: "all" | "tiny" | "small" | "medium" | "large"): boolean {
  if (filter === "all") return true;
  // Use real file size if available, otherwise estimate from params
  let gb: number | null = null;
  if (model.recommended_file_size) {
    gb = model.recommended_file_size / (1024 * 1024 * 1024);
  } else {
    const b = getParamBillions(model);
    if (b) gb = estSizeGb(b);
  }
  if (!gb) return false;
  if (filter === "tiny") return gb < 0.5;
  if (filter === "small") return gb < 1;
  if (filter === "medium") return gb < 5;
  return gb >= 5;
}

function paramBillions(params: string | null): number | null {
  if (!params) return null;
  const num = parseFloat(params);
  if (params.toUpperCase().includes("B")) return num;
  if (params.toUpperCase().includes("M")) return num / 1000;
  return null;
}

// Single-quant repos have a quantization level in the name — these only have one file
// and usually won't have the preferred Q4_K_M etc.
function isSingleQuantRepo(repoId: string): boolean {
  const name = repoId.split("/").pop() ?? "";
  return /[-_](Q\d|IQ\d|F16|F32|BF16)/i.test(name.replace(/-GGUF$/i, ""));
}

interface SmartTag { label: string; color: string }

// Derive tags from metadata + prollm.ai leaderboard
function smartTags(model: { id: string; downloads?: number | null; tags?: string[] | null; params_billions?: number | null; summarization_rank?: number | null; summarization_score?: number | null }): SmartTag[] {
  const result: SmartTag[] = [];
  const b = getParamBillions(model);
  const name = (model.id.split("/").pop() ?? "").toLowerCase();
  const tags = model.tags;
  const downloads = model.downloads;
  const isInstruct = name.includes("instruct") || (tags ?? []).includes("conversational");

  // Leaderboard-based tag (from prollm.ai)
  if (model.summarization_rank != null && model.summarization_rank <= 10) {
    result.push({ label: `#${model.summarization_rank} Summarizer`, color: "text-green-400 border-green-400/30 bg-green-400/10" });
  }

  // Size-based capability tags
  if (b !== null) {
    if (b <= 4 && isInstruct) {
      result.push({ label: "Fast", color: "text-green-400 border-green-400/30 bg-green-400/10" });
    }
    if (b >= 3 && b <= 9 && isInstruct) {
      result.push({ label: "Recommended", color: "text-accent border-accent/30 bg-accent/10" });
    }
    if (b > 9) {
      result.push({ label: "Quality", color: "text-purple-400 border-purple-400/30 bg-purple-400/10" });
    }
  }

  // Popularity
  if ((downloads ?? 0) >= 200_000) {
    result.push({ label: "Popular", color: "text-amber-400 border-amber-400/30 bg-amber-400/10" });
  }

  return result;
}

const inputClass =
  "w-full border border-white/10 rounded-xl text-text-primary placeholder-text-muted focus:outline-none focus:border-accent/50 focus:ring-1 focus:ring-accent/30 transition-colors";

const inputStyle = {
  background: "rgba(255, 255, 255, 0.05)",
  padding: "10px 14px",
  fontSize: 14,
};

function FileList({
  repoId,
  modelFiles,
  downloadModel,
  handleDownload,
  enabledQuants,
}: {
  repoId: string;
  modelFiles: ReturnType<typeof useHfModelFiles>;
  downloadModel: ReturnType<typeof useDownloadModel>;
  handleDownload: (repoId: string, filename: string) => void;
  enabledQuants: Set<string>;
}) {
  if (modelFiles.isLoading) {
    return (
      <p className="text-text-muted" style={{ fontSize: 12, padding: "4px 0" }}>
        Loading options...
      </p>
    );
  }

  if (!modelFiles.data || modelFiles.data.length === 0) {
    return (
      <p className="text-text-muted" style={{ fontSize: 12, padding: "4px 0" }}>
        No downloadable files found.
      </p>
    );
  }

  let filtered = filterAndSortFiles(modelFiles.data, enabledQuants);

  // Fallback: show all gguf files if no preferred quants found
  if (filtered.length === 0) {
    filtered = modelFiles.data.map((f) => ({
      ...f,
      tier: { pattern: "", label: f.filename.split(/[.-]/).filter((p: string) => /^Q\d/.test(p)).join(" ") || f.filename },
    }));
  }

  if (filtered.length === 0) {
    return (
      <p className="text-text-muted" style={{ fontSize: 12, padding: "4px 0" }}>
        No downloadable files found.
      </p>
    );
  }

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
      {filtered.map((file) => (
        <div
          key={file.filename}
          className="flex items-center gap-3"
          style={{ fontSize: 12 }}
        >
          <div className="flex-1 min-w-0">
            <div className="flex items-center gap-2">
              <span className="text-text-primary">
                {file.tier.label}
              </span>
              {file.tier.recommended && (
                <span
                  className="text-green-400 border-green-400/30 bg-green-400/10 rounded border"
                  style={{ fontSize: 9, padding: "1px 5px" }}
                >
                  Recommended
                </span>
              )}
            </div>
          </div>
          <span className="text-text-muted flex-shrink-0">
            {formatBytes(file.size)}
          </span>
          <button
            onClick={() => handleDownload(repoId, file.filename)}
            disabled={downloadModel.isPending}
            className="text-accent hover:text-accent-hover disabled:opacity-40 flex-shrink-0 px-2.5 py-1 rounded-lg border border-accent/20 hover:border-accent/40 transition-colors"
            style={{ fontSize: 11 }}
          >
            Download
          </button>
        </div>
      ))}
    </div>
  );
}

export function ModelBrowser({
  ai,
  updateAi,
}: {
  ai: AiSettings;
  updateAi: (patch: Partial<AiSettings>) => void;
}) {
  const [searchQuery, setSearchQuery] = useState("");
  const [debouncedQuery, setDebouncedQuery] = useState("");
  const [expandedRepo, setExpandedRepo] = useState<string | null>(null);
  const [sizeFilter, setSizeFilter] = useState<"all" | "tiny" | "small" | "medium" | "large">("all");
  const [paramFilter, setParamFilter] = useState<"all" | "tiny" | "small" | "medium" | "large">("all");
  const [enabledQuants, setEnabledQuants] = useState<Set<string>>(new Set(DEFAULT_QUANTS));
  const [showQuantFilter, setShowQuantFilter] = useState(false);

  // Debounce search
  useEffect(() => {
    const timer = setTimeout(() => setDebouncedQuery(searchQuery), 400);
    return () => clearTimeout(timer);
  }, [searchQuery]);

  // Always search — empty query shows popular models
  const effectiveQuery = debouncedQuery || "instruct GGUF";
  const searchResults = useSearchHfModels(effectiveQuery);
  const modelFiles = useHfModelFiles(expandedRepo);
  const localModels = useLocalModels();
  const downloadModel = useDownloadModel();
  const cancelDownload = useCancelDownload();
  const deleteModel = useDeleteModel();
  const progress = useDownloadProgress();
  const sysInfo = useSystemInfo();

  const handleDownload = useCallback(
    (repoId: string, filename: string) => {
      downloadModel.mutate({ repoId, filename });
    },
    [downloadModel]
  );

  const handleDelete = useCallback(
    (path: string) => {
      if (ai.local_model_path === path) {
        updateAi({ local_model_path: null });
      }
      deleteModel.mutate(path);
    },
    [deleteModel, ai.local_model_path, updateAi]
  );

  // Clear active model if it no longer exists on disk
  useEffect(() => {
    if (ai.local_model_path && localModels.data) {
      const exists = localModels.data.some((m) => m.path === ai.local_model_path);
      if (!exists) {
        updateAi({ local_model_path: null });
      }
    }
  }, [ai.local_model_path, localModels.data, updateAi]);

  const handleSelectModel = useCallback(
    (path: string) => {
      updateAi({ local_model_path: path });
    },
    [updateAi]
  );

  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 20 }}>
      {/* Currently selected model */}
      {ai.local_model_path && (
        <div
          className="rounded-xl border border-accent/20"
          style={{
            padding: "10px 14px",
            background: "rgba(88, 166, 255, 0.05)",
            fontSize: 13,
          }}
        >
          <span className="text-text-muted">Active model: </span>
          <span className="text-accent font-medium">
            {ai.local_model_path.split("/").pop()}
          </span>
        </div>
      )}

      {/* Downloaded Models */}
      {localModels.data && localModels.data.length > 0 && (
        <div>
          <label
            className="block text-text-primary"
            style={{ fontSize: 14, fontWeight: 500, marginBottom: 8 }}
          >
            Downloaded Models
          </label>
          <div
            className="rounded-xl border border-white/10 overflow-hidden"
            style={{ background: "rgba(255,255,255,0.02)" }}
          >
            {localModels.data.map((m) => (
              <div
                key={m.path}
                className={`flex items-center gap-3 border-b border-white/5 last:border-0 hover:bg-white/5 transition-colors ${m.is_partial ? "opacity-60" : "cursor-pointer"}`}
                style={{ padding: "10px 14px" }}
                onClick={() => !m.is_partial && handleSelectModel(m.path)}
              >
                {m.is_partial ? (
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" className="text-warning flex-shrink-0">
                    <circle cx="12" cy="12" r="10" strokeDasharray="4 2" />
                  </svg>
                ) : (
                  <div
                    className={`w-3.5 h-3.5 rounded-full border-2 flex-shrink-0 ${
                      ai.local_model_path === m.path
                        ? "border-accent bg-accent"
                        : "border-white/20"
                    }`}
                  />
                )}
                <div className="flex-1 min-w-0">
                  <div
                    className="text-text-primary truncate"
                    style={{ fontSize: 13 }}
                  >
                    {m.filename}
                    {m.is_partial && (
                      <span className="text-warning" style={{ fontSize: 11 }}> (incomplete)</span>
                    )}
                  </div>
                </div>
                {m.is_partial ? (
                  <div className="flex items-center gap-2 flex-shrink-0">
                    <span className="text-text-muted" style={{ fontSize: 11 }}>
                      {formatBytes(m.size_bytes)}
                    </span>
                    {m.download_repo_id ? (
                      <button
                        onClick={(e) => {
                          e.stopPropagation();
                          handleDownload(m.download_repo_id!, m.filename);
                        }}
                        disabled={downloadModel.isPending}
                        className="text-accent hover:text-accent-hover disabled:opacity-40 px-2 py-0.5 rounded border border-accent/20 hover:border-accent/40 transition-colors"
                        style={{ fontSize: 11 }}
                      >
                        Resume
                      </button>
                    ) : (
                      <span className="text-danger" style={{ fontSize: 11 }}>
                        Broken — delete & re-download
                      </span>
                    )}
                  </div>
                ) : (
                  <span
                    className="text-text-muted flex-shrink-0"
                    style={{ fontSize: 12 }}
                  >
                    {formatBytes(m.size_bytes)}
                  </span>
                )}
                <button
                  onClick={(e) => {
                    e.stopPropagation();
                    handleDelete(m.path);
                  }}
                  className="text-text-muted hover:text-danger p-1 rounded transition-colors flex-shrink-0"
                  title="Delete model"
                >
                  <svg
                    width="14"
                    height="14"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="2"
                  >
                    <path d="M3 6h18M19 6v14a2 2 0 01-2 2H7a2 2 0 01-2-2V6m3 0V4a2 2 0 012-2h4a2 2 0 012 2v2" />
                  </svg>
                </button>
              </div>
            ))}
          </div>
        </div>
      )}

      {/* Download Progress */}
      {progress && (
        <div
          className="rounded-xl border border-white/10"
          style={{
            padding: "12px 14px",
            background: "rgba(255,255,255,0.02)",
          }}
        >
          <div
            className="flex items-center justify-between"
            style={{ marginBottom: 8 }}
          >
            <span className="text-text-secondary" style={{ fontSize: 13 }}>
              Downloading {progress.filename}
            </span>
            <div className="flex items-center gap-2">
              <span className="text-text-muted" style={{ fontSize: 12 }}>
                {formatBytes(progress.downloaded)} / {formatBytes(progress.total)}
              </span>
              <button
                onClick={() => cancelDownload.mutate()}
                className="text-text-muted hover:text-danger p-1 rounded transition-colors"
                title="Cancel download"
              >
                <svg
                  width="12"
                  height="12"
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="2"
                >
                  <path d="M18 6L6 18M6 6l12 12" />
                </svg>
              </button>
            </div>
          </div>
          <div
            className="rounded-full overflow-hidden"
            style={{ height: 4, background: "rgba(255,255,255,0.1)" }}
          >
            <div
              className="h-full bg-accent rounded-full transition-all"
              style={{ width: `${progress.percent}%` }}
            />
          </div>
        </div>
      )}

      {/* Browse Models */}
      <div>
        <label
          className="block text-text-primary"
          style={{ fontSize: 14, fontWeight: 500, marginBottom: 8 }}
        >
          Get a Model
        </label>

        {sysInfo.data && (
          <p className="text-text-muted" style={{ fontSize: 11, marginBottom: 8 }}>
            {sysInfo.data.total_memory_gb} GB RAM — models up to ~{sysInfo.data.max_model_size_gb} GB recommended
          </p>
        )}

        <input
          type="text"
          value={searchQuery}
          onChange={(e) => setSearchQuery(e.target.value)}
          placeholder="Search models..."
          className={inputClass}
          style={{ ...inputStyle, marginBottom: 10 }}
        />

        <div className="flex items-center gap-1.5 flex-wrap" style={{ marginBottom: 6 }}>
          <span className="text-text-muted" style={{ fontSize: 10, width: 50, flexShrink: 0 }}>Params</span>
          {([
            { value: "all", label: "Any" },
            { value: "tiny", label: "≤ 3B" },
            { value: "small", label: "3–8B" },
            { value: "medium", label: "8–30B" },
            { value: "large", label: "30B+" },
          ] as const).map((opt) => (
            <button
              key={opt.value}
              onClick={() => setParamFilter(opt.value)}
              className={`rounded-lg border transition-colors ${
                paramFilter === opt.value
                  ? "border-accent/40 text-accent bg-accent/10"
                  : "border-white/10 text-text-muted hover:text-text-secondary hover:border-white/20"
              }`}
              style={{ padding: "4px 10px", fontSize: 11 }}
            >
              {opt.label}
            </button>
          ))}
        </div>
        <div className="flex items-center gap-1.5 flex-wrap" style={{ marginBottom: 10 }}>
          <span className="text-text-muted" style={{ fontSize: 10, width: 50, flexShrink: 0 }}>Size</span>
          {([
            { value: "all", label: "Any" },
            { value: "tiny", label: "< 500 MB" },
            { value: "small", label: "< 1 GB" },
            { value: "medium", label: "< 5 GB" },
            { value: "large", label: "5+ GB" },
          ] as const).map((opt) => (
            <button
              key={opt.value}
              onClick={() => setSizeFilter(opt.value)}
              className={`rounded-lg border transition-colors ${
                sizeFilter === opt.value
                  ? "border-accent/40 text-accent bg-accent/10"
                  : "border-white/10 text-text-muted hover:text-text-secondary hover:border-white/20"
              }`}
              style={{ padding: "4px 10px", fontSize: 11 }}
            >
              {opt.label}
            </button>
          ))}
          <button
            onClick={() => setShowQuantFilter(!showQuantFilter)}
            className={`rounded-lg border transition-colors ${
              showQuantFilter
                ? "border-accent/40 text-accent bg-accent/10"
                : "border-white/10 text-text-muted hover:text-text-secondary hover:border-white/20"
            }`}
            style={{ padding: "4px 10px", fontSize: 11 }}
          >
            Quantization {enabledQuants.size !== DEFAULT_QUANTS.size ? `(${enabledQuants.size})` : ""}
          </button>
        </div>

        {showQuantFilter && (
          <div
            className="rounded-xl border border-white/10"
            style={{ padding: "10px 12px", marginBottom: 10, background: "rgba(255,255,255,0.02)" }}
          >
            <div className="flex items-center justify-between" style={{ marginBottom: 8 }}>
              <span className="text-text-muted" style={{ fontSize: 11 }}>Show these quantization variants:</span>
              <button
                onClick={() => setEnabledQuants(new Set(DEFAULT_QUANTS))}
                className="text-text-muted hover:text-text-secondary transition-colors"
                style={{ fontSize: 10 }}
              >
                Reset defaults
              </button>
            </div>
            <div className="flex flex-wrap gap-1.5">
              {ALL_QUANTS.map((q) => (
                <button
                  key={q.pattern}
                  onClick={() => {
                    const next = new Set(enabledQuants);
                    if (next.has(q.pattern)) next.delete(q.pattern);
                    else next.add(q.pattern);
                    setEnabledQuants(next);
                  }}
                  className={`rounded border transition-colors ${
                    enabledQuants.has(q.pattern)
                      ? "border-accent/40 text-accent bg-accent/10"
                      : "border-white/10 text-text-muted hover:text-text-secondary"
                  }`}
                  style={{ padding: "2px 7px", fontSize: 10 }}
                  title={q.label}
                >
                  {q.pattern}
                </button>
              ))}
            </div>
          </div>
        )}

        {searchResults.isLoading && (
          <p className="text-text-muted" style={{ fontSize: 13 }}>
            Loading models...
          </p>
        )}

        {searchResults.data && searchResults.data
          .filter((m) => !isSingleQuantRepo(m.id))
          .filter((m) => m.recommended_file_size != null)
          .filter((m) => {
            if (sysInfo.data && m.recommended_file_size) {
              const modelGb = m.recommended_file_size / (1024 * 1024 * 1024);
              if (modelGb > sysInfo.data.max_model_size_gb) return false;
            }
            return true;
          })
          .filter((m) => passesSizeFilter(m, sizeFilter))
              .filter((m) => passesParamFilter(m, paramFilter)).length > 0 && (
          <div
            className="rounded-xl border border-white/10 overflow-hidden"
            style={{
              background: "rgba(255,255,255,0.02)",
              maxHeight: 300,
              overflowY: "auto",
            }}
          >
            {searchResults.data
              .filter((m) => !isSingleQuantRepo(m.id))
              .filter((m) => m.recommended_file_size != null)
              .filter((m) => {
                // Hide models that exceed system RAM
                if (sysInfo.data && m.recommended_file_size) {
                  const modelGb = m.recommended_file_size / (1024 * 1024 * 1024);
                  if (modelGb > sysInfo.data.max_model_size_gb) return false;
                }
                return true;
              })
              .filter((m) => passesSizeFilter(m, sizeFilter))
              .filter((m) => passesParamFilter(m, paramFilter))
              .sort((a, b) => {
                // Leaderboard-ranked models first
                const aRank = a.summarization_rank ?? 999;
                const bRank = b.summarization_rank ?? 999;
                const aHasRank = aRank < 999 ? 1 : 0;
                const bHasRank = bRank < 999 ? 1 : 0;
                if (aHasRank !== bHasRank) return bHasRank - aHasRank;
                if (aHasRank && bHasRank) return aRank - bRank;
                // Then recommended
                const aRec = smartTags(a).some((t) => t.label === "Recommended") ? 1 : 0;
                const bRec = smartTags(b).some((t) => t.label === "Recommended") ? 1 : 0;
                if (aRec !== bRec) return bRec - aRec;
                // Within same tier, smaller params first
                const aB = getParamBillions(a) ?? 999;
                const bB = getParamBillions(b) ?? 999;
                return aB - bB;
              })
              .map((model) => (
              <div
                key={model.id}
                className="border-b border-white/5 last:border-0"
              >
                <button
                  onClick={() =>
                    setExpandedRepo(
                      expandedRepo === model.id ? null : model.id
                    )
                  }
                  className="w-full flex items-center gap-3 hover:bg-white/5 transition-colors text-left"
                  style={{ padding: "10px 14px" }}
                >
                  <svg
                    width="12"
                    height="12"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="2"
                    className="text-text-muted flex-shrink-0 transition-transform"
                    style={{
                      transform:
                        expandedRepo === model.id
                          ? "rotate(90deg)"
                          : "rotate(0deg)",
                    }}
                  >
                    <path d="M9 18l6-6-6-6" />
                  </svg>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-1.5 flex-wrap">
                      <span
                        className="text-text-primary font-medium"
                        style={{ fontSize: 13 }}
                      >
                        {friendlyName(model.id)}
                      </span>
                      {getParamBillions(model) && (
                        <span className="text-text-muted" style={{ fontSize: 11 }}>
                          {getParamBillions(model)!.toFixed(1)}B
                        </span>
                      )}
                      {smartTags(model).map((tag) => (
                        <span
                          key={tag.label}
                          className={`rounded border ${tag.color}`}
                          style={{ fontSize: 9, padding: "1px 5px" }}
                        >
                          {tag.label}
                        </span>
                      ))}
                    </div>
                    <div
                      className="text-text-muted"
                      style={{ fontSize: 11, marginTop: 2 }}
                    >
                      {model.author ?? model.id.split("/")[0]} · {formatNumber(model.downloads)} downloads
                      {model.recommended_file_size && <> · {formatBytes(model.recommended_file_size)}</>}
                    </div>
                  </div>
                </button>

                {expandedRepo === model.id && (
                  <div style={{ padding: "4px 14px 12px 36px" }}>
                    <FileList
                      repoId={model.id}
                      modelFiles={modelFiles}
                      downloadModel={downloadModel}
                      handleDownload={handleDownload}
                      enabledQuants={enabledQuants}
                    />
                  </div>
                )}
              </div>
            ))}
          </div>
        )}

        {searchResults.data && searchResults.data
          .filter((m) => !isSingleQuantRepo(m.id))
          .filter((m) => m.recommended_file_size != null)
          .filter((m) => {
            if (sysInfo.data && m.recommended_file_size) {
              const modelGb = m.recommended_file_size / (1024 * 1024 * 1024);
              if (modelGb > sysInfo.data.max_model_size_gb) return false;
            }
            return true;
          })
          .filter((m) => passesSizeFilter(m, sizeFilter))
              .filter((m) => passesParamFilter(m, paramFilter)).length === 0 && (
          <p className="text-text-muted" style={{ fontSize: 13 }}>
            No models found{debouncedQuery ? ` for "${debouncedQuery}"` : ""}.
          </p>
        )}

        {searchResults.isError && (
          <p className="text-danger" style={{ fontSize: 13 }}>
            Failed to load models: {String(searchResults.error)}
          </p>
        )}
      </div>

      {/* GPU Layers — advanced */}
      <div>
        <label
          className="block text-text-muted"
          style={{ fontSize: 12, fontWeight: 500, marginBottom: 6 }}
        >
          Advanced: GPU Layers
        </label>
        <div className="flex items-center gap-3">
          <input
            type="number"
            min={-1}
            max={999}
            value={ai.local_gpu_layers ?? -1}
            onChange={(e) =>
              updateAi({
                local_gpu_layers: parseInt(e.target.value) || -1,
              })
            }
            className={inputClass}
            style={{ ...inputStyle, width: 100 }}
          />
          <span className="text-text-muted" style={{ fontSize: 11 }}>
            -1 = all on GPU (recommended for Apple Silicon)
          </span>
        </div>
      </div>
    </div>
  );
}
