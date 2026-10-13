import SwiftUI

/// A grid of symbols to choose from. The selected symbol is filled with `tint`; VoiceOver reads
/// each symbol's label and marks the selected one.
struct CategorySymbolGrid: View {
    @Binding var selection: String
    let choices: [CategorySymbolChoice]
    var tint: Color = .accentColor

    @ScaledMetric(relativeTo: .title3) private var cellSize: CGFloat = 44

    var body: some View {
        let size = min(cellSize, 76)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: size), spacing: 10)], spacing: 10) {
            ForEach(choices) { choice in
                let isSelected = choice.symbolName == selection
                Button {
                    selection = choice.symbolName
                } label: {
                    Image(systemName: choice.symbolName)
                        .font(.title3)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                        .frame(width: size, height: size)
                        .background(
                            isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(.fill.tertiary),
                            in: Circle()
                        )
                        .overlay {
                            if isSelected {
                                Circle()
                                    .strokeBorder(tint, lineWidth: 2)
                                    .padding(-4)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice.label)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(.vertical, 10)
        .animation(.snappy(duration: 0.2), value: selection)
    }
}
