import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { Sidebar } from "./Sidebar";
import { useUiStore } from "../../stores/uiStore";

// Sidebar pulls in a lot of AI-inbox/theme machinery that isn't relevant to
// this regression guard — stub it so the test only depends on navigation.
vi.mock("../../hooks/useFeeds", () => ({
  useFeeds: () => ({ data: [] }),
  useRefreshAllFeeds: () => ({ mutate: vi.fn(), isPending: false }),
}));
vi.mock("../../hooks/useInbox", () => ({
  useTriageArticles: () => ({ isPending: false, mutate: vi.fn() }),
  useTriageStats: () => ({ data: undefined }),
  useTriageProgress: () => undefined,
}));
vi.mock("../../hooks/useThemes", () => ({
  useGenerateThemes: () => ({ isPending: false, mutate: vi.fn() }),
  useThemeProgress: () => undefined,
}));
vi.mock("./FeedsSection", () => ({
  FeedsSection: () => null,
}));

// Snapshot of the store's shape (including its stable action closures) taken
// once at module load, before any test mutates it.
const INITIAL_STATE = useUiStore.getState();

beforeEach(() => {
  useUiStore.setState({ ...INITIAL_STATE, sidebarView: { type: "today" } }, true);
});

describe("Sidebar — All Articles regression guard", () => {
  // Today is a new, finite, sectioned destination sitting above All
  // Articles. All Articles must remain the complete chronological archive,
  // reachable in a single click, no matter which sidebar destination is
  // currently active — this guards against Today ever hiding or replacing it.
  it("keeps All Articles visible and one click away while viewing Today", async () => {
    const user = userEvent.setup();
    render(<Sidebar />);

    expect(useUiStore.getState().sidebarView).toEqual({ type: "today" });
    const allArticles = screen.getByText("All Articles");
    expect(allArticles).toBeInTheDocument();

    await user.click(allArticles);

    expect(useUiStore.getState().sidebarView).toEqual({ type: "all" });
  });

  it("shows both the Today destination and All Articles together", () => {
    render(<Sidebar />);
    expect(screen.getByText("Today")).toBeInTheDocument();
    expect(screen.getByText("All Articles")).toBeInTheDocument();
  });

  it("the header bolt button now opens Today, not the legacy Catch-up dialog", async () => {
    const user = userEvent.setup();
    useUiStore.setState({ ...INITIAL_STATE, sidebarView: { type: "all" } }, true);
    render(<Sidebar />);

    await user.click(screen.getByTitle("Today — your finite, sectioned daily edition"));

    expect(useUiStore.getState().sidebarView).toEqual({ type: "today" });
    expect(useUiStore.getState().showCatchup).toBe(false);
  });
});
