import { beforeEach, describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { ArticleLearningActions } from "./ArticleLearningActions";

const mutate = vi.fn();
let priorityOverride: number | null = null;
let mutationError: Error | null = null;

vi.mock("../../hooks/useLearning", () => ({
  useArticleInteraction: () => ({ data: priorityOverride == null ? null : { priority_override: priorityOverride } }),
  useSetPriorityOverride: () => ({ mutate, isPending: false, error: mutationError }),
}));

beforeEach(() => {
  priorityOverride = null;
  mutationError = null;
  mutate.mockReset();
});

describe("ArticleLearningActions", () => {
  it("exposes accessible pin and hide actions", async () => {
    const user = userEvent.setup();
    render(<ArticleLearningActions articleId="article-1" />);

    expect(screen.getByRole("group", { name: "Learning actions" })).toBeInTheDocument();
    await user.click(screen.getByRole("button", { name: "Pin to top" }));
    await user.click(screen.getByRole("button", { name: "Hide from inbox" }));

    expect(mutate).toHaveBeenNthCalledWith(1, { articleId: "article-1", priority: 5 });
    expect(mutate).toHaveBeenNthCalledWith(2, { articleId: "article-1", priority: 1 });
  });

  it("offers the native-style toggle labels and clears to neutral priority", async () => {
    priorityOverride = 5;
    const user = userEvent.setup();
    render(<ArticleLearningActions articleId="article-1" />);

    expect(screen.getByRole("button", { name: "Unpin" })).toHaveAttribute("aria-pressed", "true");
    await user.click(screen.getByRole("button", { name: "Unpin" }));
    expect(mutate).toHaveBeenCalledWith({ articleId: "article-1", priority: 3 });
  });

  it("marks a hidden article as active and supports unhiding", async () => {
    priorityOverride = 1;
    const user = userEvent.setup();
    render(<ArticleLearningActions articleId="article-1" />);

    const button = screen.getByRole("button", { name: "Unhide from inbox" });
    expect(button).toHaveAttribute("aria-pressed", "true");
    await user.click(button);
    expect(mutate).toHaveBeenCalledWith({ articleId: "article-1", priority: 3 });
  });

  it("announces a failed learning update without hiding the controls", () => {
    mutationError = new Error("Database unavailable");
    render(<ArticleLearningActions articleId="article-1" />);

    expect(screen.getByRole("alert")).toHaveTextContent("Could not update learning preference: Database unavailable");
    expect(screen.getByRole("button", { name: "Pin to top" })).toBeInTheDocument();
  });
});
