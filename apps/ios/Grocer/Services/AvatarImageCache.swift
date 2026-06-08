import UIKit
import ImageIO

/// Decodes and downsamples member avatar images off the main thread and caches
/// the result, so avatars are never re-decoded inside a SwiftUI `body` pass.
///
/// Profile images are stored at up to 512×512 but rendered tiny (≈28pt). Decoding
/// the full JPEG on every body evaluation — which happens on every keystroke while
/// a list is on screen — stalls the main thread and causes severe typing lag.
/// This cache decodes straight to the display size via ImageIO and reuses the
/// result, keyed by image content so a changed photo is picked up automatically.
actor AvatarImageCache {
    static let shared = AvatarImageCache()

    private var cache: [Int: UIImage] = [:]

    /// Returns a thumbnail decoded at roughly `maxPixel` on its longest edge.
    /// Runs off the main actor; the expensive decode happens here, not in `body`.
    func thumbnail(for data: Data, maxPixel: CGFloat) -> UIImage? {
        var hasher = Hasher()
        hasher.combine(data)
        hasher.combine(Int(maxPixel))
        let key = hasher.finalize()

        if let cached = cache[key] { return cached }

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

        let image = UIImage(cgImage: cg)
        cache[key] = image
        return image
    }
}
