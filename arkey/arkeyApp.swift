import SwiftUI
import RimeEngine

@main
struct arkeyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var systemLanguages = Locale.preferredLanguages
    @AppStorage(RimeLocalization.storageKey, store: UserDefaults(suiteName: RimeKeyboardPreferencesStore.appGroupID))
    private var interfaceLanguage = RimeAppLanguage.chinese.rawValue
    init() {
        LaunchProbe.mark("appInit")
    }

    var body: some Scene {
        WindowGroup {
          Group {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--candidate-scroll-ui-test") {
                CandidateScrollTestScreen()
            } else {
                ContentView()
                  .environment(\.locale, RimeAppLanguage.resolve(interfaceLanguage)
                    .resolved(preferredLanguages: systemLanguages).locale)
            }
            #else
            ContentView()
              .environment(\.locale, RimeAppLanguage.resolve(interfaceLanguage)
                .resolved(preferredLanguages: systemLanguages).locale)
            #endif
          }
          .onChange(of: scenePhase) { _, phase in
            if phase == .active { systemLanguages = Locale.preferredLanguages }
          }
          .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            systemLanguages = Locale.preferredLanguages
          }
        }
    }
}
