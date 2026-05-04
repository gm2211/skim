import SkimCore
import SwiftUI

@main
struct SkimMacOSApp: App {
    var body: some Scene {
        Window("Skim", id: "main") {
            VStack(spacing: 12) {
                Text("Skim")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Native macOS is intentionally deferred while the iOS reading loop proves the pivot.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            .padding(36)
            .frame(minWidth: 460, minHeight: 280)
        }
    }
}
