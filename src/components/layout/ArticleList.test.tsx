import { describe, expect, it } from "vitest";
import { buildArticleFilter } from "./ArticleList";

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
