import { useEffect, type RefObject } from "react";

// iOS WKWebView shifts the visual viewport (not the document) when the
// soft keyboard appears. We mutate the dialog's DOM directly on every
// visualViewport event so the dialog tracks the visible area without
// the lag of a React re-render.
export function useVisualViewportSync(
  ref: RefObject<HTMLElement | null>,
  active: boolean
) {
  useEffect(() => {
    if (!active) return;
    const vv = window.visualViewport;
    const el = ref.current;
    if (!vv || !el) return;
    const apply = () => {
      el.style.height = `${vv.height}px`;
      el.style.transform = `translate3d(0, ${vv.offsetTop}px, 0)`;
    };
    apply();
    vv.addEventListener("resize", apply);
    vv.addEventListener("scroll", apply);
    return () => {
      vv.removeEventListener("resize", apply);
      vv.removeEventListener("scroll", apply);
    };
  }, [active, ref]);
}
