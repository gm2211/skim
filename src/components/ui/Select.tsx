import { SelectHTMLAttributes, forwardRef } from "react";

export type SelectProps = SelectHTMLAttributes<HTMLSelectElement> & {
  /** Stretch to fill the row instead of sizing to the widest option. */
  fullWidth?: boolean;
};

/**
 * Native <select> with the platform chrome stripped and the app's dark,
 * rounded styling applied, plus our own chevron. Keeping the native element
 * means the OS picker (and its phone/VoiceOver behaviour) still does the work.
 */
export const Select = forwardRef<HTMLSelectElement, SelectProps>(function Select(
  { fullWidth = false, className = "", style, disabled, ...rest },
  ref
) {
  return (
    <span
      className={`relative inline-flex items-center ${fullWidth ? "w-full" : ""}`}
      style={{ opacity: disabled ? 0.5 : 1 }}
    >
      <select
        {...rest}
        ref={ref}
        disabled={disabled}
        className={`appearance-none border border-white/10 rounded-lg text-text-primary transition-colors hover:border-white/20 focus:outline-none focus:border-accent/60 disabled:cursor-not-allowed ${fullWidth ? "w-full" : ""} ${className}`}
        style={{
          background: "rgba(255,255,255,0.05)",
          padding: "9px 34px 9px 12px",
          fontSize: 13,
          minHeight: 40,
          fontWeight: 500,
          cursor: disabled ? "not-allowed" : "pointer",
          ...style,
        }}
      />
      <svg
        className="absolute text-text-muted"
        style={{ right: 12, pointerEvents: "none" }}
        width="12"
        height="12"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="2.5"
        strokeLinecap="round"
        strokeLinejoin="round"
        aria-hidden="true"
      >
        <path d="M6 9l6 6 6-6" />
      </svg>
    </span>
  );
});
