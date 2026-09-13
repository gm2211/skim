export function SkimTitle({ isPhone = false }: { isPhone?: boolean }) {
  return (
    <h1 style={{
      fontFamily: "'Aquire', sans-serif",
      fontSize: isPhone ? 22 : 18,
      fontWeight: 700,
      letterSpacing: "0.15em",
      transform: "scaleX(1.6)",
      transformOrigin: "left center",
      color: "#e6edf3",
      textShadow: "0 0 14px rgba(136, 200, 255, 0.35)",
      lineHeight: 1,
      whiteSpace: "nowrap",
      flexShrink: 0,
    }}>SKIM</h1>
  );
}
