import { useQueries, useQuery } from "@tanstack/react-query";
import type { AiSettings } from "../services/types";
import { listRemoteModels, mlxIsModelDownloaded } from "../services/commands";
import {
  REMOTE_LIST_PROVIDERS,
  hasChatOverride,
  mlxModelsFor,
  providerLabel,
  resolveMlxRepoId,
} from "../lib/aiModels";
import { useLocalModels } from "./useModels";

export type ModelSurface = "catchup" | "chat" | "summarize" | "today";

export interface ModelChoice {
  value: string;
  label: string;
  disabled?: boolean;
  hint?: string;
}

export interface ModelChoices {
  /** "list": the surface can switch models inline. "fixed": read-only. */
  mode: "list" | "fixed";
  current: string;
  currentLabel: string;
  choices: ModelChoice[];
  loading: boolean;
  error: string | null;
}

const DEFAULT_MODEL_LABEL = "Default model";

/**
 * Model options for one AI surface, derived from the same AppSettings the
 * Settings dialog edits. Provider itself is never editable here — only which
 * model that provider uses — so a chat-only override (ai.chat_provider) makes
 * the surface read-only rather than letting an inline pick silently switch
 * providers underneath it.
 */
export function useModelChoices(
  ai: AiSettings,
  opts: { isPhone: boolean; surface: ModelSurface },
): ModelChoices {
  const { isPhone, surface } = opts;
  const chatOverrideActive = surface === "chat" && hasChatOverride(ai);
  const provider = ai.provider;

  const mlxModels = mlxModelsFor(isPhone);
  const isMlx = !chatOverrideActive && provider === "mlx";
  const isLocal = !chatOverrideActive && provider === "local";
  const isRemote =
    !chatOverrideActive && (REMOTE_LIST_PROVIDERS as readonly string[]).includes(provider);

  // Hooks run unconditionally regardless of which branch below applies.
  const mlxDownloadQueries = useQueries({
    queries: isMlx
      ? mlxModels.map((m) => ({
          queryKey: ["mlx-downloaded", m.repoId],
          queryFn: () => mlxIsModelDownloaded(m.repoId),
          staleTime: 60_000,
        }))
      : [],
  });
  const localModelsQuery = useLocalModels();
  const remoteQuery = useQuery({
    queryKey: ["remote-models", provider, ai.endpoint],
    queryFn: () => listRemoteModels(provider, ai.api_key, ai.endpoint),
    enabled: isRemote,
    staleTime: 600_000,
    retry: false,
  });

  if (chatOverrideActive) {
    const current = ai.chat_model ?? "";
    const label = ai.chat_model || DEFAULT_MODEL_LABEL;
    return {
      mode: "fixed",
      current,
      currentLabel: label,
      choices: [{ value: current, label }],
      loading: false,
      error: null,
    };
  }

  if (isMlx) {
    const current = resolveMlxRepoId(ai, isPhone);
    const choices: ModelChoice[] = mlxModels.map((m, i) => {
      const downloaded = mlxDownloadQueries[i]?.data;
      return {
        value: m.repoId,
        label: m.label,
        disabled: downloaded === false,
        hint: downloaded === false ? "not downloaded" : undefined,
      };
    });
    const currentLabel = mlxModels.find((m) => m.repoId === current)?.label ?? current;
    return {
      mode: "list",
      current,
      currentLabel,
      choices,
      loading: mlxDownloadQueries.some((q) => q.isLoading),
      error: null,
    };
  }

  if (isLocal) {
    const models = (localModelsQuery.data ?? []).filter((m) => !m.is_partial);
    const current = ai.local_model_path ?? "";
    const choices: ModelChoice[] = models.map((m) => ({ value: m.path, label: m.filename }));
    const currentLabel =
      models.find((m) => m.path === current)?.filename ??
      (current ? current.split("/").pop() ?? current : DEFAULT_MODEL_LABEL);
    return {
      mode: "list",
      current,
      currentLabel,
      choices,
      loading: localModelsQuery.isLoading,
      error: localModelsQuery.error ? String(localModelsQuery.error) : null,
    };
  }

  if (isRemote) {
    const current = ai.model ?? "";
    if (remoteQuery.isError) {
      // Failure to load the list: keep only the current selection choosable.
      const label = current || DEFAULT_MODEL_LABEL;
      return {
        mode: "list",
        current,
        currentLabel: label,
        choices: [{ value: current, label }],
        loading: false,
        error: String(remoteQuery.error),
      };
    }
    const merged = new Map<string, string>();
    merged.set("", DEFAULT_MODEL_LABEL);
    for (const m of remoteQuery.data ?? []) merged.set(m.id, m.display_name || m.id);
    if (current && !merged.has(current)) merged.set(current, current);
    const choices: ModelChoice[] = Array.from(merged, ([value, label]) => ({ value, label }));
    const currentLabel = merged.get(current) ?? (current || DEFAULT_MODEL_LABEL);
    return {
      mode: "list",
      current,
      currentLabel,
      choices,
      loading: remoteQuery.isLoading,
      error: null,
    };
  }

  // Fixed providers: ds4, foundation-models, claude-subscription, claude-cli,
  // ollama, none — free text or nothing, never inline-editable here.
  const current = ai.model ?? "";
  const label = current || providerLabel(provider);
  return {
    mode: "fixed",
    current,
    currentLabel: label,
    choices: [{ value: current, label }],
    loading: false,
    error: null,
  };
}
