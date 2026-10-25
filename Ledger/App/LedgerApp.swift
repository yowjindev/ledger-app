import SwiftData
import SwiftUI

@main
struct LedgerApp: App {
    init() {
        if case .success(let container) = LedgerStore.shared {
            ReminderScheduler.shared.start(container: container)
        }
    }

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
