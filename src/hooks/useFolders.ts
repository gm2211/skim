import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import * as commands from "../services/commands";
import type { SmartRules } from "../services/types";

export function useFolders() {
  return useQuery({
    queryKey: ["folders"],
    queryFn: commands.listFolders,
    refetchInterval: 60_000,
  });
}

export function useCreateFolder() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: commands.createFolder,
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["folders"] });
    },
  });
}

export function useCreateSmartFolder() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ name, rules }: { name: string; rules: SmartRules }) =>
      commands.createSmartFolder(name, rules),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["folders"] });
    },
  });
}

export function useRenameFolder() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ folderId, name }: { folderId: string; name: string }) =>
      commands.renameFolder(folderId, name),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["folders"] });
    },
  });
}

export function useUpdateSmartFolderRules() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ folderId, rules }: { folderId: string; rules: SmartRules }) =>
      commands.updateSmartFolderRules(folderId, rules),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["folders"] });
    },
  });
}

export function useDeleteFolder() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: commands.deleteFolder,
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["folders"] });
      qc.invalidateQueries({ queryKey: ["feeds"] });
    },
  });
}

export function useAssignFeedToFolder() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ feedId, folderId }: { feedId: string; folderId: string | null }) =>
      commands.assignFeedToFolder(feedId, folderId),
    onSuccess: () => {
      qc.invalidateQueries({ queryKey: ["feeds"] });
      qc.invalidateQueries({ queryKey: ["folders"] });
    },
  });
}
