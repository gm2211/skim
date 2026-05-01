import React from "react";
import ReactDOM from "react-dom/client";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import App from "./App";
import "./globals.css";

// Probe iOS safe-area-inset values once at boot and expose as CSS vars,
// because env(safe-area-inset-*) sometimes returns 0 inside dialogs that
// run later in the lifecycle (e.g. when a body lock is active). Fallback
// values cover iPhone Dynamic Island devices.
function probeSafeArea() {
  const probe = document.createElement("div");
  probe.style.cssText =
    "position:fixed;top:0;left:0;padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left);visibility:hidden;pointer-events:none";
  document.body.appendChild(probe);
  const cs = getComputedStyle(probe);
  const top = parseFloat(cs.paddingTop) || 0;
  const bottom = parseFloat(cs.paddingBottom) || 0;
  const left = parseFloat(cs.paddingLeft) || 0;
  const right = parseFloat(cs.paddingRight) || 0;
  document.body.removeChild(probe);
  const root = document.documentElement;
  root.style.setProperty("--sat", `${top}px`);
  root.style.setProperty("--sab", `${bottom}px`);
  root.style.setProperty("--sal", `${left}px`);
  root.style.setProperty("--sar", `${right}px`);
}
probeSafeArea();
window.addEventListener("resize", probeSafeArea);
window.addEventListener("orientationchange", probeSafeArea);

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      retry: 1,
      staleTime: 30_000,
    },
  },
});

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      <App />
    </QueryClientProvider>
  </React.StrictMode>,
);
