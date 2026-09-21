import { act, renderHook, waitFor } from "@testing-library/react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { describe, expect, it, vi } from "vitest";
import type { ReactNode } from "react";
import { useMarkAllRead, useMarkRead, useMarkUnread, useToggleRead } from "./useArticles";
import { useTriageStats } from "./useInbox";
import * as commands from "../services/commands";

vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn().mockResolvedValue(() => {}) }));
vi.mock("../services/commands", () => ({
  getTriageStats: vi.fn(),
  markArticlesRead: vi.fn(),
  markArticlesUnread: vi.fn(),
  markAllRead: vi.fn(),
  toggleRead: vi.fn(),
}));

function setup() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } });
  const wrapper = ({ children }: { children: ReactNode }) => (
    <QueryClientProvider client={client}>{children}</QueryClientProvider>
  );
  const hooks = renderHook(
    () => ({
      stats: useTriageStats(),
      markRead: useMarkRead(),
      markUnread: useMarkUnread(),
      markAllRead: useMarkAllRead(),
      toggleRead: useToggleRead(),
    }),
    { wrapper },
  );
  return { client, ...hooks };
}

type Hooks = ReturnType<typeof setup>["result"]["current"];

/**
 * The sidebar's AI Inbox badge is `triageStats.total`, which is the unread
 * count. Every mutation that changes read state has to refetch it, or the
 * badge sits at the number it had when the app launched while the list header
 * beside it counts down.
 */
describe("AI Inbox badge tracks read state", () => {
  it.each([
    ["marking one read", (h: Hooks) => h.markRead.mutateAsync(["article"])],
    ["marking one unread", (h: Hooks) => h.markUnread.mutateAsync(["article"])],
    ["marking all read", (h: Hooks) => h.markAllRead.mutateAsync(null)],
    ["toggling read", (h: Hooks) => h.toggleRead.mutateAsync("article")],
  ])("refetches the badge count after %s", async (_label, run) => {
    let unread = 10;
    vi.mocked(commands.getTriageStats).mockImplementation(async () => ({
      total: unread,
      by_priority: {},
    }));
    const countDown = async () => {
      unread -= 1;
    };
    vi.mocked(commands.markArticlesRead).mockImplementation(countDown);
    vi.mocked(commands.markArticlesUnread).mockImplementation(countDown);
    vi.mocked(commands.markAllRead).mockImplementation(countDown);
    vi.mocked(commands.toggleRead).mockImplementation(async () => {
      await countDown();
      return true;
    });

    const { result, unmount, client } = setup();
    await waitFor(() => expect(result.current.stats.data?.total).toBe(10));
    await act(async () => {
      await run(result.current);
    });
    await waitFor(() => expect(result.current.stats.data?.total).toBe(9));

    unmount();
    client.clear();
  });
});
