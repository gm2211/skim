import { useQuery } from "@tanstack/react-query";
import { isTauri } from "@tauri-apps/api/core";
import { appStoreInstall } from "../services/commands";
import { isMacOS } from "../utils/platform";

/**
 * Whether this copy came from the Mac App Store or TestFlight. While the check runs, the Mac app
 * assumes it is, so a store copy never shows options it must not offer; off the app it is false.
 */
export function useAppStoreInstall(): boolean {
  const { data } = useQuery({
    queryKey: ["app-store-install"],
    queryFn: () => appStoreInstall().catch(() => false),
    enabled: isTauri(),
    staleTime: Infinity,
  });
  return data ?? (isTauri() && isMacOS);
}
