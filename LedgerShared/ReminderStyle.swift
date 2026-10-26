import SwiftUI
import UIKit

/// Colors shared by the app and the widget extension, which can't read the app's asset catalog.
enum ReminderStyle {
    /// The app's accent color: emerald, a little brighter in dark mode.
    static let accent = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.071, green: 0.600, blue: 0.482, alpha: 1)
            : UIColor(red: 0.055, green: 0.486, blue: 0.400, alpha: 1)
    })
}
