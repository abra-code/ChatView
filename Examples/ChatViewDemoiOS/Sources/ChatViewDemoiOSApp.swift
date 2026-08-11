// Examples/ChatViewDemoiOS/Sources/ChatViewDemoiOSApp.swift
//
// The iOS demo app. Everything of substance is in RemoteAgentScreen (Examples/Shared), which
// the macOS demo compiles too; this file is only the app shell.
//
// To run it:
//   1. On the Mac:  ./Scripts/run-bridge-demo.sh          (add --lan for a real device)
//   2. Here:        cd Examples/ChatViewDemoiOS && xcodegen generate && open ChatViewDemoiOS.xcodeproj
//   3. Run on a simulator (127.0.0.1 reaches the Mac directly) or a device on the same network.

import SwiftUI
import ChatView
import ChatViewACP

@main
struct ChatViewDemoiOSApp: App {

    init() {
        // Registers `acp-remote`. On iOS `acp` is not registered at all - it spawns a
        // subprocess, which the platform does not allow - and that asymmetry is the entire
        // reason this transport exists.
        ChatViewACP.register()
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                RemoteAgentScreen()
            }
        }
    }
}
