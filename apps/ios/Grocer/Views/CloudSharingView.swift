import CloudKit
import UIKit

/// Presents the standard iOS share sheet with a CloudKit share URL so the
/// household owner can invite family members. Anyone with the link can join.
@MainActor
enum ShareSheetPresenter {
    static func present(share: CKShare, container: CKContainer) {
        guard let url = share.url else {
            print("[CloudSharing] share has no URL")
            return
        }
        let groupName = GroceryRepository.current?.currentHousehold?.name ?? "groceries"
        let text = "Join my \(groupName) group on Grocer!"
        let controller = UIActivityViewController(activityItems: [text, url], applicationActivities: nil)

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
