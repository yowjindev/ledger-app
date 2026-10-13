import SwiftUI

/// An error or notice to show in an alert.
struct LedgerAlert: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String

    init(title: String, message: String) {
        self.title = title
        self.message = message
    }

    /// Uses the error's user-facing description. Unknown errors get a generic message so
    /// internal details are never shown.
    init(_ error: Error, title: String = "Couldn't Complete That") {
        self.title = title
        self.message = (error as? LocalizedError)?.errorDescription ?? "Something went wrong. Nothing was changed."
    }
}

extension View {
    /// Presents `alert` while it is non-nil.
    func ledgerAlert(_ alert: Binding<LedgerAlert?>) -> some View {
        self.alert(
            alert.wrappedValue?.title ?? "",
            isPresented: Binding(
                get: { alert.wrappedValue != nil },
                set: { if !$0 { alert.wrappedValue = nil } }
            ),
            presenting: alert.wrappedValue
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { item in
            Text(item.message)
        }
    }
}
