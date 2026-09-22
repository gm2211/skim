import { useRef } from "react";
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useDialogFocus } from "./useDialogFocus";

function Dialog({ onClose, enabled = true }: { onClose: () => void; enabled?: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  useDialogFocus(ref, onClose, enabled);
  return (
    <div ref={ref} role="dialog" tabIndex={-1}>
      <p>Some text you can click but not focus</p>
      <button>First</button>
      <button>Last</button>
    </div>
  );
}

afterEach(cleanup);

/**
 * Focus leaves a dialog constantly in normal use: you click a paragraph, or
 * the button you were on unmounts when the dialog's content changes. A
 * listener bound to the dialog element goes deaf the moment that happens, so
 * the dialog can only be closed with the mouse.
 */
describe("useDialogFocus", () => {
  it("closes on Escape while focus is inside the dialog", () => {
    const onClose = vi.fn();
    render(<Dialog onClose={onClose} />);
    fireEvent.keyDown(screen.getByRole("button", { name: "First" }), { key: "Escape" });
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("still closes on Escape after focus falls back to the body", () => {
    const onClose = vi.fn();
    render(<Dialog onClose={onClose} />);
    (document.activeElement as HTMLElement | null)?.blur();
    expect(document.activeElement).toBe(document.body);

    fireEvent.keyDown(document.body, { key: "Escape" });
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("pulls Tab back into the dialog when focus has escaped it", () => {
    render(<Dialog onClose={() => {}} />);
    (document.activeElement as HTMLElement | null)?.blur();

    fireEvent.keyDown(document.body, { key: "Tab" });
    expect(document.activeElement).toBe(screen.getByRole("button", { name: "First" }));
  });

  it("stays out of the way while a stacked dialog is in charge", () => {
    const onClose = vi.fn();
    render(<Dialog onClose={onClose} enabled={false} />);
    fireEvent.keyDown(document.body, { key: "Escape" });
    expect(onClose).not.toHaveBeenCalled();
  });
});
