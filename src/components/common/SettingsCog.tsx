import { useEffect, useRef, useState, type ReactNode } from "react";
import { IconButton } from "./IconButton";
import { CogIcon } from "../ui/icons";
import "./SettingsCog.css";

/**
 * A cog that opens a small settings popover, in place of a control (such as a
 * model picker) that would otherwise crowd a header. Closes on an outside
 * click or Escape.
 */
export function SettingsCog({ label, heading, size = 18, className = "", children }: {
  label: string;
  heading: string;
  size?: number;
  className?: string;
  children: (close: () => void) => ReactNode;
}) {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const close = (event: MouseEvent | KeyboardEvent) => {
      if (event instanceof KeyboardEvent) {
        if (event.key !== "Escape") return;
        // Close only the popover, not the dialog or drawer around it.
        event.stopPropagation();
        setOpen(false);
      } else if (!ref.current?.contains(event.target as Node)) {
        setOpen(false);
      }
    };
    document.addEventListener("mousedown", close);
    // Capture, so the cog's own tooltip dismissal does not swallow Escape.
    document.addEventListener("keydown", close, true);
    return () => { document.removeEventListener("mousedown", close); document.removeEventListener("keydown", close, true); };
  }, [open]);

  return (
    <div ref={ref} className="relative">
      <IconButton
        label={label}
        // No tooltip while open: it would sit over the popover.
        tooltip={open ? "" : label}
        aria-expanded={open}
        aria-haspopup="dialog"
        onClick={() => setOpen(!open)}
        className={`hover:text-text-primary hover:bg-white/10 ${open ? "text-text-primary bg-white/10" : "text-text-muted"} ${className}`}
      >
        <CogIcon size={size} />
      </IconButton>
      {open && (
        <div className="today-settings" role="dialog" aria-label={label}>
          <div className="today-settings-heading">{heading}</div>
          {children(() => setOpen(false))}
        </div>
      )}
    </div>
  );
}
