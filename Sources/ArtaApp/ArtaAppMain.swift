import SwiftUI

@main
struct ArtaApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Arta — Acoustic Measurement") {
            MainView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
