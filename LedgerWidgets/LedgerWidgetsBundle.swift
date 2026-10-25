import SwiftUI
import WidgetKit

/// Ledger's widget extension. It draws the due reminder Live Activity.
@main
struct LedgerWidgetsBundle: WidgetBundle {
    var body: some Widget {
        DueActivityWidget()
    }
}
