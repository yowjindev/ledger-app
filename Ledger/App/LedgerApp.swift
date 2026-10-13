import SwiftData
import SwiftUI

@main
struct LedgerApp: App {
    var body: some Scene {
        WindowGroup {
            switch LedgerStore.shared {
            case .success(let container):
                RootView()
                    .modelContainer(container)
            case .failure(let error):
                StoreUnavailableView(error: error)
            }
        }
    }
}
