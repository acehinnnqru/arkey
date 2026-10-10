//
//  arkeyApp.swift
//  arkey
//
//  Created by rqc on 2026/9/23.
//

import SwiftUI
import RimeEngine

@main
struct arkeyApp: App {
    @AppStorage(RimeLocalization.storageKey, store: UserDefaults(suiteName: RimeKeyboardPreferencesStore.appGroupID))
    private var interfaceLanguage = RimeAppLanguage.chinese.rawValue
    init() {
        LaunchProbe.mark("appInit")
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--candidate-scroll-ui-test") {
                CandidateScrollTestScreen()
            } else {
                ContentView()
                  .environment(\.locale, RimeAppLanguage.resolve(interfaceLanguage).locale)
            }
            #else
            ContentView()
              .environment(\.locale, RimeAppLanguage.resolve(interfaceLanguage).locale)
            #endif
        }
    }
}
