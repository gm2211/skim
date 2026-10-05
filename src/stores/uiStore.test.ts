import { beforeEach, describe, expect, it } from "vitest";
import { canGoBackArticle, canGoForwardArticle, useUiStore } from "./uiStore";

const ui = () => useUiStore.getState();

describe("article history", () => {
  beforeEach(() => {
    useUiStore.setState({
      selectedArticleId: null,
      articleReturnTarget: null,
      articleHistory: [],
      articleHistoryIndex: -1,
      showCatchup: false,
      isPhone: false,
    });
  });

  it("steps back and forward through opened articles", () => {
    ui().setSelectedArticleId("a");
    ui().setSelectedArticleId("b");
    ui().openArticleFromToday("c");
    expect(canGoForwardArticle(ui())).toBe(false);

    ui().goBackArticle();
    expect(ui().selectedArticleId).toBe("b");
    ui().goBackArticle();
    expect(ui().selectedArticleId).toBe("a");
    expect(canGoBackArticle(ui())).toBe(false);
    ui().goBackArticle();
    expect(ui().selectedArticleId).toBe("a");

    ui().goForwardArticle();
    ui().goForwardArticle();
    expect(ui().selectedArticleId).toBe("c");
    expect(canGoForwardArticle(ui())).toBe(false);
  });

  it("drops forward entries when a new article is opened", () => {
    ui().setSelectedArticleId("a");
    ui().setSelectedArticleId("b");
    ui().goBackArticle();
    ui().openArticleFromCatchup("d");
    expect(ui().articleHistory).toEqual(["a", "d"]);
    expect(canGoForwardArticle(ui())).toBe(false);
  });

  it("does not duplicate the current article", () => {
    ui().setSelectedArticleId("a");
    ui().setSelectedArticleId("a");
    expect(ui().articleHistory).toEqual(["a"]);
  });

  it("reopens the last article after the reader is closed", () => {
    ui().setSelectedArticleId("a");
    ui().setSelectedArticleId("b");
    ui().closeArticleDetail();
    expect(canGoBackArticle(ui())).toBe(true);
    expect(canGoForwardArticle(ui())).toBe(false);
    ui().goBackArticle();
    expect(ui().selectedArticleId).toBe("b");
    ui().goBackArticle();
    expect(ui().selectedArticleId).toBe("a");
  });

  it("keeps history when switching feeds", () => {
    ui().setSelectedArticleId("a");
    ui().setSidebarView({ type: "starred" });
    ui().goBackArticle();
    expect(ui().selectedArticleId).toBe("a");
  });
});
