import { type CSSProperties, type TouchEvent, useCallback, useEffect, useRef, useState } from "react";

type SwipeState = {
  startX: number;
  startY: number;
  lastY: number;
  lastAt: number;
  intent: "pending" | "vertical" | "horizontal";
};

type Phase = "idle" | "dragging" | "settling" | "dismissing";

const INTENT_PX = 10;
const DISMISS_PX = 96;
const FAST_PX_PER_MS = 0.7;
const MAX_DRAG_PX = 220;
const SETTLE_MS = 260;
const DISMISS_MS = 180;

export function useSwipeToDismiss(enabled: boolean, onDismiss: () => void) {
  const swipeRef = useRef<SwipeState | null>(null);
  const dismissRef = useRef(onDismiss);
  const timerRef = useRef<number | null>(null);
  const velocityRef = useRef(0);
  const [offset, setOffset] = useState(0);
  const [phase, setPhase] = useState<Phase>("idle");

  dismissRef.current = onDismiss;

  const clearTimer = useCallback(() => {
    if (timerRef.current !== null) {
      window.clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  }, []);

  const reset = useCallback(() => {
    clearTimer();
    setPhase("settling");
    setOffset(0);
    timerRef.current = window.setTimeout(() => {
      setPhase("idle");
      timerRef.current = null;
    }, SETTLE_MS + 40);
  }, [clearTimer]);

  const onTouchStart = useCallback((event: TouchEvent<HTMLElement>) => {
    if (!enabled) return;
    const touch = event.touches[0];
    if (!touch) return;
    clearTimer();
    velocityRef.current = 0;
    swipeRef.current = {
      startX: touch.clientX,
      startY: touch.clientY,
      lastY: touch.clientY,
      lastAt: performance.now(),
      intent: "pending",
    };
    setPhase("dragging");
  }, [clearTimer, enabled]);

  const onTouchMove = useCallback((event: TouchEvent<HTMLElement>) => {
    const swipe = swipeRef.current;
    if (!enabled || !swipe) return;
    const touch = event.touches[0];
    if (!touch) return;

    const now = performance.now();
    const dt = Math.max(1, now - swipe.lastAt);
    velocityRef.current = (touch.clientY - swipe.lastY) / dt;
    swipe.lastY = touch.clientY;
    swipe.lastAt = now;

    const dx = touch.clientX - swipe.startX;
    const dy = touch.clientY - swipe.startY;
    const absDx = Math.abs(dx);
    const absDy = Math.abs(dy);

    if (swipe.intent === "pending") {
      if (absDx > INTENT_PX && absDx > absDy) {
        swipe.intent = "horizontal";
      } else if (absDy > INTENT_PX && absDy > absDx) {
        swipe.intent = "vertical";
      }
    }

    if (swipe.intent !== "vertical" || dy <= 0) return;
    event.preventDefault();

    const eased = dy <= MAX_DRAG_PX ? dy : MAX_DRAG_PX + (dy - MAX_DRAG_PX) * 0.18;
    setOffset(eased);
  }, [enabled]);

  const onTouchEnd = useCallback(() => {
    const swipe = swipeRef.current;
    swipeRef.current = null;
    if (!enabled || !swipe || swipe.intent !== "vertical") {
      if (offset !== 0) reset();
      return;
    }

    const distance = Math.max(0, swipe.lastY - swipe.startY);
    const fast = velocityRef.current >= FAST_PX_PER_MS && distance > 32;
    if (distance >= DISMISS_PX || fast) {
      clearTimer();
      setPhase("dismissing");
      setOffset(window.innerHeight);
      timerRef.current = window.setTimeout(() => {
        timerRef.current = null;
        dismissRef.current();
      }, DISMISS_MS);
      return;
    }

    reset();
  }, [clearTimer, enabled, offset, reset]);

  const style: CSSProperties = enabled
    ? {
        transform: `translate3d(0, ${offset}px, 0)`,
        transition: phase === "dragging" ? "none" : `transform ${phase === "dismissing" ? DISMISS_MS : SETTLE_MS}ms cubic-bezier(0.22, 1, 0.36, 1)`,
        willChange: "transform",
      }
    : {};

  useEffect(() => clearTimer, [clearTimer]);

  return {
    swipeToDismissHandlers: {
      onTouchStart,
      onTouchMove,
      onTouchEnd,
      onTouchCancel: onTouchEnd,
    },
    swipeToDismissStyle: style,
  };
}
