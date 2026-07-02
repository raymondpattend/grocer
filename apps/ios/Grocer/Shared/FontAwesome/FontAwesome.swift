import SwiftUI
import CoreText
import UIKit

// MARK: - Families

/// The three Font Awesome "Jelly" families bundled with the app. Each is a
/// separate OTF registered at runtime from the target bundle.
enum FAFamily: CaseIterable {
    case jelly      // regular outline-weight
    case fill       // solid fill
    case duo        // duotone (two stacked layers)
    case classic    // Classic Pro Solid (used for chevrons, minus, xmark, plus)

    var postScriptName: String {
        switch self {
        case .jelly: return "FontAwesome7Jelly-Regular"
        case .fill: return "FontAwesome7JellyFill-Regular"
        case .duo: return "FontAwesome7JellyDuo-Regular"
        case .classic: return "FontAwesome7Pro-Solid"
        }
    }

    fileprivate var fileName: String {
        switch self {
        case .jelly: return "FontAwesome7Jelly-Regular"
        case .fill: return "FontAwesome7JellyFill-Regular"
        case .duo: return "FontAwesome7JellyDuo-Regular"
        case .classic: return "FontAwesome7Pro-Solid"
        }
    }
}

// MARK: - Registration

enum FontAwesome {
    private static let registerOnce: Void = {
        for family in FAFamily.allCases {
            // Fonts are normally registered by the system via UIAppFonts; only
            // register at runtime if that hasn't happened (e.g. an unexpected
            // bundle layout), skipping ones already available.
            if UIFont(name: family.postScriptName, size: 1) != nil { continue }
            guard let url = Bundle.main.url(forResource: family.fileName, withExtension: "otf"),
                  let data = try? Data(contentsOf: url),
                  let provider = CGDataProvider(data: data as CFData),
                  let font = CGFont(provider) else { continue }
            CTFontManagerRegisterGraphicsFont(font, nil)
        }
    }()

    /// Registers the bundled Jelly fonts. Safe to call repeatedly; runs once.
    static func register() { _ = registerOnce }

    /// Duotone secondary-layer scalar for a primary scalar.
    static let duoSecondaryOffset: UInt32 = 0x100000

    /// Resolves a Font Awesome icon name (or alias) to its primary scalar,
    /// falling back to a visible placeholder if unknown.
    static func scalar(for name: String) -> UInt32 {
        FAIcons.glyphs[name] ?? FAIcons.glyphs["circle-question"] ?? 0x3F
    }

    /// Renders an icon glyph to a `UIImage` (for UIKit surfaces such as
    /// `MKMarkerAnnotationView.glyphImage`). Accepts SF Symbol or FA names.
    static func uiImage(_ name: String,
                        size: CGFloat = 22,
                        color: UIColor = .white,
                        family: FAFamily? = nil) -> UIImage? {
        register()
        let resolved = FASymbolMap.effective(name)
        let fam = family ?? resolved.family
        guard let font = UIFont(name: fam.postScriptName, size: size) else { return nil }
        let glyph = String(UnicodeScalar(scalar(for: resolved.name)) ?? UnicodeScalar(0x3F)!)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let bounds = (glyph as NSString).size(withAttributes: attrs)
        let renderer = UIGraphicsImageRenderer(size: bounds)
        return renderer.image { _ in
            (glyph as NSString).draw(at: .zero, withAttributes: attrs)
        }.withRenderingMode(.alwaysTemplate)
    }
}

// MARK: - Sizing

extension Font.TextStyle {
    /// Nominal (unscaled) point size used to size a Font Awesome glyph so it
    /// tracks Dynamic Type the way an SF Symbol would at the same text style.
    var faBaseSize: CGFloat {
        switch self {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline, .body, .callout: return 17
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        @unknown default: return 17
        }
    }
}

// MARK: - FAImage

/// Drop-in replacement for `Image(systemName:)` that renders a bundled Font
/// Awesome Jelly glyph. Tints follow the ambient `foregroundStyle`, and size
/// tracks Dynamic Type relative to `textStyle` (or a fixed `size` when given).
struct FAImage: View {
    private let scalar: UInt32
    private let family: FAFamily
    private let size: CGFloat?
    private let textStyle: Font.TextStyle
    private let secondaryOpacity: Double

    /// - Parameters:
    ///   - name: An SF Symbol name (e.g. `"cart.fill"`) or a Font Awesome icon
    ///     name/alias (e.g. `"cart-shopping"`). SF names are resolved to their
    ///     Jelly equivalent; the default family also comes from that mapping.
    ///     Chevrons, minus, xmark, and plus resolve to the Classic Solid family.
    ///   - family: Overrides the resolved family when non-nil.
    ///   - size: Fixed point size. When nil, scales with Dynamic Type.
    ///   - textStyle: Text style the glyph scales relative to (and its base size).
    ///   - secondaryOpacity: Opacity of the duotone secondary layer (`.duo` only).
    init(_ name: String,
         family: FAFamily? = nil,
         size: CGFloat? = nil,
         relativeTo textStyle: Font.TextStyle = .body,
         secondaryOpacity: Double = 0.4) {
        let resolved = FASymbolMap.effective(name)
        self.scalar = FontAwesome.scalar(for: resolved.name)
        self.family = family ?? resolved.family
        self.size = size
        self.textStyle = textStyle
        self.secondaryOpacity = secondaryOpacity
        FontAwesome.register()
    }

    private var font: Font {
        if let size {
            return .custom(family.postScriptName, fixedSize: size)
        }
        return .custom(family.postScriptName, size: textStyle.faBaseSize, relativeTo: textStyle)
    }

    private func glyph(_ scalar: UInt32) -> String {
        String(UnicodeScalar(scalar) ?? UnicodeScalar(0x3F)!)
    }

    var body: some View {
        Group {
            if family == .duo, FAIcons.duotoneScalars.contains(scalar) {
                ZStack {
                    Text(glyph(scalar + FontAwesome.duoSecondaryOffset))
                        .opacity(secondaryOpacity)
                    Text(glyph(scalar))
                }
                .font(font)
            } else {
                Text(glyph(scalar)).font(font)
            }
        }
    }
}

// MARK: - FALabel

/// Replacement for `Label(_, systemImage:)` using a Font Awesome glyph. The
/// initializers mirror SwiftUI's `Label(_:systemImage:)` so call sites convert
/// by swapping `Label(` → `FALabel(` and `systemImage:` → `icon:`.
struct FALabel<Title: View>: View {
    private let icon: FAImage
    private let title: Title

    init(_ titleKey: LocalizedStringKey,
         icon name: String,
         family: FAFamily? = nil) where Title == Text {
        self.icon = FAImage(name, family: family)
        self.title = Text(titleKey)
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S,
                            icon name: String,
                            family: FAFamily? = nil) where Title == Text {
        self.icon = FAImage(name, family: family)
        self.title = Text(title)
    }

    init(icon name: String,
         family: FAFamily? = nil,
         @ViewBuilder title: () -> Title) {
        self.icon = FAImage(name, family: family)
        self.title = title()
    }

    var body: some View {
        Label { title } icon: { icon }
    }
}
