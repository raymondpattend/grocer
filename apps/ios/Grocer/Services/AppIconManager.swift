import UIKit

/// A selectable home-screen app icon.
///
/// `default` is the primary icon (no alternate name). Additional icons are
/// alternate icons declared in the asset catalog via
/// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES` and applied at runtime with
/// `UIApplication.setAlternateIconName`.
enum AppIcon: String, CaseIterable, Identifiable {
    case `default`
    case cart

    var id: String { rawValue }

    /// The alternate icon name passed to `setAlternateIconName`. `nil` restores
    /// the primary icon. Must match an entry in the asset catalog /
    /// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`.
    var alternateIconName: String? {
        switch self {
        case .default: return nil
        case .cart: return "AppIconCart"
        }
    }

    /// Image set used to render the option's preview tile in Preferences.
    var previewImageName: String {
        switch self {
        case .default: return "PreferencesAppIcon"
        case .cart: return "CartAppIconPreview"
        }
    }

    var localizedName: String {
        switch self {
        case .default: return String(localized: "Default")
        case .cart: return String(localized: "Midnight")
        }
    }

    /// Whether choosing this icon requires an active Grocer Pro subscription.
    var requiresPro: Bool {
        switch self {
        case .default: return false
        case .cart: return true
        }
    }
}

/// Reads and applies the current home-screen icon.
@MainActor
enum AppIconManager {
    static var supportsAlternateIcons: Bool {
        UIApplication.shared.supportsAlternateIcons
    }

    /// The icon currently in use, derived from the live alternate-icon name.
    static var current: AppIcon {
        let name = UIApplication.shared.alternateIconName
        return AppIcon.allCases.first { $0.alternateIconName == name } ?? .default
    }

    /// Applies `icon`, no-op if it is already active. iOS shows its own
    /// "You have changed the icon" confirmation alert.
    static func set(_ icon: AppIcon) async {
        guard supportsAlternateIcons, current != icon else { return }
        do {
            try await UIApplication.shared.setAlternateIconName(icon.alternateIconName)
        } catch {
            print("[AppIcon] Failed to set \(icon.rawValue): \(error)")
        }
    }
}
