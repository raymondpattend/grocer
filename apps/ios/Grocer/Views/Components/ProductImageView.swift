import SwiftUI

/// SwiftUI view that loads and displays a product image with a skeleton shimmer
/// while loading. The image bytes/streaming are served by the `ProductImageLoader`
/// service; this view is the presentation layer for them.
struct ProductImageView: View {
    @Environment(\.displayScale) private var displayScale

    let itemName: String
    var size: CGFloat = 48

    @State private var image: UIImage?
    @State private var isLoading = true

    private struct LoadToken: Equatable {
        var key: String
        var maxPixel: Int
    }

    private var imageKey: String {
        itemName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var loadToken: LoadToken {
        LoadToken(key: imageKey, maxPixel: ProductImageLoader.pixelKey(for: size * displayScale))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .transition(.opacity.animation(.easeIn(duration: 0.2)))
            } else if isLoading {
                ShimmerRect(cornerRadius: 10)
                    .frame(width: size, height: size)
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(.systemGray6))
                    .frame(width: size, height: size)
                    .overlay {
                        FAImage("basket.fill")
                            .foregroundStyle(.tertiary)
                            .font(.system(size: size * 0.35))
                    }
            }
        }
        .accessibilityHidden(true)
        .task(id: loadToken) {
            image = nil
            isLoading = true
            for await frame in ProductImageLoader.shared.imageStream(for: itemName, maxPixel: CGFloat(loadToken.maxPixel)) {
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.2)) { image = frame.image }
                isLoading = !frame.isFinal
            }
            guard !Task.isCancelled else { return }
            isLoading = false
        }
    }
}
