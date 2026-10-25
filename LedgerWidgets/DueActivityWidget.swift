import ActivityKit
import SwiftUI
import WidgetKit

/// The due reminder Live Activity: on the Lock Screen, in the Dynamic Island, and in the Smart
/// Stack and CarPlay. It names what's due and when, never how much.
struct DueActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DueActivityAttributes.self) { context in
            DueActivityView(lines: context.state.lines)
        } dynamicIsland: { context in
            let lines = context.state.lines
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DueSymbol(line: lines.first)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(ReminderCopy.activityTitle(lines))
                        .font(.headline)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    DueLines(lines: lines, limit: 2)
                }
            } compactLeading: {
                DueSymbol(line: lines.first)
            } compactTrailing: {
                Text(compactText(lines))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(lines.contains(where: \.isOverdue) ? .red : ReminderStyle.accent)
            } minimal: {
                DueSymbol(line: lines.first)
            }
            .keylineTint(ReminderStyle.accent)
        }
        .supplementalActivityFamilies([.small])
    }

    /// "Due", "Late", or a count such as "3 due".
    private func compactText(_ lines: [ReminderLine]) -> String {
        if lines.count > 1 { return "\(lines.count) due" }
        return lines.first?.isOverdue == true ? "Late" : "Due"
    }
}

/// The Lock Screen and banner presentation, or a short one in the Smart Stack and CarPlay.
private struct DueActivityView: View {
    let lines: [ReminderLine]

    @Environment(\.activityFamily) private var family

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.exclamationmark")
                    .foregroundStyle(ReminderStyle.accent)
                Text(ReminderCopy.activityTitle(lines))
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            if family == .medium {
                DueLines(lines: lines, limit: 3)
            } else if let first = lines.first {
                Text(ReminderCopy.line(first))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding()
        .activitySystemActionForegroundColor(ReminderStyle.accent)
    }
}

/// Up to `limit` dues, overdue ones in red with an icon, then how many more there are.
private struct DueLines: View {
    let lines: [ReminderLine]
    let limit: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines.prefix(limit), id: \.ownerKey) { line in
                HStack(spacing: 8) {
                    Image(systemName: line.symbolName)
                        .frame(width: 20)
                        .foregroundStyle(ReminderStyle.accent)
                    Text(line.name)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    HStack(spacing: 3) {
                        if line.isOverdue {
                            Image(systemName: "exclamationmark.circle.fill")
                        }
                        Text(line.dateText)
                    }
                    .font(.subheadline)
                    .foregroundStyle(line.isOverdue ? .red : .secondary)
                }
            }
            if lines.count > limit {
                Text("\(lines.count - limit) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The first due's symbol, red while it's overdue.
private struct DueSymbol: View {
    let line: ReminderLine?

    var body: some View {
        Image(systemName: line?.symbolName ?? "calendar.badge.exclamationmark")
            .foregroundStyle(line?.isOverdue == true ? .red : ReminderStyle.accent)
    }
}
