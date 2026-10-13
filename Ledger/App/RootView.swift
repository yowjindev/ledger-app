import SwiftUI

enum OnboardingState {
    /// `UserDefaults` key set once the user finishes or skips first-run setup.
    static let completedKey = "onboarding.completed"
}

/// Tabs, the shared transaction editor sheet, and first-run onboarding.
struct RootView: View {
    @AppStorage(OnboardingState.completedKey) private var hasCompletedOnboarding = false
    @AppStorage(DisplayPreferences.Keys.symbolStyle) private var symbolStyle: CurrencySymbolStyle = .symbol
    @AppStorage(DisplayPreferences.Keys.centavos) private var centavos: CentavoDisplay = .always
    @State private var router = AppRouter(selectedTab: AppLaunchConfiguration.current.initialTab ?? .dashboard)

    var body: some View {
        TabView(selection: $router.selectedTab) {
            Tab("Overview", systemImage: "chart.pie.fill", value: AppTab.dashboard) {
                NavigationStack {
                    DashboardView()
                        .ledgerRouteDestinations()
                }
            }
            Tab("Activity", systemImage: "list.bullet.rectangle", value: AppTab.transactions) {
                NavigationStack {
                    TransactionListView()
                        .ledgerRouteDestinations()
                }
            }
            Tab("Accounts", systemImage: "wallet.bifold", value: AppTab.accounts) {
                NavigationStack {
                    AccountsView()
                        .ledgerRouteDestinations()
                }
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                NavigationStack {
                    SettingsView()
                        .ledgerRouteDestinations()
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .task {
            if let kind = AppLaunchConfiguration.current.initialEditorKind {
                router.addTransaction(kind)
            }
        }
        .sheet(item: $router.editorRequest) { request in
            TransactionEditorView(request: request)
                .environment(\.moneyFormatter, formatter)
        }
        .fullScreenCover(isPresented: showsOnboarding) {
            OnboardingView {
                hasCompletedOnboarding = true
            }
            .environment(\.moneyFormatter, formatter)
        }
        .environment(router)
        .environment(\.moneyFormatter, formatter)
    }

    private var formatter: MoneyFormatter {
        MoneyFormatter(preferences: DisplayPreferences(symbolStyle: symbolStyle, centavos: centavos))
    }

    private var showsOnboarding: Binding<Bool> {
        Binding(
            get: { !hasCompletedOnboarding && !AppLaunchConfiguration.current.skipsOnboarding },
            set: { isPresented in
                if !isPresented { hasCompletedOnboarding = true }
            }
        )
    }
}
