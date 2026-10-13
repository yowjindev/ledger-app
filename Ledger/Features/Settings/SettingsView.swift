import SwiftData
import SwiftUI

/// Settings tab: accounts and categories, display and logging preferences, Shortcuts and
/// Action Button setup, data and privacy, and the app version and credits.
struct SettingsView: View {
    @AppStorage(DisplayPreferences.Keys.symbolStyle) private var symbolStyle: CurrencySymbolStyle = .symbol
    @AppStorage(DisplayPreferences.Keys.centavos) private var centavos: CentavoDisplay = .always
    @AppStorage(AppPreferences.Keys.warnsAboutDuplicates) private var warnsAboutDuplicates = true
    @AppStorage(AppPreferences.Keys.dashboardPeriod) private var period: ReportingPeriod = .thisMonth

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Query(filter: #Predicate<Account> { !$0.isArchived }) private var activeAccounts: [Account]
    @Query(filter: #Predicate<LedgerCategory> { !$0.isArchived }) private var activeCategories: [LedgerCategory]

    var body: some View {
        Form {
            moneySection
            displaySection
            preferencesSection

            Section {
                NavigationLink {
                    ActionButtonGuideView()
                } label: {
                    Label("Shortcuts & Action Button", systemImage: "square.2.layers.3d")
                }
            } footer: {
                Text("Log in a few taps with the Action Button, Siri, or Spotlight.")
            }

            Section {
                NavigationLink {
                    DataPrivacyView()
                } label: {
                    Label("Data & Privacy", systemImage: "hand.raised")
                }
            }

            Section {
                LabeledContent("Version", value: Self.infoValue("CFBundleShortVersionString"))
                LabeledContent("Build", value: Self.infoValue("CFBundleVersion"))
            } header: {
                Text("About")
            } footer: {
                CreditsView()
            }
        }
        .navigationTitle("Settings")
    }

    // MARK: Sections

    private var moneySection: some View {
        Section("Money") {
            NavigationLink {
                AccountsView()
            } label: {
                countRow("Accounts", systemImage: "wallet.bifold", count: activeAccounts.count)
            }
            NavigationLink {
                CategoryListView(kind: .expense)
            } label: {
                countRow(
                    CategoryKind.expense.pluralTitle,
                    systemImage: "tag",
                    count: activeCategories.count { $0.kind == .expense }
                )
            }
            NavigationLink {
                CategoryListView(kind: .income)
            } label: {
                countRow(
                    CategoryKind.income.pluralTitle,
                    systemImage: "banknote",
                    count: activeCategories.count { $0.kind == .income }
                )
            }
        }
    }

    private var displaySection: some View {
        Section {
            Picker("Currency", selection: $symbolStyle) {
                ForEach(CurrencySymbolStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            Picker("Centavos", selection: $centavos) {
                ForEach(CentavoDisplay.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            LabeledContent("Example") {
                // At accessibility sizes the value moves below the label, so it aligns leading.
                VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
                    Text(exampleFormatter.string(Money(minorUnits: 123_450)))
                    Text(exampleFormatter.string(Money(minorUnits: 25_000)))
                }
                .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        } header: {
            Text("Display")
        } footer: {
            Text("Changes how amounts are shown, never the amounts saved.")
        }
    }

    private var preferencesSection: some View {
        Section {
            Picker("Overview Period", selection: $period) {
                ForEach(ReportingPeriod.allCases) { period in
                    Text(period.title).tag(period)
                }
            }
            Toggle("Warn About Possible Duplicates", isOn: $warnsAboutDuplicates)
        } header: {
            Text("Preferences")
        } footer: {
            Text(
                "Ledger asks before saving an entry identical to one saved in the last \(SettingsCopy.duplicateWindow). "
                    + "Identical entries are never discarded automatically."
            )
        }
    }

    // MARK: Helpers

    /// Formats the example amounts with the choices currently selected above.
    private var exampleFormatter: MoneyFormatter {
        MoneyFormatter(preferences: DisplayPreferences(symbolStyle: symbolStyle, centavos: centavos))
    }

    private func countRow(_ title: String, systemImage: String, count: Int) -> some View {
        LabeledContent {
            Text(count, format: .number)
        } label: {
            Label(title, systemImage: systemImage)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(count) active")
    }

    private static func infoValue(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "Unknown"
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
    .ledgerPreview()
}
