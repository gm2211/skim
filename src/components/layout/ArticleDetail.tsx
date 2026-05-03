import { useEffect, useState, useCallback, useRef, useLayoutEffect } from "react";
import { createPortal } from "react-dom";
import { useArticle, useMarkRead, useToggleStar, useToggleRead } from "../../hooks/useArticles";
import { useSummarizeArticle } from "../../hooks/useAi";
import { useSettings } from "../../hooks/useSettings";
import { useUiStore } from "../../stores/uiStore";
import { fetchFullArticle, cancelSummarize } from "../../services/commands";
import { ChatDrawer } from "../chat/ChatPanel";
import { useReadingTimeTracker } from "../../hooks/useLearning";
import { openUrl } from "@tauri-apps/plugin-opener";
import { NumberInput } from "../ui/NumberInput";
import { AIDisclaimer } from "../common/AIDisclaimer";
import { usePullToRefresh } from "../../hooks/usePullToRefresh";

type ViewMode = "reader" | "web";
type SwipeTarget = "web" | "reader" | "list";
type SwipeTransition = "none" | "slide" | "bounce";
type ArticleSwipe = {
  id: number;
  iframeGestureId: number | null;
  startX: number;
  startY: number;
  lastX: number;
  lastAt: number;
  velocityX: number;
  intent: "pending" | "horizontal" | "vertical";
  startedIn: ViewMode;
  target: SwipeTarget | null;
};

type FetchedArticleContent = {
  html: string;
  raw_html: string;
};

const SWIPE_INTENT_PX = 10;
const SWIPE_VERTICAL_CANCEL_PX = 40;
const SWIPE_COMMIT_MAX_PX = 96;
const SWIPE_COMMIT_RATIO = 0.24;
const SWIPE_FAST_PX_PER_MS = 0.44;
const SWIPE_FAST_MIN_PX = 24;
const SLIDE_MS = 390;
const BOUNCE_MS = 280;
const SWIPE_STALE_MS = 900;
const PHONE_SLIDE_EASING = "cubic-bezier(0.16, 1, 0.3, 1)";
const PHONE_SETTLE_EASING = "cubic-bezier(0.2, 0.9, 0.2, 1)";

const EMBEDDED_WEB_VIEW_CSS = `
html,body{width:100%!important;max-width:100%!important;overflow-x:hidden!important;overscroll-behavior-x:none!important;touch-action:pan-y}
*,*::before,*::after{box-sizing:border-box!important;max-width:100%!important}
img,video,iframe,embed,object,canvas,svg{max-width:100%!important;height:auto!important}
pre,code{white-space:pre-wrap!important;overflow-wrap:anywhere!important;overflow-x:hidden!important}
table{display:block!important;width:100%!important;table-layout:fixed!important;overflow-x:hidden!important}
th,td,a,p,li,span,div{overflow-wrap:anywhere!important}
*::-webkit-scrollbar{width:6px!important}
*::-webkit-scrollbar-track{background:transparent!important}
*::-webkit-scrollbar-thumb{background:rgba(127,127,127,0.35)!important;border-radius:3px!important}
*::-webkit-scrollbar-thumb:hover{background:rgba(127,127,127,0.55)!important}
html,body{scrollbar-color:rgba(127,127,127,0.35) transparent!important;scrollbar-width:thin!important}
`;

const EMBEDDED_WEB_VIEW_SCRIPT = `
<script>
(() => {
  let gestureId = 0;
  let startX = 0;
  let startY = 0;
  let horizontal = false;
  let vertical = false;
  let active = false;
  const postSwipe = (phase, touch) => {
    if (!touch) return;
    window.parent.postMessage({
      type: "skim-article-swipe",
      gestureId,
      phase,
      x: touch.clientX,
      y: touch.clientY
    }, "*");
  };
  const postPull = (phase, touch) => {
    if (!touch) return;
    window.parent.postMessage({
      type: "skim-article-pull-refresh",
      gestureId,
      phase,
      x: touch.clientX,
      y: touch.clientY
    }, "*");
  };
  const scrollTop = () =>
    window.scrollY ||
    document.documentElement.scrollTop ||
    document.body.scrollTop ||
    0;
  let pullCandidate = false;
  let pulling = false;
  window.addEventListener("touchstart", (event) => {
    const touch = event.touches[0];
    if (!touch) return;
    startX = touch.clientX;
    startY = touch.clientY;
    horizontal = false;
    vertical = false;
    active = true;
    pullCandidate = scrollTop() <= 0;
    pulling = false;
    gestureId += 1;
    postSwipe("start", touch);
    if (pullCandidate) postPull("start", touch);
  }, { passive: true, capture: true });
  window.addEventListener("touchmove", (event) => {
    if (!active) return;
    const touch = event.touches[0];
    if (!touch) return;
    const dx = touch.clientX - startX;
    const absDx = Math.abs(dx);
    const signedDy = touch.clientY - startY;
    const dy = Math.abs(signedDy);
    if (!horizontal && !vertical) {
      if (signedDy < -${SWIPE_VERTICAL_CANCEL_PX} && dy > absDx) {
        vertical = true;
      } else if (absDx > ${SWIPE_INTENT_PX} && absDx > dy) {
        horizontal = true;
      }
    }
    if (pullCandidate && !horizontal && !vertical && signedDy > ${SWIPE_INTENT_PX} && signedDy > absDx && scrollTop() <= 0) {
      pulling = true;
    }
    if (pulling) {
      event.preventDefault();
      postPull("move", touch);
      return;
    }
    if (!horizontal) return;
    event.preventDefault();
    postSwipe("move", touch);
  }, { passive: false, capture: true });
  const finish = (phase, event) => {
    if (!active) return;
    active = false;
    postSwipe(phase, event.changedTouches[0]);
    if (pullCandidate || pulling) postPull(phase, event.changedTouches[0]);
    pullCandidate = false;
    pulling = false;
  };
  window.addEventListener("touchend", (event) => finish("end", event), { passive: true, capture: true });
  window.addEventListener("touchcancel", (event) => finish("cancel", event), { passive: true, capture: true });
  window.addEventListener("blur", () => {
    if (!active) return;
    active = false;
    window.parent.postMessage({
      type: "skim-article-swipe",
      gestureId,
      phase: "cancel",
      x: startX,
      y: startY
    }, "*");
    if (pullCandidate || pulling) {
      window.parent.postMessage({
        type: "skim-article-pull-refresh",
        gestureId,
        phase: "cancel",
        x: startX,
        y: startY
      }, "*");
    }
    pullCandidate = false;
    pulling = false;
  });
})();
</script>
`;

function buildEmbeddedWebSrcDoc(html: string): string {
  const injection = `<style>${EMBEDDED_WEB_VIEW_CSS}</style>${EMBEDDED_WEB_VIEW_SCRIPT}`;
  if (/<head[^>]*>/i.test(html)) {
    return html.replace(/(<head[^>]*>)/i, `$1${injection}`);
  }
  if (/<html[^>]*>/i.test(html)) {
    return html.replace(/(<html[^>]*>)/i, `$1<head>${injection}</head>`);
  }
  return `${injection}${html}`;
}

function formatDate(timestamp: number | null): string {
  if (!timestamp) return "";
  const date = new Date(timestamp * 1000);
  return date.toLocaleDateString("en-US", {
    weekday: "short",
    month: "short",
    day: "numeric",
    year: "numeric",
    hour: "numeric",
    minute: "2-digit",
  });
}

function stripRssJunk(html: string): string {
  const div = document.createElement("div");
  div.innerHTML = html;
  div.querySelectorAll("a").forEach((a) => {
    const text = a.textContent?.toLowerCase().trim() ?? "";
    if (
      text.includes("read full") ||
      text.includes("read more") ||
      text.includes("continue reading") ||
      text.includes("skip to") ||
      text.includes("full article") ||
      text === "comments"
    ) {
      a.remove();
    }
  });
  return div.innerHTML;
}

function stripFullArticleJunk(html: string): string {
  const div = document.createElement("div");
  div.innerHTML = html;

  // Remove links with junk text
  div.querySelectorAll("a").forEach((a) => {
    const text = a.textContent?.toLowerCase().trim() ?? "";
    if (
      text.includes("skip to") ||
      text.includes("learn more") ||
      text.includes("subscribe") ||
      text.includes("sign in") ||
      text.includes("sign up") ||
      text.includes("log in")
    ) {
      a.remove();
    }
  });

  // Remove form/interactive elements
  div.querySelectorAll("select, label, fieldset, legend, input, textarea").forEach((el) => el.remove());

  // Remove elements whose text is pure site UI
  const walkAndRemove = (root: Element) => {
    const toRemove: Element[] = [];
    root.querySelectorAll("div, span, section, aside, figure").forEach((el) => {
      const text = el.textContent?.trim() ?? "";
      if (text.length < 60 && /^(STORY TEXT|SIZE|WIDTH|LINKS|SUBSCRIBERS ONLY|MINIMIZE TO NAV|TEXT SETTINGS|LEARN MORE)/i.test(text)) {
        toRemove.push(el);
      }
    });
    toRemove.forEach((el) => el.remove());
  };
  walkAndRemove(div);

  // Remove elements by common junk selectors
  const junkSelectors = [
    "[class*='skip']", "[class*='paywall']", "[class*='subscribe']",
    "[class*='newsletter']", "[class*='toolbar']", "[class*='topbar']",
    "[class*='ad-slot']", "[class*='advert']", "[class*='popup']",
    "[class*='modal']", "[class*='overlay']", "[class*='cookie']",
    "[class*='consent']", "[class*='social']", "[class*='share']",
    "[class*='related']", "[class*='comment']", "[class*='story-settings']",
    "[class*='minimize']", "[class*='site-header']", "[class*='site-nav']",
    "[class*='settings']", "[class*='font-size']", "[class*='reading']",
    "[class*='story-text']", "[class*='story_text']",
    "[role='banner']", "[role='navigation']", "[role='complementary']",
    "[aria-hidden='true']",
  ];
  junkSelectors.forEach((sel) => {
    try {
      div.querySelectorAll(sel).forEach((el) => el.remove());
    } catch {
      // invalid selector, skip
    }
  });

  return div.innerHTML;
}

function htmlToPlainText(html: string): string {
  const div = document.createElement("div");
  div.innerHTML = html;
  div.querySelectorAll("script, style, noscript, svg").forEach((el) => el.remove());
  return (div.textContent ?? "").replace(/\s+/g, " ").trim();
}

function looksLikeBlockedHtml(html: string): boolean {
  const plain = htmlToPlainText(html);
  return (
    /recaptcha (service|challenge)|captcha.{0,80}(challenge|required|verification)|verification required|access denied|are you a human|cloudflare|just a moment|please enable (javascript|js)|enable javascript/i.test(plain)
  );
}

function prepareFetchedArticle(result: FetchedArticleContent): {
  fullContent: string | null;
  rawHtml: string | null;
  error: string | null;
} {
  const stripped = stripFullArticleJunk(result.html);
  const plain = htmlToPlainText(stripped);
  const blocked = looksLikeBlockedHtml(stripped) || looksLikeBlockedHtml(result.raw_html);

  if (blocked) {
    return {
      fullContent: null,
      rawHtml: null,
      error: "Reader couldn't extract this page (likely paywall, JS-required, or anti-bot challenge). Showing RSS preview.",
    };
  }

  if (plain.length < 240) {
    return {
      fullContent: null,
      rawHtml: result.raw_html,
      error: "Reader couldn't extract this page (likely paywall, JS-required, or anti-bot challenge). Showing RSS preview.",
    };
  }

  return {
    fullContent: stripped,
    rawHtml: result.raw_html,
    error: null,
  };
}

export function ArticleDetail() {
  const { selectedArticleId, closeArticleDetail, listCollapsed, sidebarCollapsed, sidebarView, isPhone, phoneBack } = useUiStore();
  const { data: article, refetch: refetchArticle } = useArticle(selectedArticleId);
  const markRead = useMarkRead();
  const toggleStar = useToggleStar();
  const toggleRead = useToggleRead();
  const summarize = useSummarizeArticle();
  const { data: settings } = useSettings();
  // Don't count engagement when browsing the Recent tab — that view already
  // reflects past engagement and would otherwise self-reinforce.
  useReadingTimeTracker(selectedArticleId, sidebarView.type === "recent");
  const [showSummarizeMenu, setShowSummarizeMenu] = useState(false);
  const [perArticleLength, setPerArticleLength] = useState<string | undefined>();
  const [perArticleTone, setPerArticleTone] = useState<string | undefined>();
  const [perArticlePrompt, setPerArticlePrompt] = useState<string | undefined>();
  const [perArticleWordCount, setPerArticleWordCount] = useState<number | undefined>();
  const sumMenuRef = useRef<HTMLDivElement>(null);
  const longPressTimer = useRef<number | null>(null);
  const longPressFired = useRef(false);
  const longPressStart = useRef<{ x: number; y: number } | null>(null);
  const articleFrameRef = useRef<HTMLDivElement>(null);
  const readerScrollRef = useRef<HTMLDivElement>(null);
  const articleSwipeRef = useRef<ArticleSwipe | null>(null);
  const articleSwipeSeqRef = useRef(0);
  const articleSwipeWatchdogRef = useRef<number | null>(null);
  const modeTransitionTimerRef = useRef<number | null>(null);
  const dismissTransitionTimerRef = useRef<number | null>(null);
  const dismissToListRef = useRef(false);
  const [fullContent, setFullContent] = useState<string | null>(null);
  const [rawHtml, setRawHtml] = useState<string | null>(null);
  const [loadingFull, setLoadingFull] = useState(false);
  const [fullError, setFullError] = useState<string | null>(null);
  const iframeRef = useRef<HTMLIFrameElement>(null);
  const fullFetchSeqRef = useRef(0);
  const [viewMode, setViewMode] = useState<ViewMode>("reader");
  const [articleFrameWidth, setArticleFrameWidth] = useState(0);
  const [modeDragOffset, setModeDragOffset] = useState(0);
  const [dismissOffset, setDismissOffset] = useState(0);
  const [modeTransition, setModeTransition] = useState<SwipeTransition>("none");
  const [dismissTransition, setDismissTransition] = useState<SwipeTransition>("none");
  const effectiveArticleFrameWidth = Math.max(
    1,
    articleFrameWidth || (typeof window !== "undefined" ? window.innerWidth : 1)
  );

  useLayoutEffect(() => {
    const frame = articleFrameRef.current;
    if (!frame) return;
    const updateWidth = () => setArticleFrameWidth(frame.clientWidth);
    updateWidth();
    const observer = new ResizeObserver(updateWidth);
    observer.observe(frame);
    return () => observer.disconnect();
  }, [article?.id, selectedArticleId]);

  useEffect(() => {
    return () => {
      if (articleSwipeWatchdogRef.current) window.clearTimeout(articleSwipeWatchdogRef.current);
      if (modeTransitionTimerRef.current) window.clearTimeout(modeTransitionTimerRef.current);
      if (dismissTransitionTimerRef.current) window.clearTimeout(dismissTransitionTimerRef.current);
    };
  }, []);

  useEffect(() => {
    if (articleSwipeRef.current) return;
    if (modeTransition === "none" && modeDragOffset !== 0) setModeDragOffset(0);
    if (dismissTransition === "none" && dismissOffset !== 0) setDismissOffset(0);
  }, [dismissOffset, dismissTransition, modeDragOffset, modeTransition]);

  // Reset state when article changes — cancel any in-flight summary
  useEffect(() => {
    fullFetchSeqRef.current += 1;
    cancelSummarize().catch(() => {});
    articleSwipeRef.current = null;
    dismissToListRef.current = false;
    if (articleSwipeWatchdogRef.current) window.clearTimeout(articleSwipeWatchdogRef.current);
    if (modeTransitionTimerRef.current) window.clearTimeout(modeTransitionTimerRef.current);
    if (dismissTransitionTimerRef.current) window.clearTimeout(dismissTransitionTimerRef.current);
    setFullContent(null);
    setRawHtml(null);
    setLoadingFull(false);
    setFullError(null);
    setViewMode("reader");
    setModeDragOffset(0);
    setDismissOffset(0);
    setModeTransition("none");
    setDismissTransition("none");
    summarize.reset();
    setShowSummarizeMenu(false);
    setPerArticleLength(undefined);
    setPerArticleTone(undefined);
    setPerArticlePrompt(undefined);
    setPerArticleWordCount(undefined);
  }, [selectedArticleId]);

  // Auto-fetch full article on open so Reader has content immediately.
  // Inlined (instead of calling fetchFull) so the fetch isn't gated on the
  // previous article's fullContent value during the reset → fetch transition.
  useEffect(() => {
    const articleId = article?.id;
    const url = article?.url;
    if (!articleId || !url) return;
    let cancelled = false;
    const seq = ++fullFetchSeqRef.current;
    setLoadingFull(true);
    setFullError(null);
    (async () => {
      try {
        const result = await fetchFullArticle(url);
        if (cancelled || seq !== fullFetchSeqRef.current) return;
        const prepared = prepareFetchedArticle(result);
        setRawHtml(prepared.rawHtml);
        setFullContent(prepared.fullContent);
        setFullError(prepared.error);
      } catch (e) {
        if (!cancelled && seq === fullFetchSeqRef.current) setFullError(String(e));
      } finally {
        if (!cancelled && seq === fullFetchSeqRef.current) setLoadingFull(false);
      }
    })();
    return () => { cancelled = true; };
  }, [selectedArticleId, article?.id, article?.url]);

  // Close summarize menu on click outside
  useEffect(() => {
    if (!showSummarizeMenu) return;
    const handler = (e: MouseEvent) => {
      if (sumMenuRef.current && !sumMenuRef.current.contains(e.target as Node)) {
        setShowSummarizeMenu(false);
      }
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, [showSummarizeMenu]);

  const doSummarize = useCallback(
    (force = false) => {
      if (!article) return;
      if (
        !settings ||
        settings.ai.provider === "none" ||
        (settings.ai.provider === "local" && !settings.ai.local_model_path)
      ) {
        useUiStore.getState().setShowSettings(true);
        return;
      }
      // Force re-summarize if any per-article override is set
      const hasOverrides = perArticleLength || perArticleTone || perArticlePrompt;
      summarize.mutate({
        articleId: article.id,
        force: force || !!hasOverrides,
        summaryLength: perArticleLength,
        summaryTone: perArticleTone,
        summaryCustomPrompt: perArticlePrompt,
      });
      setShowSummarizeMenu(false);
    },
    [article, settings, summarize, perArticleLength, perArticleTone]
  );

  // Mark as read when opened
  useEffect(() => {
    if (article && !article.is_read) {
      markRead.mutate([article.id]);
    }
  }, [article?.id]);

  const fetchFull = useCallback(async (force = false) => {
    const articleId = article?.id;
    const url = article?.url;
    if (!articleId || !url || (!force && rawHtml)) return;
    const seq = ++fullFetchSeqRef.current;
    setLoadingFull(true);
    setFullError(null);
    try {
      const result = await fetchFullArticle(url);
      if (seq !== fullFetchSeqRef.current || useUiStore.getState().selectedArticleId !== articleId) return;
      const prepared = prepareFetchedArticle(result);
      setFullContent(prepared.fullContent);
      setRawHtml(prepared.rawHtml);
      setFullError(prepared.error);
    } catch (e) {
      if (seq === fullFetchSeqRef.current) setFullError(String(e));
    } finally {
      if (seq === fullFetchSeqRef.current) setLoadingFull(false);
    }
  }, [article?.id, article?.url, rawHtml]);

  const refreshCurrentArticle = useCallback(async () => {
    await refetchArticle();
    await fetchFull(true);
  }, [fetchFull, refetchArticle]);

  const readerRefresh = usePullToRefresh({
    enabled: isPhone,
    canStart: () =>
      viewMode === "reader" &&
      (readerScrollRef.current?.scrollTop ?? 0) <= 0 &&
      !loadingFull,
    onRefresh: refreshCurrentArticle,
  });

  const {
    beginPull: beginWebPullRefresh,
    movePull: moveWebPullRefresh,
    endPull: endWebPullRefresh,
    pullToRefreshContentStyle: webPullToRefreshContentStyle,
    pullToRefreshIndicator: webPullToRefreshIndicator,
  } = usePullToRefresh({
    enabled: isPhone,
    canStart: () => viewMode === "web" && !loadingFull,
    onRefresh: refreshCurrentArticle,
  });

  const clearModeTransitionTimer = useCallback(() => {
    if (modeTransitionTimerRef.current) {
      window.clearTimeout(modeTransitionTimerRef.current);
      modeTransitionTimerRef.current = null;
    }
  }, []);

  const clearDismissTransitionTimer = useCallback(() => {
    if (dismissTransitionTimerRef.current) {
      window.clearTimeout(dismissTransitionTimerRef.current);
      dismissTransitionTimerRef.current = null;
    }
  }, []);

  const clearArticleSwipeWatchdog = useCallback(() => {
    if (articleSwipeWatchdogRef.current) {
      window.clearTimeout(articleSwipeWatchdogRef.current);
      articleSwipeWatchdogRef.current = null;
    }
  }, []);

  const finishModeTransition = useCallback(() => {
    clearModeTransitionTimer();
    clearArticleSwipeWatchdog();
    articleSwipeRef.current = null;
    setModeTransition("none");
    setModeDragOffset(0);
  }, [clearArticleSwipeWatchdog, clearModeTransitionTimer]);

  const finishDismissTransition = useCallback(() => {
    clearDismissTransitionTimer();
    clearArticleSwipeWatchdog();
    const shouldGoBack = dismissToListRef.current;
    dismissToListRef.current = false;
    articleSwipeRef.current = null;
    setDismissTransition("none");
    setDismissOffset(0);
    if (shouldGoBack) {
      window.dispatchEvent(new CustomEvent("skim-suppress-next-phone-pane-transition"));
      phoneBack();
    }
  }, [clearArticleSwipeWatchdog, clearDismissTransitionTimer, phoneBack]);

  const cancelActiveArticleSwipe = useCallback((animate = true) => {
    const swipe = articleSwipeRef.current;
    articleSwipeRef.current = null;
    clearArticleSwipeWatchdog();

    if (swipe?.target === "list") {
      setDismissOffset(0);
      if (animate) {
        setDismissTransition("bounce");
        clearDismissTransitionTimer();
        dismissTransitionTimerRef.current = window.setTimeout(finishDismissTransition, BOUNCE_MS + 80);
      } else {
        finishDismissTransition();
      }
      return;
    }

    setModeDragOffset(0);
    if (animate) {
      setModeTransition("bounce");
      clearModeTransitionTimer();
      modeTransitionTimerRef.current = window.setTimeout(finishModeTransition, BOUNCE_MS + 80);
    } else {
      finishModeTransition();
    }
  }, [
    clearArticleSwipeWatchdog,
    clearDismissTransitionTimer,
    clearModeTransitionTimer,
    finishDismissTransition,
    finishModeTransition,
  ]);

  const armArticleSwipeWatchdog = useCallback((swipeId: number) => {
    clearArticleSwipeWatchdog();
    articleSwipeWatchdogRef.current = window.setTimeout(() => {
      if (articleSwipeRef.current?.id !== swipeId) return;
      cancelActiveArticleSwipe(true);
    }, SWIPE_STALE_MS);
  }, [cancelActiveArticleSwipe, clearArticleSwipeWatchdog]);

  useEffect(() => {
    if (!isPhone) return;
    if (modeDragOffset === 0 && dismissOffset === 0) return;
    const id = window.setTimeout(() => {
      const swipe = articleSwipeRef.current;
      if (!swipe) return;
      if (performance.now() - swipe.lastAt >= SWIPE_STALE_MS) {
        cancelActiveArticleSwipe(true);
      }
    }, SWIPE_STALE_MS + 40);
    return () => window.clearTimeout(id);
  }, [cancelActiveArticleSwipe, dismissOffset, isPhone, modeDragOffset]);

  const settleMode = useCallback((transition: Exclude<SwipeTransition, "none">) => {
    clearModeTransitionTimer();
    setModeTransition(transition);
    modeTransitionTimerRef.current = window.setTimeout(
      finishModeTransition,
      (transition === "bounce" ? BOUNCE_MS : SLIDE_MS) + 80
    );
  }, [clearModeTransitionTimer, finishModeTransition]);

  const settleDismiss = useCallback((transition: Exclude<SwipeTransition, "none">, toList = false) => {
    clearDismissTransitionTimer();
    dismissToListRef.current = toList;
    setDismissTransition(transition);
    dismissTransitionTimerRef.current = window.setTimeout(
      finishDismissTransition,
      (transition === "bounce" ? BOUNCE_MS : SLIDE_MS) + 80
    );
  }, [clearDismissTransitionTimer, finishDismissTransition]);

  const animateToMode = useCallback((mode: ViewMode) => {
    if (mode === "web") void fetchFull();
    clearModeTransitionTimer();
    setDismissOffset(0);
    if (viewMode !== mode && isPhone) settleMode("slide");
    setModeDragOffset(0);
    setViewMode(mode);
  }, [clearModeTransitionTimer, fetchFull, isPhone, settleMode, viewMode]);

  const handleReader = useCallback(async () => {
    animateToMode("reader");
  }, [animateToMode]);

  const handleWebView = useCallback(async () => {
    animateToMode(viewMode === "web" ? "reader" : "web");
  }, [animateToMode, viewMode]);

  const resolveSwipeTarget = useCallback((dx: number, startedIn: ViewMode): SwipeTarget | null => {
    if (dx < 0 && startedIn === "reader" && article?.url) return "web";
    if (dx > 0 && startedIn === "web") return "reader";
    if (dx > 0 && startedIn === "reader") return "list";
    return null;
  }, [article?.url]);

  const constrainedSwipeOffset = useCallback((dx: number, target: SwipeTarget | null): number => {
    if (!target) {
      return Math.sign(dx) * Math.min(Math.abs(dx) * 0.22, 46);
    }

    const direction = target === "web" ? -1 : 1;
    const distance = Math.max(0, direction * dx);
    if (distance <= effectiveArticleFrameWidth) return direction * distance;
    return direction * (effectiveArticleFrameWidth + (distance - effectiveArticleFrameWidth) * 0.16);
  }, [effectiveArticleFrameWidth]);

  const beginArticleSwipe = useCallback((x: number, y: number, iframeGestureId: number | null = null) => {
    if (!isPhone) return;
    clearModeTransitionTimer();
    clearDismissTransitionTimer();
    clearArticleSwipeWatchdog();
    dismissToListRef.current = false;
    setModeTransition("none");
    setDismissTransition("none");
    const id = articleSwipeSeqRef.current + 1;
    articleSwipeSeqRef.current = id;
    articleSwipeRef.current = {
      id,
      iframeGestureId,
      startX: x,
      startY: y,
      lastX: x,
      lastAt: performance.now(),
      velocityX: 0,
      intent: "pending",
      startedIn: viewMode,
      target: null,
    };
  }, [clearArticleSwipeWatchdog, clearDismissTransitionTimer, clearModeTransitionTimer, isPhone, viewMode]);

  const moveArticleSwipe = useCallback((x: number, y: number, iframeGestureId: number | null = null): boolean => {
    const swipe = articleSwipeRef.current;
    if (!isPhone || !swipe) return false;
    if (swipe.iframeGestureId !== iframeGestureId) return false;

    const now = performance.now();
    const dt = Math.max(1, now - swipe.lastAt);
    swipe.velocityX = (x - swipe.lastX) / dt;
    swipe.lastX = x;
    swipe.lastAt = now;

    const dx = x - swipe.startX;
    const absDx = Math.abs(dx);
    const dy = Math.abs(y - swipe.startY);

    if (swipe.intent === "pending") {
      if (dy > SWIPE_VERTICAL_CANCEL_PX && dy > absDx) {
        swipe.intent = "vertical";
        setModeDragOffset(0);
        setDismissOffset(0);
        return false;
      }
      if (absDx <= SWIPE_INTENT_PX || absDx <= dy) return false;
      swipe.intent = "horizontal";
    }

    if (swipe.intent !== "horizontal") return false;
    if (!swipe.target) swipe.target = resolveSwipeTarget(dx, swipe.startedIn);

    const visualOffset = constrainedSwipeOffset(dx, swipe.target);
    if (swipe.target === "list") {
      setModeDragOffset(0);
      setDismissOffset(Math.max(0, visualOffset));
    } else {
      setDismissOffset(0);
      setModeDragOffset(visualOffset);
    }
    armArticleSwipeWatchdog(swipe.id);
    return true;
  }, [armArticleSwipeWatchdog, constrainedSwipeOffset, isPhone, resolveSwipeTarget]);

  const endArticleSwipe = useCallback((iframeGestureId?: number | null) => {
    const swipe = articleSwipeRef.current;
    if (iframeGestureId !== undefined && swipe?.iframeGestureId !== iframeGestureId) return;
    articleSwipeRef.current = null;
    clearArticleSwipeWatchdog();
    if (!swipe || swipe.intent !== "horizontal") return;

    const dx = swipe.lastX - swipe.startX;
    const target = swipe.target ?? resolveSwipeTarget(dx, swipe.startedIn);
    const direction = target === "web" ? -1 : 1;
    const distance = target ? Math.max(0, direction * dx) : 0;
    const velocity = target ? direction * swipe.velocityX : 0;
    const threshold = Math.min(SWIPE_COMMIT_MAX_PX, effectiveArticleFrameWidth * SWIPE_COMMIT_RATIO);
    const shouldCommit = Boolean(
      target &&
      (distance >= threshold || (distance >= SWIPE_FAST_MIN_PX && velocity >= SWIPE_FAST_PX_PER_MS))
    );

    if (shouldCommit && target === "web") {
      animateToMode("web");
      return;
    }
    if (shouldCommit && target === "reader") {
      animateToMode("reader");
      return;
    }
    if (shouldCommit && target === "list") {
      setModeDragOffset(0);
      setDismissOffset(effectiveArticleFrameWidth);
      settleDismiss("slide", true);
      return;
    }

    if (target === "list") {
      setDismissOffset(0);
      settleDismiss("bounce");
    } else {
      setModeDragOffset(0);
      settleMode("bounce");
    }
  }, [
    animateToMode,
    clearArticleSwipeWatchdog,
    effectiveArticleFrameWidth,
    resolveSwipeTarget,
    settleDismiss,
    settleMode,
  ]);

  const handleArticleTouchStart = useCallback((e: React.TouchEvent<HTMLDivElement>) => {
    const t = e.touches[0];
    if (!t) return;
    beginArticleSwipe(t.clientX, t.clientY);
  }, [beginArticleSwipe]);

  const handleArticleTouchMove = useCallback((e: React.TouchEvent<HTMLDivElement>) => {
    const t = e.touches[0];
    if (!t) return;
    if (moveArticleSwipe(t.clientX, t.clientY)) e.preventDefault();
  }, [moveArticleSwipe]);

  const handleArticleTouchEnd = useCallback(() => {
    endArticleSwipe(undefined);
  }, [endArticleSwipe]);

  useEffect(() => {
    if (!isPhone) return;
    const finish = (event: TouchEvent) => {
      if (event.touches.length === 0) endArticleSwipe(undefined);
    };
    const cancel = () => cancelActiveArticleSwipe(true);
    const cancelIfHidden = () => {
      if (document.hidden) cancelActiveArticleSwipe(true);
    };
    window.addEventListener("touchend", finish, { capture: true });
    window.addEventListener("touchcancel", finish, { capture: true });
    window.addEventListener("blur", cancel);
    window.addEventListener("pagehide", cancel);
    document.addEventListener("visibilitychange", cancelIfHidden);
    return () => {
      window.removeEventListener("touchend", finish, { capture: true });
      window.removeEventListener("touchcancel", finish, { capture: true });
      window.removeEventListener("blur", cancel);
      window.removeEventListener("pagehide", cancel);
      document.removeEventListener("visibilitychange", cancelIfHidden);
    };
  }, [cancelActiveArticleSwipe, endArticleSwipe, isPhone]);

  useEffect(() => {
    if (!isPhone) return;
    const handleMessage = (event: MessageEvent) => {
      if (event.source !== iframeRef.current?.contentWindow) return;
      const data = event.data as {
        type?: string;
        phase?: string;
        gestureId?: number;
        x?: number;
        y?: number;
      };
      if (typeof data.gestureId !== "number" || typeof data.x !== "number" || typeof data.y !== "number") {
        return;
      }
      if (data.type === "skim-article-pull-refresh") {
        if (data.phase === "start") {
          beginWebPullRefresh(data.x, data.y);
        } else if (data.phase === "move") {
          moveWebPullRefresh(data.x, data.y);
        } else if (data.phase === "end" || data.phase === "cancel") {
          endWebPullRefresh();
        }
        return;
      }
      if (data.type !== "skim-article-swipe") return;
      if (data.phase === "start") {
        beginArticleSwipe(data.x, data.y, data.gestureId);
      } else if (data.phase === "move") {
        moveArticleSwipe(data.x, data.y, data.gestureId);
      } else if (data.phase === "end" || data.phase === "cancel") {
        endArticleSwipe(data.gestureId);
      }
    };
    window.addEventListener("message", handleMessage);
    return () => window.removeEventListener("message", handleMessage);
  }, [
    beginArticleSwipe,
    beginWebPullRefresh,
    endArticleSwipe,
    endWebPullRefresh,
    isPhone,
    moveArticleSwipe,
    moveWebPullRefresh,
  ]);

  // Arrow key navigation — toggle between reader and web views
  useEffect(() => {
    if (!article?.url) return;
    const handler = (e: KeyboardEvent) => {
      if (e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement) return;
      if (e.key === "ArrowRight") {
        e.preventDefault();
        animateToMode("web");
      } else if (e.key === "ArrowLeft") {
        e.preventDefault();
        animateToMode("reader");
      }
    };
    window.addEventListener("keydown", handler);
    return () => window.removeEventListener("keydown", handler);
  }, [animateToMode, article?.url]);

  if (!article) {
    return (
      <div
        className="flex-1 flex items-center justify-center bg-bg-primary/60 cursor-pointer"
        onClick={() => {
          const state = useUiStore.getState();
          if (state.listCollapsed) state.toggleList();
        }}
      >
        <span className="text-text-muted text-sm">Select an article to read</span>
      </div>
    );
  }

  let rssHtml: string | null = null;
  try {
    rssHtml = article.content_html ? stripRssJunk(article.content_html) : null;
  } catch (e) {
    console.error("Failed to strip RSS junk:", e);
    rssHtml = article.content_html;
  }

  const modeBtn = (mode: ViewMode, label: string, icon: React.ReactNode) => (
    <button
      onClick={mode === "reader" ? handleReader : handleWebView}
      disabled={loadingFull}
      className={`${isPhone ? "phone-icon-button" : "flex items-center gap-1.5 rounded-lg"} border transition-colors disabled:opacity-40 ${
        viewMode === mode
          ? "border-accent/30 text-accent bg-accent/10"
          : "border-white/12 text-text-secondary bg-white/[0.02] hover:text-text-primary hover:border-white/24"
      }`}
      style={{ padding: isPhone ? 0 : "6px 12px", fontSize: 12, justifyContent: "center" }}
      aria-label={label}
      title={label}
    >
      {icon}
      {!isPhone && label}
    </button>
  );

  const renderSummarizeMenuBody = () => (
    <>
      <div style={{ marginBottom: 8 }}>
        <label className="text-text-muted block" style={{ fontSize: 11, marginBottom: 4 }}>Length</label>
        <select
          value={perArticleLength ?? settings?.ai.summary_length ?? "short"}
          onChange={(e) => setPerArticleLength(e.target.value)}
          className="w-full border border-white/10 rounded-lg text-text-primary bg-white/5"
          style={{ padding: "4px 8px", fontSize: 12 }}
        >
          <option value="short">Short (~30 words)</option>
          <option value="medium">Medium (~150 words)</option>
          <option value="long">Long (~300 words)</option>
          <option value="custom">Custom...</option>
        </select>
        {(perArticleLength ?? settings?.ai.summary_length) === "custom" && (
          <NumberInput
            min={20}
            max={1000}
            placeholder="Word count"
            value={perArticleWordCount ?? settings?.ai.summary_custom_word_count ?? null}
            onChange={(n) => setPerArticleWordCount(n ?? undefined)}
            className="w-full border border-white/10 rounded-lg text-text-primary bg-white/5"
            style={{ padding: "4px 8px", fontSize: 12, marginTop: 4 }}
          />
        )}
      </div>
      <div style={{ marginBottom: 8 }}>
        <label className="text-text-muted block" style={{ fontSize: 11, marginBottom: 4 }}>Tone</label>
        <select
          value={perArticleTone ?? settings?.ai.summary_tone ?? "concise"}
          onChange={(e) => setPerArticleTone(e.target.value)}
          className="w-full border border-white/10 rounded-lg text-text-primary bg-white/5"
          style={{ padding: "4px 8px", fontSize: 12 }}
        >
          <option value="concise">Concise</option>
          <option value="detailed">Detailed</option>
          <option value="casual">Casual</option>
          <option value="technical">Technical</option>
        </select>
      </div>
      <div style={{ marginBottom: 10 }}>
        <label className="text-text-muted block" style={{ fontSize: 11, marginBottom: 4 }}>Custom prompt</label>
        <textarea
          value={perArticlePrompt ?? settings?.ai.summary_custom_prompt ?? ""}
          onChange={(e) => setPerArticlePrompt(e.target.value || undefined)}
          placeholder="e.g. Focus on financial implications..."
          className="w-full border border-white/10 rounded-lg text-text-primary bg-white/5 placeholder-text-muted"
          style={{ padding: "6px 8px", fontSize: 11, minHeight: 48, resize: "vertical" }}
          rows={2}
        />
      </div>
      <div className="flex gap-2">
        <button
          onClick={() => doSummarize(false)}
          className="flex-1 text-accent border border-accent/20 hover:bg-accent/10 rounded-lg transition-colors"
          style={{ padding: "5px 0", fontSize: 11 }}
        >
          Summarize
        </button>
        {summarize.data && (
          <button
            onClick={() => doSummarize(true)}
            className="flex-1 text-text-secondary border border-white/10 hover:bg-white/5 rounded-lg transition-colors"
            style={{ padding: "5px 0", fontSize: 11 }}
          >
            Re-summarize
          </button>
        )}
      </div>
    </>
  );

  const modeTrackX = (viewMode === "web" ? -effectiveArticleFrameWidth : 0) + modeDragOffset;
  const modeTransitionStyle =
    modeTransition === "none"
      ? "none"
      : modeTransition === "bounce"
        ? `transform ${BOUNCE_MS}ms ${PHONE_SETTLE_EASING}`
        : `transform ${SLIDE_MS}ms ${PHONE_SLIDE_EASING}`;
  const dismissTransitionStyle =
    dismissTransition === "none"
      ? "none"
      : dismissTransition === "bounce"
        ? `transform ${BOUNCE_MS}ms ${PHONE_SETTLE_EASING}`
        : `transform ${SLIDE_MS}ms ${PHONE_SLIDE_EASING}`;

  return (
    <div className="flex-1 flex flex-col h-full bg-bg-primary/60 overflow-hidden">
      {/* Toolbar */}
      <div
        className="flex items-center justify-between relative z-20 flex-shrink-0"
        style={{ height: isPhone ? 76 : 52, padding: isPhone ? "0 12px" : "0 24px", gap: isPhone ? 8 : undefined }}
      >
        {(isPhone || !(sidebarCollapsed && listCollapsed)) && (
          <button
            onClick={() => {
              if (isPhone) {
                phoneBack();
                return;
              }
              closeArticleDetail();
              const state = useUiStore.getState();
              if (state.listCollapsed) state.toggleList();
            }}
            className="tap-target text-text-muted hover:text-text-primary rounded-lg hover:bg-white/10 transition-colors"
            style={isPhone ? { minWidth: 56, minHeight: 62 } : undefined}
            title={isPhone ? "Back" : "Close"}
          >
            <svg width={isPhone ? 30 : 16} height={isPhone ? 30 : 16} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
              <path d="M19 12H5M12 19l-7-7 7-7" />
            </svg>
          </button>
        )}

        <div
          className="flex items-center gap-2 min-w-0"
          style={isPhone ? { gap: 8, flex: "1 1 auto", flexWrap: "nowrap" } : undefined}
        >
          {article.url && (
            <>
              {modeBtn("reader", "Reader",
                <svg width={isPhone ? 30 : 13} height={isPhone ? 30 : 13} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20" />
                  <path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z" />
                </svg>
              )}
              {modeBtn("web", "Web",
                <svg width={isPhone ? 30 : 13} height={isPhone ? 30 : 13} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <circle cx="12" cy="12" r="10" />
                  <line x1="2" y1="12" x2="22" y2="12" />
                  <path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z" />
                </svg>
              )}
            </>
          )}

          {!isPhone && <div className="w-px h-5 bg-white/10" />}

          <div className="relative" ref={sumMenuRef}>
            <div className="flex">
              <button
                onClick={() => {
                  if (longPressFired.current) { longPressFired.current = false; return; }
                  doSummarize(false);
                }}
                onPointerDown={isPhone ? (e) => {
                  if (e.pointerType !== "touch") return;
                  longPressFired.current = false;
                  longPressStart.current = { x: e.clientX, y: e.clientY };
                  if (longPressTimer.current) window.clearTimeout(longPressTimer.current);
                  longPressTimer.current = window.setTimeout(() => {
                    longPressFired.current = true;
                    setShowSummarizeMenu(true);
                    if (navigator.vibrate) navigator.vibrate(8);
                  }, 450);
                } : undefined}
                onPointerUp={isPhone ? () => {
                  if (longPressTimer.current) { window.clearTimeout(longPressTimer.current); longPressTimer.current = null; }
                  longPressStart.current = null;
                } : undefined}
                onPointerMove={isPhone ? (e) => {
                  if (!longPressStart.current || !longPressTimer.current) return;
                  const dx = e.clientX - longPressStart.current.x;
                  const dy = e.clientY - longPressStart.current.y;
                  if (Math.hypot(dx, dy) > 10) {
                    window.clearTimeout(longPressTimer.current);
                    longPressTimer.current = null;
                  }
                } : undefined}
                onPointerLeave={isPhone ? () => {
                  if (longPressTimer.current) { window.clearTimeout(longPressTimer.current); longPressTimer.current = null; }
                } : undefined}
                onContextMenu={isPhone ? (e) => e.preventDefault() : undefined}
                disabled={summarize.isPending}
                className={`${isPhone ? "phone-icon-button" : "rounded-l-lg border-r-0"} border border-white/10 bg-white/[0.02] text-text-secondary hover:text-text-primary hover:border-white/20 transition-colors disabled:opacity-40`}
                style={{ padding: isPhone ? 0 : "6px 12px", fontSize: 12, touchAction: "manipulation", userSelect: "none", WebkitUserSelect: "none", WebkitTouchCallout: "none" }}
                title={isPhone ? "Tap: summarize • Long press: options" : "Summarize"}
                aria-label="Summarize"
              >
                {summarize.isPending ? (
                  isPhone ? <span className="smooth-spin" style={{ width: 30, height: 30, display: "inline-flex" }}>
                    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                      <path d="M21 12a9 9 0 1 1-6.219-8.56" />
                    </svg>
                  </span> : "..."
                ) : (isPhone ? (
                  <svg width="30" height="30" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                    <path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z" />
                    <polyline points="14 2 14 8 20 8" />
                    <line x1="16" y1="13" x2="8" y2="13" />
                    <line x1="16" y1="17" x2="8" y2="17" />
                  </svg>
                ) : "Summarize")}
              </button>
              {!isPhone && (
                <button
                  onClick={() => setShowSummarizeMenu(!showSummarizeMenu)}
                  disabled={summarize.isPending}
                  className="rounded-r-lg border border-white/10 text-text-secondary hover:text-text-primary hover:border-white/20 transition-colors disabled:opacity-40 flex items-center justify-center"
                  style={{ padding: "6px 4px", fontSize: 12 }}
                  aria-label="Summary options"
                  title="Summary options"
                >
                  <svg width="10" height="10" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                    <path d="M6 9l6 6 6-6" />
                  </svg>
                </button>
              )}
            </div>

            {showSummarizeMenu && (
              isPhone ? createPortal(
                <div className="fixed inset-0 z-50" onClick={() => setShowSummarizeMenu(false)}>
                  <div
                    className="absolute left-1/2 -translate-x-1/2 border border-white/10 rounded-xl shadow-xl"
                    style={{ background: "rgba(22, 27, 34, 0.95)", backdropFilter: "blur(12px)", padding: "12px", width: "min(320px, calc(100vw - 24px))", top: "calc(env(safe-area-inset-top, 0px) + 82px)" }}
                    onClick={(e) => e.stopPropagation()}
                  >
                    {renderSummarizeMenuBody()}
                  </div>
                </div>,
                document.body
              ) : (
                <div
                  className="absolute right-0 top-full mt-1 border border-white/10 rounded-xl shadow-xl z-50"
                  style={{ background: "rgba(22, 27, 34, 0.95)", backdropFilter: "blur(12px)", padding: "12px", width: 260 }}
                >
                  {renderSummarizeMenuBody()}
                </div>
              )
            )}
          </div>

          {!isPhone && <div className="w-px h-5 bg-white/10" />}

          <button
            onClick={() => toggleStar.mutate(article.id)}
            className={`${isPhone ? "phone-icon-button border border-white/10 bg-white/[0.02]" : "tap-target rounded-lg"} hover:bg-white/10 transition-colors ${
              article.is_starred ? "text-warning" : "text-text-muted hover:text-text-primary"
            }`}
            title={article.is_starred ? "Unstar" : "Star"}
          >
            <svg width={isPhone ? 31 : 16} height={isPhone ? 31 : 16} viewBox="0 0 24 24" fill={article.is_starred ? "currentColor" : "none"} stroke="currentColor" strokeWidth="2">
              <polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2" />
            </svg>
          </button>

          {!isPhone && (
            <button
              onClick={() => toggleRead.mutate(article.id)}
              className={`tap-target rounded-lg hover:bg-white/10 transition-colors ${
                !article.is_read ? "text-accent" : "text-text-muted hover:text-text-primary"
              }`}
              title={article.is_read ? "Mark as unread" : "Mark as read"}
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill={!article.is_read ? "currentColor" : "none"} stroke="currentColor" strokeWidth="2">
                <circle cx="12" cy="12" r="5" />
              </svg>
            </button>
          )}


          {article.url && !isPhone && (
            <button
              onClick={() => { if (article.url) openUrl(article.url); }}
              className="tap-target text-text-muted hover:text-text-primary rounded-lg hover:bg-white/10 transition-colors"
              title="Open in browser"
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6M15 3h6v6M10 14L21 3" />
              </svg>
            </button>
          )}
        </div>
      </div>

      {fullError && (
        <div style={{ padding: "0 24px 8px" }}>
          <p className="text-danger" style={{ fontSize: 13 }}>{fullError}</p>
        </div>
      )}

      {/* Summary — visible across all panels */}
      {summarize.isPending && (
        <div className="flex-shrink-0" style={{ maxWidth: 720, margin: "0 auto", padding: "0 40px 8px", width: "100%" }}>
          <div className="rounded-xl border border-white/10" style={{ padding: "16px 20px", background: "rgba(255,255,255,0.03)" }}>
            <div className="text-text-muted uppercase tracking-wider font-semibold" style={{ fontSize: 11, marginBottom: 8 }}>AI Summary</div>
            <div className="flex items-center gap-2 text-text-muted" style={{ fontSize: 14 }}>
              <svg className="smooth-spin" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M21 12a9 9 0 1 1-6.219-8.56" />
              </svg>
              Summarizing...
            </div>
          </div>
        </div>
      )}

      {summarize.data && (
        <div className="flex-shrink-0" style={{ maxWidth: 720, margin: "0 auto", padding: "0 40px 8px", width: "100%", maxHeight: "40vh", overflow: "hidden", display: "flex", flexDirection: "column" }}>
          <div className="rounded-xl border border-white/10" style={{ background: "rgba(255,255,255,0.03)", overflowY: "auto", display: "flex", flexDirection: "column", minHeight: 0 }}>
            <div
              className="flex items-center justify-between"
              style={{
                position: "sticky",
                top: 0,
                background: "rgba(28, 33, 40, 0.96)",
                backdropFilter: "blur(8px)",
                padding: isPhone ? "2px 8px 2px 12px" : "6px 12px",
                minHeight: isPhone ? 32 : 34,
                borderBottom: "1px solid rgba(255,255,255,0.06)",
                zIndex: 1,
              }}
            >
              <div className="text-text-muted uppercase tracking-wider font-semibold" style={{ fontSize: isPhone ? 10 : 11 }}>AI Summary</div>
              <button
                onClick={() => summarize.reset()}
                className="inline-flex items-center justify-center text-text-muted hover:text-text-primary transition-colors rounded-md hover:bg-white/10"
                style={{ lineHeight: 0, width: isPhone ? 30 : 28, height: isPhone ? 30 : 28, flex: "0 0 auto" }}
                title="Dismiss summary"
                aria-label="Dismiss summary"
              >
                <svg width={isPhone ? 18 : 12} height={isPhone ? 18 : 12} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                  <path d="M18 6L6 18M6 6l12 12" />
                </svg>
              </button>
            </div>
            <div style={{ padding: "12px 16px 16px" }}>
              {summarize.data.bullet_summary && (
                <div className="text-text-primary whitespace-pre-wrap" style={{ fontSize: 14, marginBottom: 10, lineHeight: 1.6 }}>{summarize.data.bullet_summary}</div>
              )}
              {summarize.data.full_summary && (
                <div
                  className="text-text-primary leading-relaxed prose prose-invert prose-sm max-w-none"
                  style={{ fontSize: 14, opacity: 0.85 }}
                  dangerouslySetInnerHTML={{
                    __html: summarize.data.full_summary
                      .replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>')
                      .replace(/\*(.+?)\*/g, '<em>$1</em>')
                      .replace(/\n\n/g, '</p><p style="margin-top:12px">')
                      .replace(/^/, '<p>').replace(/$/, '</p>')
                  }}
                />
              )}
              <div style={{ marginTop: 12 }}>
                <AIDisclaimer />
              </div>
            </div>
          </div>
        </div>
      )}

      {summarize.isError && (() => {
        const msg = String(summarize.error instanceof Error ? summarize.error.message : summarize.error);
        const lower = msg.toLowerCase();
        const isConfigError = msg.includes("[configure-ai]") || lower.includes("no ai provider configured") || lower.includes("no local model selected") || lower.includes("go to settings");
        const isModelLoadError = lower.includes("failed to load model") || lower.includes("null result from llama");
        const isNotSignedIn = lower.includes("not signed in to claude");
        const isUnknownModel = lower.includes("not_found_error") && lower.includes("model:");
        const modelMatch = isUnknownModel ? msg.match(/"model:\s*([^"}\s]+)"?/i) : null;
        const badModel = modelMatch ? modelMatch[1] : null;
        return (
          <div className="flex-shrink-0" style={{ maxWidth: 720, margin: "0 auto", padding: "0 40px 8px", width: "100%" }}>
            {isConfigError ? (
              <div className="rounded-xl border border-white/10" style={{ padding: "12px 16px", fontSize: 14, background: "rgba(255,255,255,0.03)" }}>
                <span className="text-text-secondary">AI not configured. </span>
                <button onClick={() => useUiStore.getState().setShowSettings(true)} className="text-accent hover:underline">Open Settings</button>
                <span className="text-text-secondary"> to set up a provider.</span>
              </div>
            ) : isModelLoadError ? (
              <div className="rounded-xl border border-warning/30" style={{ padding: "12px 16px", fontSize: 14, background: "rgba(255, 170, 50, 0.08)" }}>
                <span className="text-warning font-medium">Model failed to load. </span>
                <span className="text-text-secondary">It may be corrupted or too large for your system. </span>
                <button onClick={() => useUiStore.getState().setShowSettings(true)} className="text-accent hover:underline">Try a different model</button>
              </div>
            ) : isNotSignedIn ? (
              <div className="rounded-xl border border-warning/30" style={{ padding: "12px 16px", fontSize: 14, background: "rgba(255, 170, 50, 0.08)" }}>
                <span className="text-warning font-medium">Not signed in to Claude. </span>
                <button onClick={() => useUiStore.getState().setShowSettings(true)} className="text-accent hover:underline">Sign in</button>
              </div>
            ) : isUnknownModel ? (
              <div className="rounded-xl border border-warning/30" style={{ padding: "12px 16px", fontSize: 14, background: "rgba(255, 170, 50, 0.08)", lineHeight: 1.5 }}>
                <div className="text-warning font-medium" style={{ marginBottom: 4 }}>
                  Model not found{badModel ? `: ${badModel}` : ""}
                </div>
                <div className="text-text-secondary">
                  Anthropic's model IDs change over time. Find the current ID at{" "}
                  <a href="https://docs.anthropic.com/en/docs/about-claude/models" target="_blank" rel="noreferrer" className="text-accent hover:underline">
                    docs.anthropic.com/models
                  </a>{" "}
                  (or use a family alias like <code className="text-accent">claude-sonnet-4-5</code>), then{" "}
                  <button onClick={() => useUiStore.getState().setShowSettings(true)} className="text-accent hover:underline">
                    paste it into Settings → AI Provider → Model
                  </button>.
                </div>
              </div>
            ) : (
              <div className="rounded-xl border border-danger/30 text-danger" style={{ padding: "12px 16px", fontSize: 14, background: "rgba(248, 81, 73, 0.1)" }}>
                {msg}
              </div>
            )}
          </div>
        );
      })()}

      {/* Swipeable article surface: drag either commits to the next pane or settles back to center. */}
      <div
        ref={articleFrameRef}
        className="flex-1 min-h-0 relative overflow-hidden"
        onTouchStart={handleArticleTouchStart}
        onTouchMove={handleArticleTouchMove}
        onTouchEnd={handleArticleTouchEnd}
        onTouchCancel={handleArticleTouchEnd}
        style={{ overscrollBehaviorX: "none", touchAction: isPhone ? "pan-y" : undefined }}
      >
        <div
          className="h-full w-full"
          onTransitionEnd={(e) => {
            if (e.currentTarget === e.target && e.propertyName === "transform" && dismissTransition !== "none") {
              finishDismissTransition();
            }
          }}
          style={{
            transform: `translate3d(${dismissOffset}px, 0, 0)`,
            transition: dismissTransitionStyle,
            willChange: isPhone ? "transform" : undefined,
          }}
        >
          <div
            className="h-full flex"
            onTransitionEnd={(e) => {
              if (e.currentTarget === e.target && e.propertyName === "transform" && modeTransition !== "none") {
                finishModeTransition();
              }
            }}
            style={{
              width: effectiveArticleFrameWidth * 2,
              transform: `translate3d(${modeTrackX}px, 0, 0)`,
              transition: modeTransitionStyle,
              willChange: isPhone ? "transform" : undefined,
            }}
          >
            <section
              className="h-full overflow-hidden"
              aria-hidden={viewMode !== "reader"}
              style={{ width: effectiveArticleFrameWidth, flex: "0 0 auto" }}
            >
              <div
                ref={readerScrollRef}
                className="h-full overflow-y-auto overflow-x-hidden relative"
                style={{ overscrollBehaviorX: "none", touchAction: "pan-y" }}
                {...readerRefresh.pullToRefreshHandlers}
              >
                {readerRefresh.pullToRefreshIndicator}
                <div
                  style={{
                    ...readerRefresh.pullToRefreshContentStyle,
                    maxWidth: 720,
                    width: "100%",
                    margin: "0 auto",
                    padding: isPhone ? "16px 16px 64px" : "24px 40px 80px",
                    overflowX: "hidden",
                  }}
                >
                  <div style={{ marginBottom: 28 }}>
                    <h1 className="text-text-primary" style={{ fontSize: 26, fontWeight: 700, lineHeight: 1.3, marginBottom: 12 }}>{article.title}</h1>
                    <div className="flex items-center flex-wrap gap-x-2 gap-y-1" style={{ fontSize: 13 }}>
                      <span className="text-accent font-medium">{article.feed_title}</span>
                      {article.author && (<><span className="text-text-muted">·</span><span className="text-text-secondary">{article.author}</span></>)}
                      <span className="text-text-muted">·</span>
                      <span className="text-text-muted">{formatDate(article.published_at)}</span>
                    </div>
                  </div>
                  {fullContent ? (
                    <div className="full-article-content" dangerouslySetInnerHTML={{ __html: fullContent }} />
                  ) : loadingFull ? (
                    <div className="flex items-center gap-2 text-text-muted" style={{ fontSize: 14 }}>
                      <svg className="smooth-spin" width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                        <path d="M21 12a9 9 0 1 1-6.219-8.56" />
                      </svg>
                      Loading article…
                    </div>
                  ) : rssHtml ? (
                    <div className="article-content text-text-primary" dangerouslySetInnerHTML={{ __html: rssHtml }} />
                  ) : article.content_text ? (
                    <div className="article-content text-text-primary whitespace-pre-wrap">{article.content_text}</div>
                  ) : (
                    <p className="text-text-muted" style={{ fontSize: 14 }}>No preview available.</p>
                  )}
                </div>
              </div>
            </section>

            <section
              className="h-full overflow-hidden"
              aria-hidden={viewMode !== "web"}
              style={{ width: effectiveArticleFrameWidth, flex: "0 0 auto" }}
            >
              <div className="h-full relative overflow-hidden">
                {webPullToRefreshIndicator}
                <div className="h-full relative" style={webPullToRefreshContentStyle}>
                  {article.url && (
                    <button
                      onClick={() => { if (article.url) openUrl(article.url); }}
                      className="absolute bg-bg-secondary/90 hover:bg-bg-secondary border border-white/15 text-text-primary backdrop-blur-md rounded-full shadow-lg transition-colors flex items-center justify-center z-10"
                      style={{ bottom: 16, right: 16, width: 48, height: 48 }}
                      title="Open original in external browser"
                      aria-label="Open in browser"
                    >
                      <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                        <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6M15 3h6v6M10 14L21 3" />
                      </svg>
                    </button>
                  )}
                  {loadingFull && !rawHtml && (
                    <div className="absolute inset-0 flex flex-col items-center justify-center text-center" style={{ padding: "0 24px" }}>
                      <svg className="smooth-spin text-text-muted" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" style={{ marginBottom: 12 }}>
                        <path d="M21 12a9 9 0 1 1-6.219-8.56" />
                      </svg>
                      <p className="text-text-muted" style={{ fontSize: 14 }}>
                        Loading web view...
                      </p>
                    </div>
                  )}
                  {!rawHtml && !loadingFull && (
                    <div className="flex flex-col items-center justify-center h-full text-center" style={{ padding: "0 24px" }}>
                      <p className="text-text-muted" style={{ fontSize: 14, marginBottom: 8 }}>
                        {fullError ? "Couldn't load page in the embedded view." : "No embedded page preview is available."}
                      </p>
                      <p className="text-text-muted" style={{ fontSize: 12 }}>
                        Use the "Open in browser" button.
                      </p>
                    </div>
                  )}
                  {rawHtml && (
                    <iframe
                      key={`${article.id}:${article.url}`}
                      ref={iframeRef}
                      srcDoc={buildEmbeddedWebSrcDoc(rawHtml)}
                      sandbox="allow-scripts allow-popups allow-forms allow-modals allow-pointer-lock allow-presentation"
                      style={{ width: "100%", height: "100%", border: "none", background: "#fff", overflow: "hidden" }}
                      title="Article web view"
                      onLoad={() => {
                        try {
                          const win = iframeRef.current?.contentWindow;
                          if (!win) return;
                          const s = win.document.createElement("style");
                          s.textContent = EMBEDDED_WEB_VIEW_CSS;
                          win.document.head.appendChild(s);
                          win.document.addEventListener("contextmenu", (e: Event) => e.preventDefault());
                          win.addEventListener("keydown", ((e: KeyboardEvent) => {
                            if (e.key === "ArrowLeft" || e.key === "ArrowRight") {
                              e.preventDefault();
                              window.dispatchEvent(new KeyboardEvent("keydown", { key: e.key }));
                            }
                          }) as EventListener);
                        } catch { /* cross-origin */ }
                      }}
                    />
                  )}
                </div>
              </div>
            </section>
          </div>
        </div>
      </div>

      {/* Chat drawer — collapsible bottom pane */}
      <ChatDrawer articleId={article.id} articleTitle={article.title} />
    </div>
  );
}
