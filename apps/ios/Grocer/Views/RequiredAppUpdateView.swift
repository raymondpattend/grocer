import PostHog
import SwiftUI

/// Blocking full-screen cover presented by `RootView` when the running build is
/// below the backend's minimum supported version, routing the shopper to the
/// App Store update.
struct RequiredAppUpdateView: View {
    let update: RequiredAppUpdate
    let openUpdate: () -> Void

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            Image(systemName: "arrow.down.app.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(.green)
                .symbolRenderingMode(.hierarchical)

            VStack(spacing: 10) {
                Text("App Update Required")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)

                Text("This version of Grocer is no longer supported. Install the latest update to keep using the app.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                Haptics.selection()
                openUpdate()
            } label: {
                Label("Update App", systemImage: "arrow.up.forward.app.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.green)

            Text("Current build \(update.currentBuild). Required build \(update.minimumSupportedBuild).")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .postHogScreenView("App Update Required")
    }
}
