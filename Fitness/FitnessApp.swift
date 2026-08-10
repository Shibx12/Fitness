import SwiftUI

@main
struct FitnessApp: App {
    @StateObject private var store = HealthDataStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(store)
        }
    }
}
