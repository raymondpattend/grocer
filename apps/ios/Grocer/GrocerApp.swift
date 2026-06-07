import SwiftUI

@main
struct GrocerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var repository = GroceryRepository.makeShared()
    @State private var settings = SettingsStore.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(repository)
                .environment(settings)
                .task {
                    await repository.bootstrap()
                }
        }
    }
}
