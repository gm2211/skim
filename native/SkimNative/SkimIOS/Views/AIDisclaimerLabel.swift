import SwiftUI

/// Small reusable disclaimer label shown beneath any AI-generated content surface.
/// Text lifted verbatim from src/components/common/AIDisclaimer.tsx.
struct AIDisclaimerLabel: View {
    var body: some View {
        Text("AI-generated. May be inaccurate or biased — verify important details. Skim does not produce or endorse this content.")
            .font(.system(size: 11, weight: .regular))
            .foregroundStyle(SkimStyle.secondary.opacity(0.78))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, 6)
            .accessibilityLabel("AI disclaimer")
    }
}
