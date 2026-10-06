import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { describe, expect, it, vi } from "vitest";
import { AIBootDisclaimer } from "./AIBootDisclaimer";

describe("AIBootDisclaimer", () => {
  it("passes the Don't show again choice to Got it", async () => {
    const onDismiss = vi.fn();
    const user = userEvent.setup();
    render(<AIBootDisclaimer onDismiss={onDismiss} />);
    await user.click(screen.getByLabelText("Don't show again until the next update"));
    await user.click(screen.getByRole("button", { name: "Got it" }));
    expect(onDismiss).toHaveBeenCalledWith(true);
  });

  it("defaults to showing the notice again next launch", async () => {
    const onDismiss = vi.fn();
    const user = userEvent.setup();
    render(<AIBootDisclaimer onDismiss={onDismiss} />);
    await user.click(screen.getByRole("button", { name: "Got it" }));
    expect(onDismiss).toHaveBeenCalledWith(false);
  });
});
