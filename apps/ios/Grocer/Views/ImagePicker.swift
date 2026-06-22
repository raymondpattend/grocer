import SwiftUI
import UIKit

/// Thin SwiftUI wrapper over `UIImagePickerController` so the add flow can take a
/// live photo of a grocery item (or pick one from the library where no camera is
/// available, e.g. the Simulator). `PhotosPicker` can't drive the camera, so we
/// drop down to UIKit for this one case.
struct ImagePicker: UIViewControllerRepresentable {
    /// Camera when available; falls back to the photo library otherwise.
    static var preferredSourceType: UIImagePickerController.SourceType {
        UIImagePickerController.isSourceTypeAvailable(.camera) ? .camera : .photoLibrary
    }

    var sourceType: UIImagePickerController.SourceType = preferredSourceType
    /// Delivers the picked image, or nil when the user cancels.
    var onPicked: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        // Guard against a stale source type (e.g. camera revoked between launch
        // and presentation) so we never present an unsupported controller.
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(sourceType) ? sourceType : .photoLibrary
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPicked: (UIImage?) -> Void

        init(onPicked: @escaping (UIImage?) -> Void) { self.onPicked = onPicked }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onPicked(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onPicked(nil)
        }
    }
}

extension UIImage {
    /// Downsizes an item photo for storage as a CloudKit asset: aspect-preserving,
    /// bounded to `maxPixelSize` on its longest edge, JPEG-encoded. Keeps the
    /// shared snapshot/outbox JSON and the uploaded asset reasonably small.
    func resizedItemPhotoData(maxPixelSize: CGFloat = 1024,
                              compressionQuality: CGFloat = 0.8) -> Data? {
        guard size.width > 0, size.height > 0 else { return nil }

        let longestEdge = max(size.width, size.height)
        let scale = min(1, maxPixelSize / longestEdge)
        let targetSize = CGSize(width: (size.width * scale).rounded(),
                                height: (size.height * scale).rounded())

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: targetSize, format: format)
            .jpegData(withCompressionQuality: compressionQuality) { _ in
                draw(in: CGRect(origin: .zero, size: targetSize))
            }
    }
}
