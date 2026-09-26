import SwiftUI

@main
struct ModelHubMobileApp: App {
    @State private var store = MobileStore()

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
        }
    }
}
