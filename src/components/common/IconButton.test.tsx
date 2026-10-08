import { expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { IconButton } from "./IconButton";

it("keeps an accessible name and dismisses its keyboard tooltip before bubbling Escape", async () => {
  const outerKeyDown = vi.fn();
  const user = userEvent.setup();
  render(<div onKeyDown={outerKeyDown}><IconButton label="Refresh feeds"><svg aria-hidden="true" /></IconButton></div>);
  const button = screen.getByRole("button", { name: "Refresh feeds" });
  const tooltip = screen.getByText("Refresh feeds").parentElement!;
  await user.tab();
  expect(button).toHaveFocus();
  outerKeyDown.mockClear();
  await user.keyboard("{Escape}");
  expect(tooltip).toHaveClass("hidden");
  expect(outerKeyDown).not.toHaveBeenCalled();
  await user.keyboard("{Escape}");
  expect(outerKeyDown).toHaveBeenCalledOnce();
  await user.tab();
  expect(tooltip).not.toHaveClass("hidden");
});
