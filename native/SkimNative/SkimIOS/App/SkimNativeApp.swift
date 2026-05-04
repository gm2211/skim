import CoreText
import SwiftUI

@main
struct SkimNativeApp: App {
    @StateObject private var model = AppModel()

    init() {
        AppFonts.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}

private enum AppFonts {
    static func register() {
        guard let url = Bundle.main.url(forResource: "AquireBold", withExtension: "otf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}
