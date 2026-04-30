interface Props {
  variant?: "inline" | "block";
}

export function AIDisclaimer({ variant = "inline" }: Props) {
  const text =
    "AI-generated. May be inaccurate or biased — verify important details. Skim does not produce or endorse this content.";

  if (variant === "block") {
    return (
      <div
        className="text-text-muted"
        style={{
          fontSize: 11,
          lineHeight: 1.5,
          padding: "6px 10px",
          background: "rgba(255,255,255,0.03)",
          border: "1px solid rgba(255,255,255,0.06)",
          borderRadius: 8,
          opacity: 0.75,
        }}
        role="note"
      >
        {text}
      </div>
    );
  }

  return (
    <div
      className="text-text-muted text-center"
      style={{ fontSize: 11, opacity: 0.78, lineHeight: 1.45 }}
      role="note"
    >
      {text}
    </div>
  );
}
