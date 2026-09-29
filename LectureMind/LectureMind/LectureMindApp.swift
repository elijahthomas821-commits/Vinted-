import SwiftUI

@main
@MainActor
struct LectureMindApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(appState)
        } label: {
            Image(systemName: appState.status.menuBarSymbolName)
                .accessibilityLabel("LectureMind: \(appState.status.title)")
        }
        .menuBarExtraStyle(.window)
    }
}
