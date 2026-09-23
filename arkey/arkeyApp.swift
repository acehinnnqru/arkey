//
//  arkeyApp.swift
//  arkey
//
//  Created by rqc on 2026/9/23.
//

import SwiftUI

@main
struct arkeyApp: App {
    init() {
        LaunchProbe.mark("appInit")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
