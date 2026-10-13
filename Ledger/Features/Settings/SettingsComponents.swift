import SwiftUI

/// The introduction at the top of a Settings guide: a symbol tile, a title, and a short message.
/// Place it in its own list section; it clears the row background itself.
struct SettingsGuideHeader: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey

    @ScaledMetric(relativeTo: .largeTitle) private var tileSize: CGFloat = 64

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.white)
                .frame(width: min(tileSize, 104), height: min(tileSize, 104))
                .background(Color.accentColor.gradient, in: .rect(cornerRadius: 16, style: .continuous))
                .accessibilityHidden(true)
                .padding(.bottom, 4)
            Text(title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
        .accessibilityElement(children: .combine)
    }
}

/// A guide row: a symbol badge, a title, and an optional detail line.
struct SettingsInfoRow: View {
    let systemImage: String
    var tint: Color = .accentColor
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?

    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 36

    var body: some View {
        HStack(spacing: 14) {
            SymbolBadge(systemName: systemImage, tint: tint, size: min(badgeSize, 60))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// One numbered step of a sequence: a symbol badge, "1. Title", and an optional detail line.
/// Markdown in the detail (for example `**Action Button**`) highlights on-screen names.
struct SettingsStepRow: View {
    let number: Int
    let systemImage: String
    var tint: Color = .accentColor
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?

    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 36

    var body: some View {
        HStack(spacing: 14) {
            SymbolBadge(systemName: systemImage, tint: tint, size: min(badgeSize, 60))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(Text("\(number).").foregroundStyle(tint).monospacedDigit()) \(Text(title))")
                    .font(.body.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

/// A short supporting note with a small symbol, aligned with the text of neighboring
/// `SettingsInfoRow` and `SettingsStepRow` rows.
struct SettingsNoteRow: View {
    let systemImage: String
    let text: LocalizedStringKey

    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 36

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: min(badgeSize, 60))
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Wording shared by more than one Settings screen.
@MainActor
enum SettingsCopy {
    /// How far back Ledger looks for an identical entry before saving, for example "2 minutes".
    static var duplicateWindow: String {
        Duration.seconds(LedgerService.possibleDuplicateWindow)
            .formatted(.units(allowed: [.minutes, .seconds], width: .wide))
    }
}
