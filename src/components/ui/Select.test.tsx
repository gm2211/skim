import { describe, expect, it, vi } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { Select } from "./Select";

describe("Select", () => {
  it("stays a labelable native select so the OS picker keeps working", async () => {
    const onChange = vi.fn();
    render(
      <label>
        Include
        <Select value="unread" onChange={onChange}>
          <option value="inbox">Priority inbox</option>
          <option value="unread">All unread articles</option>
        </Select>
      </label>
    );

    const select = screen.getByLabelText("Include");
    expect(select.tagName).toBe("SELECT");

    await userEvent.setup().selectOptions(select, "inbox");
    expect(onChange).toHaveBeenCalledOnce();
  });

  it("sizes to its content unless asked to fill the row", () => {
    const { rerender } = render(
      <Select aria-label="scope" value="a" onChange={() => {}}>
        <option value="a">A</option>
      </Select>
    );
    expect(screen.getByLabelText("scope")).not.toHaveClass("w-full");

    rerender(
      <Select aria-label="scope" fullWidth value="a" onChange={() => {}}>
        <option value="a">A</option>
      </Select>
    );
    expect(screen.getByLabelText("scope")).toHaveClass("w-full");
  });
});
