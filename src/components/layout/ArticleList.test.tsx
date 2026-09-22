import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { useUiStore } from "../../stores/uiStore";
import { ArticleList, buildArticleFilter, buildMarkAllReadScope } from "./ArticleList";

describe("buildArticleFilter", () => {
  it.each([
    { type: "inbox" as const },
    { type: "recent" as const },
    { type: "theme" as const, themeId: "theme-1" },
    { type: "folder" as const, folderId: "folder-1" },
  ])("makes search global from %s", (sidebarView) => {
    expect(buildArticleFilter({
      sidebarView,
      listFilter: "unread",
      pageLimit: 200,
      searchQuery: "  climate  ",
      folderFeedIds: ["feed-1"],
    })).toEqual({ limit: 200, search: "climate" });
  });

  it("keeps folder feed membership when search is cleared", () => {
    expect(buildArticleFilter({
      sidebarView: { type: "folder", folderId: "folder-1" },
      listFilter: "starred",
      pageLimit: 200,
      searchQuery: "",
      folderFeedIds: ["feed-1", "feed-2"],
    })).toEqual({
      limit: 200,
      feed_ids: ["feed-1", "feed-2"],
      is_starred: true,
    });
  });
});


const mock = vi.hoisted(() => ({ markAll: vi.fn() }));
const mutation = () => ({ mutate: vi.fn(), isPending: false });
vi.mock("../../hooks/useArticles", () => ({
  useArticles: (filter: { search?: string }) => ({ data: filter.search ? [{
    id: "url-match", title: "Unrelated title", feed_title: "Source", content_text: "Body",
    url: "https://unique-domain.example/story", is_read: true, fetched_at: 100,
  }] : [] }),
  useArticleCount: () => ({ data: 0 }),
  useMarkAllRead: () => ({ mutate: mock.markAll, isPending: false }),
  useMarkRead: () => mutation(), useMarkUnread: () => mutation(),
  useToggleRead: () => mutation(), useToggleStar: () => mutation(),
}));
vi.mock("../../hooks/useInbox", () => ({ useInboxArticles: () => ({ data: [] }) }));
vi.mock("../../hooks/useRecent", () => ({
  useRecentArticles: () => ({ data: [] }), useRemoveRecent: () => mutation(),
}));
vi.mock("../../hooks/useFeeds", () => ({
  useFeeds: () => ({ data: [{ id: "f1", title: "Source", folder_id: "folder-1" }] }),
  useRefreshAllFeeds: () => mutation(),
}));
vi.mock("../../hooks/useFolders", () => ({
  useFolders: () => ({ data: [{ id: "folder-1", name: "Folder", is_smart: false }] }),
}));
vi.mock("../../hooks/useThemes", () => ({
  useThemes: () => ({ data: [] }), useArticleThemeTags: () => ({ data: [] }),
}));
vi.mock("../../hooks/usePullToRefresh", () => ({ usePullToRefresh: () => ({}) }));
vi.mock("../article/ArticleCard", () => ({
  ArticleCard: ({ article }: { article: { title: string } }) => <div>{article.title}</div>,
}));
vi.mock("../chat/AskSkimDialog", () => ({ AskSkimDialog: () => null }));

const initialState = useUiStore.getState();
beforeEach(() => {
  mock.markAll.mockClear();
  useUiStore.setState({ ...initialState, sidebarView: { type: "all" }, listFilter: "unread" }, true);
});
afterEach(cleanup);

describe("article list scope regressions", () => {
  it.each(["inbox", "recent", "all"] as const)("renders backend URL-only search matches from %s", async (type) => {
    useUiStore.setState({ sidebarView: { type } });
    render(<ArticleList />);
    await userEvent.type(screen.getByPlaceholderText("Search articles..."), "unique-domain");
    expect(screen.getByText("Unrelated title")).toBeInTheDocument();
    expect(screen.getByText("Search Results")).toBeInTheDocument();
    expect(screen.queryByText("Show them")).not.toBeInTheDocument();
  });

  it("marks the selected folder scope, not the global library", async () => {
    useUiStore.setState({ sidebarView: { type: "folder", folderId: "folder-1" } });
    render(<ArticleList />);
    await userEvent.click(screen.getByTitle("Mark all as read"));
    expect(mock.markAll).toHaveBeenCalledWith({
      filter: { limit: 200, feed_ids: ["f1"], is_read: false }, recentOnly: false,
    }, expect.anything());
  });

  it("keeps the efficient global action only for the unsearched All view", async () => {
    render(<ArticleList />);
    await userEvent.click(screen.getByTitle("Mark all as read"));
    expect(mock.markAll).toHaveBeenLastCalledWith(null, expect.anything());
    await userEvent.type(screen.getByPlaceholderText("Search articles..."), "unique-domain");
    await userEvent.click(screen.getByTitle("Mark all as read"));
    expect(mock.markAll).toHaveBeenLastCalledWith({
      filter: { limit: 200, search: "unique-domain", is_read: false }, recentOnly: false,
    }, expect.anything());
  });

  it.each([
    [{ type: "theme", themeId: "t1" }, { theme_id: "t1" }, false],
    [{ type: "starred" }, { is_starred: true }, false],
    [{ type: "inbox" }, { theme_id: "active-theme" }, false],
    [{ type: "recent" }, {}, true],
    [{ type: "all" }, {}, false],
    [{ type: "today" }, { feed_ids: [] }, false],
  ] as const)("builds bounded bulk scope for %s", (sidebarView, expected, recentOnly) => {
    expect(buildMarkAllReadScope({
      sidebarView, listFilter: "all", searchQuery: "", folderFeedIds: [], activeThemeId: "active-theme",
    })).toEqual({ filter: { limit: 200, is_read: false, ...expected }, recentOnly });
  });
});
