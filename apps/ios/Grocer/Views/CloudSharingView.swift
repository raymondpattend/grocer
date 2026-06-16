import CloudKit
import UIKit

/// Presents CloudKit's sharing UI so family members are explicit private
/// participants. That matters for removal: public share URLs can be reused by
/// anyone who still has the link, but private participants can be revoked.
@MainActor
enum ShareSheetPresenter {
    private static let delegate = CloudSharingDelegate()

    static func presentInvite(url: URL) {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.setValue(String(localized: "Join my Grocer list"), forKey: "subject")
        present(controller)
    }

    static func present(share: CKShare, container: CKContainer) {
        let controller = UICloudSharingController(share: share, container: container)
        controller.delegate = delegate
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        present(controller)
    }

    private static func present(_ controller: UIViewController) {
        guard let top = topViewController() else { return }

        if let pop = controller.popoverPresentationController {
            pop.sourceView = top.view
            pop.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 60, width: 0, height: 0)
            pop.permittedArrowDirections = []
        }
        top.present(controller, animated: true)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController
            ?? scene?.windows.first?.rootViewController else { return nil }
        while let presented = top.presentedViewController { top = presented }
        return top
    }
}

private final class CloudSharingDelegate: NSObject, UICloudSharingControllerDelegate {
    func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
        print("[CloudSharing] failed to save share: \(error)")
    }

    func itemTitle(for csc: UICloudSharingController) -> String? {
        GroceryRepository.current?.currentHousehold?.name ?? String(localized: "Grocer")
    }

    func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
        print("[CloudSharing] share saved")
    }

    func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
        print("[CloudSharing] stopped sharing")
    }
}
