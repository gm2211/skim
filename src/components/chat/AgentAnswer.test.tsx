import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { AgentAnswer, linkCitations } from "./AgentAnswer";

vi.mock("@tauri-apps/plugin-opener", () => ({ openUrl: vi.fn() }));

const sources = ["Wallpaper", "Court ruling", "Phone colors"].map((title, index) => ({
  id: `a${index + 1}`, title, feed_title: "Desk", url: null, published_at: null, source_type: "article" as const,
}));

describe("AgentAnswer citations", () => {
  it("numbers chips by where the answer first cites each article", () => {
    expect(linkCitations("Most detail is in [3], with [2] agreeing [3][2].", sources)).toBe(
      "Most detail is in [1](#skim-article-a3), with [2](#skim-article-a2) agreeing [1](#skim-article-a3)⁠[2](#skim-article-a2).",
    );
  });

  it("opens the cited article from its chip and reports hovers so the card can light up", async () => {
    const onOpenArticle = vi.fn();
    const onHoverSource = vi.fn();
    render(<AgentAnswer content="The ruling stands [2]." sources={sources} onOpenArticle={onOpenArticle} onHoverSource={onHoverSource} highlightId="a2" />);
    const chip = screen.getByRole("link", { name: "1" });
    expect(chip).toHaveClass("active");
    await userEvent.hover(chip);
    expect(onHoverSource).toHaveBeenCalledWith("a2");
    await userEvent.click(chip);
    expect(onOpenArticle).toHaveBeenCalledWith("a2");
  });
});
