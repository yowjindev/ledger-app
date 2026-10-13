import SwiftUI

/// Where Ledger keeps data, what it never does, how backups work, and where balances come from.
struct DataPrivacyView: View {
    var body: some View {
        List {
            Section {
                SettingsGuideHeader(
                    systemImage: "hand.raised.fill",
                    title: "Stored on This iPhone",
                    message: "Ledger works without an account or an internet connection. Your data is included in this iPhone's backups."
                )
            }

            Section("Storage") {
                SettingsInfoRow(
                    systemImage: "iphone",
                    title: "On This iPhone",
                    detail: "Your records are stored in Ledger's private app storage, with no server or sync."
                )
                SettingsInfoRow(
                    systemImage: "person.crop.circle.badge.xmark",
                    title: "No Sign-In",
                    detail: "There's no account to create."
                )
                SettingsInfoRow(
                    systemImage: "server.rack",
                    title: "No Server",
                    detail: "Ledger has no server, so nothing is sent to one."
                )
                SettingsInfoRow(
                    systemImage: "building.columns",
                    title: "No Bank Connection",
                    detail: "Ledger never connects to a bank."
                )
                SettingsInfoRow(
                    systemImage: "wifi.slash",
                    title: "No Network Access",
                    detail: "Ledger doesn't use the internet."
                )
            }

            Section("Backups") {
                SettingsInfoRow(
                    systemImage: "icloud",
                    tint: LedgerTheme.transfer,
                    title: "Included in Your Backups",
                    detail: "Ledger's data is part of this iPhone's iCloud Backup or computer backup when those are on."
                )
                SettingsInfoRow(
                    systemImage: "arrow.triangle.2.circlepath",
                    tint: LedgerTheme.transfer,
                    title: "No Export or Sync Yet",
                    detail: "There's no separate export, and no sync with other devices yet."
                )
                SettingsInfoRow(
                    systemImage: "trash",
                    tint: .red,
                    title: "Deleting the App Deletes Its Data",
                    detail: "Removing Ledger erases its records from this iPhone."
                )
            }

            Section("Balances") {
                SettingsInfoRow(
                    systemImage: "function",
                    title: "Calculated, Never Fetched",
                    detail: "Balances are calculated from your opening balances and transactions. They're never fetched from a bank."
                )
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Data & Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        DataPrivacyView()
    }
}
