import Foundation

/// Maps the SF Symbols the app historically used to their closest Font Awesome
/// "Jelly" equivalent (name + family). Used both to render legacy/dynamic icon
/// strings through `FAImage` and to migrate persisted icon names to FA names.
///
/// A handful of grocery-specific SF Symbols have no exact match in the bundled
/// Jelly kit (basket, carrot, popcorn, comb, takeout bag); those fall back to
/// the nearest available icon and are marked below.
enum FASymbolMap {
    struct Entry {
        let name: String
        let family: FAFamily
        init(_ name: String, _ family: FAFamily) { self.name = name; self.family = family }
    }

    /// SF Symbol name -> Font Awesome (name, family).
    static let table: [String: Entry] = [
        // Arrows / refresh / navigation
        "arrow.counterclockwise": Entry("arrow-rotate-left", .jelly),
        "arrow.down.app.fill": Entry("arrow-down-to-line", .fill),
        "arrow.triangle.2.circlepath": Entry("arrows-rotate", .jelly),
        "arrow.triangle.2.circlepath.circle.fill": Entry("arrows-rotate", .fill),
        "arrow.up.arrow.down": Entry("sort", .jelly),
        "arrow.up.forward.app.fill": Entry("arrow-up-right-from-square", .fill),
        "arrow.uturn.backward": Entry("arrow-rotate-left", .jelly),
        "arrow.uturn.forward": Entry("arrow-rotate-right", .jelly),
        "arrow.uturn.forward.circle.fill": Entry("arrow-rotate-right", .fill),
        "chevron.backward": Entry("angle-left", .jelly),
        "chevron.left": Entry("angle-left", .jelly),
        "chevron.right": Entry("angle-right", .jelly),
        "chevron.up.chevron.down": Entry("sort", .jelly),
        "keyboard.chevron.compact.down": Entry("angle-down", .jelly),
        "line.3.horizontal": Entry("bars", .jelly),
        "square.grid.2x2": Entry("grid", .jelly),
        "slider.horizontal.3": Entry("sliders", .jelly),
        "rectangle.portrait.and.arrow.right": Entry("arrow-right-from-bracket", .jelly),
        "square.and.arrow.up": Entry("arrow-up-from-bracket", .jelly),
        "tray.and.arrow.up": Entry("arrow-up-from-bracket", .jelly),
        "square.stack.3d.up.fill": Entry("layer-group", .fill),

        // Checks / marks / status
        "check": Entry("check", .jelly),
        "checkmark": Entry("check", .jelly),
        "checkmark.circle": Entry("circle-check", .jelly),
        "checkmark.circle.fill": Entry("circle-check", .fill),
        "checkmark.seal.fill": Entry("circle-check", .fill),
        "circle": Entry("circle", .jelly),
        "circle.dashed": Entry("circle", .jelly),
        "circle.lefthalf.filled": Entry("circle-half-stroke", .jelly),
        "xmark": Entry("xmark", .jelly),
        "xmark.circle.fill": Entry("circle-xmark", .fill),
        "plus": Entry("plus", .jelly),
        "plus.circle.dashed": Entry("circle-plus", .jelly),
        "plus.circle.fill": Entry("circle-plus", .fill),
        "minus": Entry("minus", .jelly),
        "info.circle": Entry("circle-info", .jelly),
        "exclamationmark.triangle.fill": Entry("triangle-exclamation", .fill),
        "exclamationmark.icloud": Entry("triangle-exclamation", .jelly),
        "ellipsis.circle": Entry("ellipsis", .jelly),
        "flag.checkered": Entry("flag", .jelly),
        "bolt.fill": Entry("bolt", .fill),
        "bolt.horizontal.circle": Entry("bolt", .jelly),

        // Cart / shop / bags
        "cart": Entry("cart-shopping", .jelly),
        "cart.fill": Entry("cart-shopping", .fill),
        "cart.badge.plus": Entry("cart-shopping", .jelly),
        "cart.badge.minus": Entry("cart-shopping", .jelly),
        "cart.fill.badge.plus": Entry("cart-shopping", .fill),
        "basket.fill": Entry("cart-shopping", .fill), // no basket in kit
        "bag": Entry("bag-shopping", .jelly),
        "bag.fill": Entry("bag-shopping", .fill),
        "takeoutbag.and.cup.and.straw.fill": Entry("bag-shopping", .fill), // no takeout bag
        "storefront": Entry("shop", .jelly),
        "storefront.fill": Entry("shop", .fill),
        "creditcard": Entry("credit-card", .jelly),
        "dollarsign.circle": Entry("money-bill", .jelly),

        // Food / grocery categories
        "fork.knife": Entry("utensils", .jelly),
        "carrot.fill": Entry("leaf", .fill), // no carrot in kit
        "leaf": Entry("leaf", .jelly),
        "leaf.fill": Entry("leaf", .fill),
        "fish": Entry("fish", .jelly),
        "fish.fill": Entry("fish", .fill),
        "drop": Entry("droplet", .jelly),
        "snowflake": Entry("snowflake", .jelly),
        "archivebox": Entry("box-archive", .jelly),
        "shippingbox.fill": Entry("box", .fill),
        "birthday.cake": Entry("cake-candles", .jelly),
        "birthday.cake.fill": Entry("cake-candles", .fill),
        "cup.and.saucer": Entry("mug-hot", .jelly),
        "cup.and.saucer.fill": Entry("mug-hot", .fill),
        "wineglass.fill": Entry("martini-glass", .fill),
        "popcorn": Entry("bag-shopping", .jelly), // no snack icon in kit
        "comb": Entry("scissors", .jelly), // no comb in kit; grooming
        "pawprint": Entry("paw", .jelly),
        "pawprint.fill": Entry("paw", .fill),
        "house": Entry("house", .jelly),
        "house.fill": Entry("house", .fill),
        "gift.fill": Entry("gift", .fill),
        "heart.fill": Entry("heart", .fill),

        // People
        "person.2": Entry("users", .jelly),
        "person.2.fill": Entry("users", .fill),
        "person.3.fill": Entry("users", .fill),
        "person.crop.circle.fill": Entry("circle-user", .fill),
        "person.crop.circle.fill.badge.plus": Entry("circle-user", .fill),
        "person.crop.circle.badge.plus": Entry("circle-user", .jelly),
        "person.crop.circle.badge.questionmark": Entry("circle-user", .jelly),
        "person.crop.circle.badge.xmark": Entry("circle-user", .jelly),

        // Camera / media
        "camera.fill": Entry("camera", .fill),
        "camera.circle.fill": Entry("camera", .fill),
        "photo": Entry("image", .jelly),

        // Bells / notifications
        "bell.badge": Entry("bell", .jelly),
        "bell.badge.fill": Entry("bell", .fill),
        "bell.and.waves.left.and.right": Entry("bell", .jelly),
        "bell.and.waves.left.and.right.fill": Entry("bell", .fill),

        // Editing / tools
        "pencil": Entry("pencil", .jelly),
        "trash": Entry("trash", .jelly),
        "trash.fill": Entry("trash", .fill),
        "trash.circle.fill": Entry("trash", .fill),
        "paintbrush": Entry("palette", .jelly),
        "paintbrush.fill": Entry("palette", .fill),
        "gearshape": Entry("gear", .jelly),
        "link": Entry("link", .jelly),
        "doc.on.clipboard": Entry("clipboard", .jelly),
        "note.text": Entry("file", .jelly),
        "checklist": Entry("list", .jelly),
        "list.bullet": Entry("list", .jelly),
        "list.bullet.rectangle.portrait": Entry("list", .jelly),

        // Search / lock / misc
        "magnifyingglass": Entry("magnifying-glass", .jelly),
        "lock.fill": Entry("lock", .fill),
        "lock.open": Entry("lock-open", .jelly),
        "sparkle": Entry("sparkles", .jelly),
        "sparkles": Entry("sparkles", .jelly),
        "lightbulb": Entry("lightbulb", .jelly),
        "crown.fill": Entry("crown", .fill),
        "star.fill": Entry("star", .fill),
        "hand.draw": Entry("hand", .jelly),
        "wifi.slash": Entry("wifi-slash", .jelly),

        // Time
        "clock.arrow.circlepath": Entry("clock", .jelly),

        // Cloud
        "icloud.and.arrow.down": Entry("arrow-down-to-line", .jelly),
        "icloud.slash": Entry("cloud", .jelly),

        // Pins / location
        "pin": Entry("thumbtack", .jelly),
        "pin.fill": Entry("thumbtack", .fill),
        "pin.slash": Entry("thumbtack", .jelly),
        "mappin": Entry("location-dot", .fill),
        "mappin.and.ellipse": Entry("location-dot", .jelly),
        "location.fill.viewfinder": Entry("location-dot", .fill),
    ]

    /// Resolves any icon string to a Font Awesome (name, family). Accepts SF
    /// Symbol names (mapped via `table`), Font Awesome names/aliases (passed
    /// through as `.fill`), and unknown strings (rendered as a placeholder).
    static func resolve(_ name: String) -> (name: String, family: FAFamily) {
        if let e = table[name] { return (e.name, e.family) }
        if FAIcons.glyphs[name] != nil { return (name, .fill) }
        return (name, .fill)
    }

    /// Full resolution used by the renderers: Classic overrides first (chevron,
    /// minus, xmark, plus), otherwise the SF→Jelly mapping.
    static func effective(_ name: String) -> (name: String, family: FAFamily) {
        if let classic = classicOverride(name) { return (classic, .classic) }
        return resolve(name)
    }

    /// Font Awesome name for a persisted SF Symbol string (migration helper).
    /// Returns the input unchanged if it is already a Font Awesome name.
    static func faName(for stored: String) -> String {
        if let e = table[stored] { return e.name }
        return stored
    }

    /// Icons rendered from the Font Awesome **Classic Solid** family instead of
    /// Jelly — the chevron, minus, xmark, and plus families, per product
    /// direction. Returns the Classic FA icon name, or nil to render Jelly.
    static func classicOverride(_ name: String) -> String? {
        switch name {
        case "chevron.left", "chevron.backward": return "chevron-left"
        case "chevron.right", "chevron.forward": return "chevron-right"
        case "chevron.up": return "chevron-up"
        case "chevron.down", "keyboard.chevron.compact.down": return "chevron-down"
        case "chevron.up.chevron.down": return "sort"
        case "xmark.circle.fill", "xmark.circle": return "circle-xmark"
        case "plus.circle.fill", "plus.circle", "plus.circle.dashed": return "circle-plus"
        default: break
        }
        if name == "xmark" || name == "minus" || name == "plus" { return name }
        if name.hasPrefix("chevron.") { return "chevron-right" } // any other chevron
        return nil
    }
}
