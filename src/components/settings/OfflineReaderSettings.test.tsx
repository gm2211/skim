import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { OfflineReaderSettings } from "./OfflineReaderSettings";
import { getOfflineCacheStats, preloadArticlesForOffline } from "../../services/commands";

vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn().mockResolvedValue(vi.fn()) }));
vi.mock("../../services/commands", () => ({
  OFFLINE_PRELOAD_PROGRESS_EVENT: "skim-reader://offline-preload-progress",
  getOfflineCacheStats: vi.fn(),
  preloadArticlesForOffline: vi.fn(),
}));

beforeEach(() => {
  vi.clearAllMocks();
  Object.defineProperty(globalThis, "localStorage", { configurable: true, value: { getItem: vi.fn(() => null), setItem: vi.fn() } });
  vi.mocked(getOfflineCacheStats).mockResolvedValue({ extracted_articles: 7 });
  vi.mocked(preloadArticlesForOffline).mockResolvedValue({ completed: 25, total: 25, cached: 4, already_ready: 20, failed: 1, current_title: null });
});

describe("OfflineReaderSettings", () => {
  it("preloads only after user action and reports cache results", async () => {
    render(<OfflineReaderSettings />);
    expect(preloadArticlesForOffline).not.toHaveBeenCalled();
    expect(await screen.findByText(/7 extracted articles cached/)).toBeInTheDocument();

    await userEvent.setup().click(screen.getByRole("button", { name: "Preload articles" }));

    expect(preloadArticlesForOffline).toHaveBeenCalledWith(300);
    expect(await screen.findByText(/24 ready, 4 newly cached, 1 failed/)).toBeInTheDocument();
  });
});
