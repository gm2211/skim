import {
  type CSSProperties,
  type ReactNode,
  type TouchEvent,
  useCallback,
  useEffect,
  useRef,
  useState,
} from "react";

type PullState = {
  startX: number;
  startY: number;
  lastY: number;
  lastAt: number;
  intent: "pending" | "pull" | "horizontal" | "vertical-up";
};

type Phase = "idle" | "pulling" | "refreshing" | "settling";

const INTENT_PX = 10;
const ACTIVATE_PX = 84;
const HOLD_PX = 52;
const MAX_PULL_PX = 132;
const FAST_PX_PER_MS = 0.75;
const SETTLE_MS = 300;

function elasticPull(distance: number) {
  if (distance <= MAX_PULL_PX) return distance;
  return MAX_PULL_PX + (distance - MAX_PULL_PX) * 0.18;
}

export function usePullToRefresh({
  enabled,
  canStart,
  onRefresh,
}: {
  enabled: boolean;
  canStart: () => boolean;
  onRefresh: () => Promise<void> | void;
}) {
  const pullRef = useRef<PullState | null>(null);
  const timerRef = useRef<number | null>(null);
  const velocityRef = useRef(0);
  const refreshRef = useRef(onRefresh);
  const canStartRef = useRef(canStart);
  const [phase, setPhase] = useState<Phase>("idle");
  const [offset, setOffset] = useState(0);

  refreshRef.current = onRefresh;
  canStartRef.current = canStart;

  const clearTimer = useCallback(() => {
    if (timerRef.current !== null) {
      window.clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  }, []);

  const settle = useCallback(() => {
    clearTimer();
    pullRef.current = null;
    setPhase("settling");
    setOffset(0);
    timerRef.current = window.setTimeout(() => {
      setPhase("idle");
      timerRef.current = null;
    }, SETTLE_MS + 40);
  }, [clearTimer]);

  const startRefresh = useCallback(async () => {
    clearTimer();
    pullRef.current = null;
    setPhase("refreshing");
    setOffset(HOLD_PX);
    try {
      await refreshRef.current();
    } finally {
      settle();
    }
  }, [clearTimer, settle]);

  const beginPull = useCallback((x: number, y: number) => {
    if (!enabled || phase === "refreshing" || !canStartRef.current()) return;
    clearTimer();
    velocityRef.current = 0;
    pullRef.current = {
      startX: x,
      startY: y,
      lastY: y,
      lastAt: performance.now(),
      intent: "pending",
    };
  }, [clearTimer, enabled, phase]);

  const movePull = useCallback((x: number, y: number) => {
    const pull = pullRef.current;
    if (!enabled || !pull || phase === "refreshing") return false;

    const now = performance.now();
    const dt = Math.max(1, now - pull.lastAt);
    velocityRef.current = (y - pull.lastY) / dt;
    pull.lastY = y;
    pull.lastAt = now;

    const dx = x - pull.startX;
    const dy = y - pull.startY;
    const absDx = Math.abs(dx);
    const absDy = Math.abs(dy);

    if (pull.intent === "pending") {
      if (absDx > INTENT_PX && absDx > absDy) {
        pull.intent = "horizontal";
      } else if (dy < -INTENT_PX && absDy > absDx) {
        pull.intent = "vertical-up";
      } else if (dy > INTENT_PX && absDy > absDx) {
        pull.intent = "pull";
      }
    }

    if (pull.intent !== "pull" || dy <= 0) return false;
    setPhase("pulling");
    setOffset(elasticPull(dy));
    return true;
  }, [enabled, phase]);

  const endPull = useCallback(() => {
    const pull = pullRef.current;
    if (!pull || pull.intent !== "pull") {
      pullRef.current = null;
      if (phase === "pulling") settle();
      return;
    }

    const distance = Math.max(0, pull.lastY - pull.startY);
    const shouldRefresh =
      distance >= ACTIVATE_PX ||
      (distance > HOLD_PX && velocityRef.current >= FAST_PX_PER_MS);

    if (shouldRefresh) {
      void startRefresh();
    } else {
      settle();
    }
  }, [phase, settle, startRefresh]);

  const onTouchStart = useCallback((event: TouchEvent<HTMLElement>) => {
    const touch = event.touches[0];
    if (!touch) return;
    beginPull(touch.clientX, touch.clientY);
  }, [beginPull]);

  const onTouchMove = useCallback((event: TouchEvent<HTMLElement>) => {
    const touch = event.touches[0];
    if (!touch) return;
    if (movePull(touch.clientX, touch.clientY)) event.preventDefault();
  }, [movePull]);

  useEffect(() => clearTimer, [clearTimer]);

  const progress = Math.max(0, Math.min(1, offset / ACTIVATE_PX));
  const activated = offset >= ACTIVATE_PX || phase === "refreshing";
  const contentStyle: CSSProperties = {
    transform: `translate3d(0, ${offset}px, 0)`,
    transition: phase === "pulling" ? "none" : `transform ${SETTLE_MS}ms cubic-bezier(0.22, 1, 0.36, 1)`,
    willChange: enabled ? "transform" : undefined,
  };

  const indicator = enabled && phase !== "idle" ? (
    <div
      className="pointer-events-none absolute left-0 right-0 top-0 z-20 flex justify-center"
      style={{
        transform: `translate3d(0, ${Math.max(8, Math.min(offset - 34, HOLD_PX))}px, 0)`,
        opacity: phase === "settling" ? Math.min(1, progress) : Math.max(0.35, progress),
        transition: phase === "pulling" ? "none" : `transform ${SETTLE_MS}ms cubic-bezier(0.22, 1, 0.36, 1), opacity ${SETTLE_MS}ms ease`,
      }}
      aria-hidden="true"
    >
      <div
        className="rounded-full border border-white/10 bg-bg-secondary/95 text-accent shadow-lg backdrop-blur-xl flex items-center justify-center"
        style={{ width: 34, height: 34 }}
      >
        <span
          className={phase === "refreshing" ? "smooth-spin" : undefined}
          style={{
            width: 18,
            height: 18,
            display: "inline-flex",
            transform: phase === "refreshing" ? undefined : `rotate(${progress * 240}deg)`,
            transition: phase === "pulling" ? "none" : "transform 180ms linear",
          }}
        >
          <svg
            width="18"
            height="18"
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
            style={{ display: "block" }}
          >
            <path d="M21 12a9 9 0 1 1-2.64-6.36" />
            <path d="M21 3v6h-6" />
          </svg>
        </span>
      </div>
    </div>
  ) : null;

  return {
    pullToRefreshHandlers: {
      onTouchStart,
      onTouchMove,
      onTouchEnd: endPull,
      onTouchCancel: endPull,
    },
    beginPull,
    movePull,
    endPull,
    pullToRefreshContentStyle: contentStyle,
    pullToRefreshIndicator: indicator as ReactNode,
    isPullRefreshing: phase === "refreshing",
    isPullActivated: activated,
  };
}
