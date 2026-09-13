export function SkimTitle({ isPhone = false }: { isPhone?: boolean }) {
  return (
    <h1 style={{
      fontFamily: "'Aquire', sans-serif",
      fontSize: isPhone ? 22 : 18,
      fontWeight: 700,
      letterSpacing: "0.15em",
      width: isPhone ? undefined : 80,
      transform: isPhone ? "scaleX(1.6)" : undefined,
      transformOrigin: "left center",
      color: "#e6edf3",
      textShadow: "0 0 14px rgba(136, 200, 255, 0.35)",
      lineHeight: 1,
      whiteSpace: "nowrap",
      flexShrink: 0,
    }}><span style={{ display: "inline-block", transform: isPhone ? undefined : "scaleX(1.6)", transformOrigin: "left center" }}>SKIM</span></h1>
  );
}
