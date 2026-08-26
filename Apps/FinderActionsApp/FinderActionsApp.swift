import SwiftUI

@main
struct FinderActionsApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 780, minHeight: 560)
        }
        .windowStyle(.titleBar)
    }
}
