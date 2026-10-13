import SwiftUI

/// The title of a `.borderedProminent` button. It takes the system background color, which
/// reads clearly on the accent color in both appearances: white on the deep emerald of light
/// mode and black on the brighter emerald of dark mode, where white would be too faint.
struct ContrastingButtonTitle: View {
    let title: LocalizedStringKey
    /// Stretches the label so the button spans the available width.
    var fillsWidth = false

    init(_ title: LocalizedStringKey, fillsWidth: Bool = false) {
        self.title = title
        self.fillsWidth = fillsWidth
    }

    var body: some View {
        Text(title)
            .font(.headline)
            .foregroundStyle(.background)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
    }
}
