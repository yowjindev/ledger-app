import Foundation
import Observation

/// Where a Live Activity button asked the app to go: paying a due, or moving it.
enum ReminderRoute: Identifiable, Hashable, Sendable {
    case pay(DueOwner)
    case move(DueOwner)

    var id: String {
        switch self {
        case .pay(let owner): "pay-\(owner.key)"
        case .move(let owner): "move-\(owner.key)"
        }
    }
}

/// Carries a Live Activity button's request to the app's screens, which present it.
@MainActor
@Observable
final class ReminderRouting {
    static let shared = ReminderRouting()

    var pending: ReminderRoute?
}
