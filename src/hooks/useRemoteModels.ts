import { useQuery } from "@tanstack/react-query";
import { listRemoteModels, type RemoteModel } from "../services/commands";

/** Short, non-reversible tag for a credential, so a new key gets its own cached list without the key itself sitting in the cache key. */
function credentialTag(apiKey: string | null): string {
  if (!apiKey) return "none";
  let hash = 0x811c9dc5;
  for (let i = 0; i < apiKey.length; i++) hash = Math.imul(hash ^ apiKey.charCodeAt(i), 0x01000193);
  return (hash >>> 0).toString(36);
}

export const remoteModelsKey = (provider: string, apiKey: string | null, endpoint: string | null) =>
  ["remote-models", provider, endpoint, credentialTag(apiKey)] as const;

/**
 * A provider's live model list, shared by Settings and every inline picker so
 * a list one of them loads shows up in the others. It loads on its own: an
 * empty or failed list is treated as stale, so the next picker that mounts
 * (opening Settings, a chat config popover) fetches it again instead of
 * waiting for someone to press refresh.
 */
export function useRemoteModels(provider: string, apiKey: string | null, endpoint: string | null, enabled = true) {
  return useQuery<RemoteModel[]>({
    queryKey: remoteModelsKey(provider, apiKey, endpoint),
    queryFn: () => listRemoteModels(provider, apiKey, endpoint),
    enabled,
    staleTime: (query) => (query.state.data?.length ? 600_000 : 0),
    retry: 1,
    retryDelay: 800,
  });
}
