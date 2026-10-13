import SwiftUI

/// Shown instead of the app when the data store can't be opened. Nothing is deleted.
struct StoreUnavailableView: View {
    let error: LedgerStoreError
    @State private var showsDetails = false

    var body: some View {
        ContentUnavailableView {
            Label("Ledger Can't Open Its Data", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text("Your data has not been deleted. Quit and reopen Ledger to try again. Don't delete the app: that would erase its data.")
        } actions: {
            Button(showsDetails ? "Hide Details" : "Show Details") {
                showsDetails.toggle()
            }
            if showsDetails {
                Text(error.underlyingDescription)
                    .font(.footnote.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal)
            }
        }
    }
}
