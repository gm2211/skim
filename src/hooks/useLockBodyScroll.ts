import { useEffect } from "react";

// iOS WKWebView scrolls the document up when a textarea inside a fixed
// dialog gains focus. Even position:fixed children get pushed under the
// notch. The standard workaround is to pin the body in place while the
// dialog is open: position:fixed + negative top equal to current scrollY.
export function useLockBodyScroll(active: boolean) {
  useEffect(() => {
    if (!active) return;
    const html = document.documentElement;
    const body = document.body;
    const scrollY = window.scrollY;
    const original = {
      htmlOverflow: html.style.overflow,
      bodyOverflow: body.style.overflow,
      bodyPosition: body.style.position,
      bodyTop: body.style.top,
      bodyLeft: body.style.left,
      bodyRight: body.style.right,
      bodyWidth: body.style.width,
    };
    // Scroll to top first so that body's "fixed at top:0" lock doesn't
    // visually shift the portal'd dialog (which is anchored to body via
    // createPortal). The user's scroll position is restored on cleanup.
    window.scrollTo(0, 0);
    html.style.overflow = "hidden";
    body.style.overflow = "hidden";
    body.style.position = "fixed";
    body.style.top = "0";
    body.style.left = "0";
    body.style.right = "0";
    body.style.width = "100%";
    return () => {
      html.style.overflow = original.htmlOverflow;
      body.style.overflow = original.bodyOverflow;
      body.style.position = original.bodyPosition;
      body.style.top = original.bodyTop;
      body.style.left = original.bodyLeft;
      body.style.right = original.bodyRight;
      body.style.width = original.bodyWidth;
      window.scrollTo(0, scrollY);
    };
  }, [active]);
}
