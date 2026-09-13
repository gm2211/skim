// Keep iPadOS's desktop user agent separate from the macOS native runtime.
export const isIOS =
  /iPad|iPhone|iPod/.test(navigator.userAgent) ||
  (navigator.userAgent.includes("Mac") && navigator.maxTouchPoints > 1);

export const isMacOS = navigator.userAgent.includes("Mac") && !isIOS;
