// Frontend platform detection. iOS WKWebView and iPadOS-pretending-to-be-Mac
// both behave the same way for our backend gating (Skim Swift plugin is only
// compiled into the iOS Tauri bundle), so collapse them under one flag.
export const isIOS =
  /iPad|iPhone|iPod/.test(navigator.userAgent) ||
  (navigator.userAgent.includes("Mac") && navigator.maxTouchPoints > 1);
