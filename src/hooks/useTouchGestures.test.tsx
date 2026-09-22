import { cleanup, createEvent, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { usePullToRefresh } from "./usePullToRefresh";
import { useSwipeToDismiss } from "./useSwipeToDismiss";

function touchList(x: number, y: number) {
  return [{ clientX: x, clientY: y }];
}

function dispatchMove(node: HTMLElement, x: number, y: number) {
  const event = createEvent.touchMove(node, { touches: touchList(x, y) });
  fireEvent(node, event);
  return event;
}

function Puller() {
  const { pullToRefreshHandlers } = usePullToRefresh({
    enabled: true,
    canStart: () => true,
    onRefresh: () => {},
  });
  return (
    <div data-testid="surface" {...pullToRefreshHandlers}>
      list
    </div>
  );
}

function Sheet() {
  const { swipeToDismissHandlers } = useSwipeToDismiss(true, () => {});
  return (
    <div data-testid="surface" {...swipeToDismissHandlers}>
      sheet
    </div>
  );
}

afterEach(cleanup);

/**
 * React attaches touchmove at its root as a passive listener, so
 * preventDefault() inside an onTouchMove prop is ignored and the page scrolls
 * underneath the gesture. Both hooks therefore own the move themselves with a
 * non-passive listener registered for the length of each gesture.
 */
describe.each([
  ["usePullToRefresh", Puller],
  ["useSwipeToDismiss", Sheet],
])("%s touch gesture", (_name, Component) => {
  it("registers its touchmove listener as non-passive", () => {
    render(<Component />);
    const node = screen.getByTestId("surface");
    const spy = vi.spyOn(node, "addEventListener");

    fireEvent.touchStart(node, { touches: touchList(40, 100) });

    const move = spy.mock.calls.find(([type]) => type === "touchmove");
    expect(move).toBeDefined();
    expect(move?.[2]).toEqual({ passive: false });
  });

  it("prevents the default scroll once the gesture is a downward drag", () => {
    render(<Component />);
    const node = screen.getByTestId("surface");
    fireEvent.touchStart(node, { touches: touchList(40, 100) });

    expect(dispatchMove(node, 40, 160).defaultPrevented).toBe(true);
  });

  it("leaves a horizontal gesture to the browser", () => {
    render(<Component />);
    const node = screen.getByTestId("surface");
    fireEvent.touchStart(node, { touches: touchList(40, 100) });

    expect(dispatchMove(node, 140, 102).defaultPrevented).toBe(false);
  });

  it("stops listening once the gesture ends", () => {
    render(<Component />);
    const node = screen.getByTestId("surface");
    fireEvent.touchStart(node, { touches: touchList(40, 100) });
    fireEvent.touchEnd(node, { touches: [] });

    expect(dispatchMove(node, 40, 220).defaultPrevented).toBe(false);
  });

  it("stops listening when the component unmounts mid-gesture", () => {
    const { unmount } = render(<Component />);
    const node = screen.getByTestId("surface");
    fireEvent.touchStart(node, { touches: touchList(40, 100) });
    unmount();

    expect(dispatchMove(node, 40, 220).defaultPrevented).toBe(false);
  });
});
