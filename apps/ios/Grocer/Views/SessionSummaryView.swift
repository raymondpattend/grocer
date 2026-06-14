import SwiftUI

/// Shown after the shopper taps Finish Shopping. Summarizes the trip and lets
/// the user clean up the list.
struct SessionSummaryView: View {
    @Environment(GroceryRepository.self) private var repo

    let session: ShoppingSession
    let onDone: () -> Void

    @State private var clearCompleted = true
    @State private var keepOutOfStock = true
    @State private var finished = false

    private var progress: SessionProgress { repo.progress(for: session) }

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("Shopping Complete")
                        .font(.title2.bold())
                    if let store = session.storeName {
                        Text(store).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical)
                .listRowBackground(Color.clear)
            }

            Section("Summary") {
                summaryRow(String(localized: "Found"), progress.found, systemImage: "checkmark.circle.fill", tint: .green)
                summaryRow(String(localized: "Replaced"), progress.replaced, systemImage: "arrow.triangle.2.circlepath.circle.fill", tint: .blue)
                summaryRow(String(localized: "Out of stock"), progress.outOfStock, systemImage: "xmark.circle.fill", tint: .red)
                summaryRow(String(localized: "Skipped"), progress.skipped, systemImage: "arrow.uturn.forward.circle.fill", tint: .orange)
            }

            Section("Cleanup") {
                Toggle("Clear completed items", isOn: $clearCompleted)
                    .onChange(of: clearCompleted) { _, _ in Haptics.selection() }
                Toggle("Keep out-of-stock items for next trip", isOn: $keepOutOfStock)
                    .onChange(of: keepOutOfStock) { _, _ in Haptics.selection() }
            }
        }
        .navigationTitle("Trip Summary")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .safeAreaInset(edge: .bottom) {
            Button {
                Haptics.success()
                if !finished {
                    finished = true
                    // Finish runs without blocking; the APNs end push is fire-and-forget.
                    Task { await repo.finishShopping(session, clearCompleted: clearCompleted, keepOutOfStock: keepOutOfStock) }
                }
                onDone()
            } label: {
                Text("Done")
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
            .background(.bar)
        }
    }

    private func summaryRow(_ title: String, _ count: Int, systemImage: String, tint: Color) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, tint)
            Spacer()
            Text("\(count)").bold().monospacedDigit()
        }
    }
}
