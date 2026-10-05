import { useEffect, useRef } from "react";

// Actions whose state lives inside a mounted component (the Ask Skim dialog,
// the article list's search box, the reader's chat drawer...) are reached
// from the command palette through this window event, so the palette does
// not need to own that state.
export type AppCommand =
  | "ask-skim"
  | "focus-search"
  | "mark-all-read"
  | "summarize"
  | "toggle-chat"
  | "reader-view"
  | "web-view";

export const APP_COMMAND_EVENT = "skim:app-command";

export function runAppCommand(command: AppCommand) {
  window.dispatchEvent(new CustomEvent<AppCommand>(APP_COMMAND_EVENT, { detail: command }));
}

export function useAppCommand(command: AppCommand, handler: () => void) {
  const latest = useRef(handler);
  latest.current = handler;
  useEffect(() => {
    const listener = (event: Event) => {
      if ((event as CustomEvent<AppCommand>).detail === command) latest.current();
    };
    window.addEventListener(APP_COMMAND_EVENT, listener);
    return () => window.removeEventListener(APP_COMMAND_EVENT, listener);
  }, [command]);
}
