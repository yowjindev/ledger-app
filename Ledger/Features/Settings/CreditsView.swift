import SwiftUI

/// Credits shown at the bottom of Settings, under the About section.
///
/// Section footers dim hierarchical styles, so the text uses fixed label colors.
struct CreditsView: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("Vibe Coded with Claude Code")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color.secondary)
            Text(verbatim: "Eugene Clark Eridao")
                .font(.headline)
                .foregroundStyle(Color.primary)
                .padding(.top, 6)
            Text(verbatim: "@yowjin.dev")
                .font(.subheadline)
                .foregroundStyle(.tint)
            ClaudeSpark()
                .frame(width: 44, height: 44)
                .padding(.top, 14)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .accessibilityElement(children: .combine)
    }
}

/// A spark in Claude's orange. Its rays breathe in turn while the whole spark turns slowly, and it
/// holds still when Reduce Motion is on.
struct ClaudeSpark: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let rayCount = 10
    private static let color = Color(red: 217 / 255, green: 119 / 255, blue: 87 / 255)

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let radius = min(size.width, size.height) / 2
                canvas.translateBy(x: size.width / 2, y: size.height / 2)
                canvas.rotate(by: .radians(time * 0.3))
                for index in 0..<Self.rayCount {
                    let turn = Double(index) / Double(Self.rayCount)
                    // A wave of growth that travels around the spark twice per cycle.
                    let breath = 0.92 + 0.08 * sin(time * 2.4 - turn * 4 * .pi)
                    let length = radius * breath * (index.isMultiple(of: 2) ? 1 : 0.8)
                    var ray = canvas
                    ray.rotate(by: .radians(turn * 2 * .pi))
                    ray.fill(
                        Self.rayPath(length: length, baseWidth: radius * 0.2, tipWidth: radius * 0.1),
                        with: .color(Self.color)
                    )
                }
            }
        }
        .shadow(color: Self.color.opacity(0.35), radius: 6)
        .accessibilityHidden(true)
    }

    /// A ray along the x axis that narrows from the center to a rounded tip.
    private static func rayPath(length: CGFloat, baseWidth: CGFloat, tipWidth: CGFloat) -> Path {
        let tipStart = length - tipWidth / 2
        var path = Path()
        path.move(to: CGPoint(x: 0, y: -baseWidth / 2))
        path.addLine(to: CGPoint(x: tipStart, y: -tipWidth / 2))
        path.addQuadCurve(to: CGPoint(x: tipStart, y: tipWidth / 2), control: CGPoint(x: length + tipWidth / 2, y: 0))
        path.addLine(to: CGPoint(x: 0, y: baseWidth / 2))
        path.closeSubpath()
        return path
    }
}

#Preview {
    Form {
        Section {
            LabeledContent("Version", value: "1.0")
        } header: {
            Text("About")
        } footer: {
            CreditsView()
        }
    }
}
