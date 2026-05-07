import CoreText
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

@main
struct SkimNativeApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif
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

#if canImport(UIKit)
/// Handles background URLSession completion events for MLX model downloads.
///
/// When the OS relaunches the app after a background download finishes, it calls
/// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`. We store
/// the completion handler and call it once the session delegate has processed all
/// pending events — this tells the OS it can safely suspend the app again.
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// Keyed by session identifier; called after all background events are delivered.
    var backgroundSessionCompletionHandlers: [String: () -> Void] = [:]

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        // Store the handler. The URLSession delegate will call it via
        // urlSessionDidFinishEvents(forBackgroundURLSession:) once all
        // queued events have been delivered.
        backgroundSessionCompletionHandlers[identifier] = completionHandler
    }
}
#endif

private enum AppFonts {
    static func register() {
        guard let url = Bundle.main.url(forResource: "AquireBold", withExtension: "otf") else { return }
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }
}
