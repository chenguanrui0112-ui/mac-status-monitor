import SwiftUI

@main
struct EdisonApplication: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(model: model)
        } label: {
            JerseyMenuBarIcon()
                .accessibilityLabel("edison")
        }
        .menuBarExtraStyle(.window)
    }
}

