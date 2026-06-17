import Foundation
import ImageIO
import SwiftUI
import UIKit

/// Data shared between the Grocer app and the GrocerWidget extension via an App
/// Group container. The home-screen widget runs in a separate process and can't
/// reach the app's CloudKit cache, so the app publishes a lightweight snapshot
/// of each list here and the widget reads it back.
///
/// Keep this file self-contained (no app models) so it compiles cleanly in the
/// widget target — mirror raw string values rather than importing the app's
/// enums, the same convention used by `GroceryActivityAttributes`.

// MARK: - App Group

enum GrocerAppGroup {
    /// Must match the App Group entitlement on both the app and widget targets.
    static let identifier = "group.org.narro.grocer"

    /// Suffix that scopes device-local state (UserDefaults + App Group files) to
    /// the current build environment.
    ///
    /// Debug and Release builds share the same bundle id, so on one device they
    /// share `UserDefaults` and this App Group container. CloudKit, however,
    /// routes Debug builds to its **Development** database and Release builds to
    /// **Production**. Without this split, a prior prod build leaves behind
    /// Production-scoped change tokens and selected-household / member pointers
    /// that a debug build then reuses against the Development database — making
    /// its own trips and stats fail to appear. Keep the two environments'
    /// caches separate so each build sees only its own data.
    #if DEBUG
    static let environmentSuffix = ".debug"
    #else
    static let environmentSuffix = ""
    #endif

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    /// Environment-scoped `UserDefaults`. Use this — never `UserDefaults.standard`
    /// — for anything that mirrors CloudKit state (change tokens, selected
    /// household, member id, subscription flags, device settings) so Debug and
    /// Release builds on the same device don't poison each other's caches.
    static let defaults: UserDefaults = {
        #if DEBUG
        return UserDefaults(suiteName: "org.narro.grocer.debug") ?? .standard
        #else
        return .standard
        #endif
    }()

    /// Appends the environment suffix to an App Group file/directory name so the
    /// Development and Production caches live side by side.
    static func scopedName(_ base: String) -> String {
        base + environmentSuffix
    }
}

/// Base URL for the Worker API. Mirrors `APIClient.baseURLString` so the widget
/// can fill image-cache misses without depending on the app target.
enum GrocerWidgetAPI {
    #if DEBUG
    static let baseURLString = "https://grocer-75.localcan.dev"
    #else
    static let baseURLString = "https://api.grocer.sh"
    #endif
}

// MARK: - Snapshot models

/// One grocery list (a group) as the widget needs to render it.
struct WidgetListSummary: Codable, Hashable, Identifiable {
    /// The group's id (`Household.id`).
    var id: String
    var name: String
    /// SF Symbol name (`Household.icon`).
    var icon: String
    /// `ListColorTheme` raw value (e.g. "green").
    var colorThemeRaw: String
    var storeName: String?
    var pendingCount: Int
    /// Pending item names in display order (capped when published).
    var itemNames: [String]
}

struct WidgetSnapshot: Codable {
    var lists: [WidgetListSummary]
    var generatedAt: Date
}

/// Reads/writes the published snapshot JSON in the App Group container.
enum WidgetSnapshotStore {
    private static var fileName: String { GrocerAppGroup.scopedName("widget-snapshot") + ".json" }

    private static var fileURL: URL? {
        GrocerAppGroup.containerURL?.appendingPathComponent(fileName)
    }

    static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Theme

/// Maps a `ListColorTheme` raw value to a SwiftUI color. Mirrors
/// `ListColorTheme.color` so the widget can theme without the app's models.
func widgetThemeColor(_ raw: String) -> Color {
    switch raw {
    case "blue": return .blue
    case "indigo": return .indigo
    case "purple": return .purple
    case "pink": return .pink
    case "red": return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "teal": return .teal
    case "mint": return .mint
    case "brown": return .brown
    case "gray": return .gray
    default: return .green
    }
}

// MARK: - Image downsampling

/// Decodes `data` to a thumbnail no larger than `maxPixel` on its longest edge,
/// via ImageIO. Live Activities render under a strict memory budget, so loading
/// a full-resolution product image or avatar can silently fail to display —
/// always downsample to the rendered size first. Synchronous and cheap enough
/// for a Live Activity `body`.
func widgetDownsampledImage(from data: Data, maxPixel: CGFloat) -> UIImage? {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: max(maxPixel, 1),
    ]
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }
    return UIImage(cgImage: cg)
}

// MARK: - Shared product images

/// Reads (and, on a miss, fetches) AI-generated product images from the App
/// Group cache that `ProductImageLoader` writes into. Lets the widget show the
/// same food photos the user already loaded in the app.
enum WidgetImageStore {
    /// `<AppGroup>/ProductImages` — the same directory `ProductImageLoader`
    /// caches into, so app-loaded images are visible to the widget.
    static var imagesDirectory: URL? {
        guard let base = GrocerAppGroup.containerURL else { return nil }
        let dir = base.appendingPathComponent(GrocerAppGroup.scopedName("ProductImages"), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Filename scheme MUST match `ProductImageLoader.cacheFile(for:)`.
    static func cacheFileURL(for name: String) -> URL? {
        guard let dir = imagesDirectory else { return nil }
        let safe = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return dir.appendingPathComponent("\(safe).png")
    }

    static func cachedImage(for name: String) -> UIImage? {
        guard let url = cacheFileURL(for: name),
              let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    /// Cached image downsampled to `maxPixel` for memory-constrained renderers
    /// (the Live Activity). Returns nil on a cache miss.
    static func cachedThumbnail(for name: String, maxPixel: CGFloat) -> UIImage? {
        guard let url = cacheFileURL(for: name),
              let data = try? Data(contentsOf: url) else { return nil }
        return widgetDownsampledImage(from: data, maxPixel: maxPixel)
    }

    /// Disk cache first; on a miss, fetch from the product-image endpoint and
    /// persist to the shared cache. Bounded by a short request timeout so it
    /// can't hang the widget timeline.
    static func loadOrFetch(for name: String) async -> UIImage? {
        if let cached = cachedImage(for: name) { return cached }
        let key = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: GrocerWidgetAPI.baseURLString + "/product-image?name=\(encoded)") else {
            return nil
        }
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let img = UIImage(data: data) else { return nil }
            if let fileURL = cacheFileURL(for: key) { try? data.write(to: fileURL, options: .atomic) }
            return img
        } catch {
            return nil
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 6
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
}

// MARK: - Shopper avatar

/// Stores household members' profile images in the App Group, keyed by member
/// id, so the Live Activity (running in the widget process) can render the
/// shopper's picture in place of the generic cart icon — looked up via the
/// activity's `attributes.startedByMemberId`.
///
/// Keying by member id (rather than session id) means a family device that has
/// synced the member roster already has the shopper's avatar cached when a
/// push-to-start arrives, even though the push itself carries no image bytes.
/// Falls back to the cart icon when the avatar isn't cached.
enum WidgetShopperAvatarStore {
    static var directory: URL? {
        guard let base = GrocerAppGroup.containerURL else { return nil }
        let dir = base.appendingPathComponent(GrocerAppGroup.scopedName("ShopperAvatars"), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func sanitize(_ memberId: String) -> String {
        memberId.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression)
    }

    static func fileURL(forMember memberId: String) -> URL? {
        guard let dir = directory, !memberId.isEmpty else { return nil }
        return dir.appendingPathComponent("\(sanitize(memberId)).img")
    }

    static func save(_ imageData: Data, forMember memberId: String) {
        guard let url = fileURL(forMember: memberId) else { return }
        try? imageData.write(to: url, options: .atomic)
    }

    /// Avatar downsampled to `maxPixel` for the memory-constrained Live Activity
    /// renderer. Returns nil when no avatar is cached for the member.
    static func cachedThumbnail(forMember memberId: String, maxPixel: CGFloat) -> UIImage? {
        guard let url = fileURL(forMember: memberId),
              let data = try? Data(contentsOf: url) else { return nil }
        return widgetDownsampledImage(from: data, maxPixel: maxPixel)
    }

    /// Reconciles the cached avatars with the current roster: writes each
    /// member's image (or removes it when they have none) and prunes avatars for
    /// members no longer present. Call when the member roster syncs.
    static func sync(_ avatars: [(memberId: String, imageData: Data?)]) {
        guard let dir = directory else { return }
        let keep = Set(avatars.map { sanitize($0.memberId) })
        for entry in avatars where !entry.memberId.isEmpty {
            let url = dir.appendingPathComponent("\(sanitize(entry.memberId)).img")
            if let data = entry.imageData {
                try? data.write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "img"
            && !keep.contains(file.deletingPathExtension().lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
