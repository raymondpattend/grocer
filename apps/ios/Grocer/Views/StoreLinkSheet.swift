import CoreLocation
import MapKit
import PostHog
import SwiftUI
import UIKit

/// Geofence radius presets surfaced to the user, mirroring the "Small / Medium /
/// Large" control in Find My.
private enum GeofenceSize: String, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }

    var meters: Double {
        switch self {
        case .small: return 128
        case .medium: return 255
        case .large: return 425
        }
    }

    var label: String {
        switch self {
        case .small: return String(localized: "Small")
        case .medium: return String(localized: "Medium")
        case .large: return String(localized: "Large")
        }
    }

    static func closest(to meters: Double) -> GeofenceSize {
        allCases.min(by: { abs($0.meters - meters) < abs($1.meters - meters) }) ?? .small
    }
}

/// Sets up an arrival reminder for the current list: explains the feature, requires
/// Always location permission, then lets the member pick the store on a Find My–style
/// map before linking it on the shared `Household` record and opting this member in.
struct StoreLinkSheet: View {
    @Environment(GroceryRepository.self) private var repo
    @Environment(\.dismiss) private var dismiss

    /// Observed so the flow reacts when the permission prompt resolves.
    private let reminders = StoreReminderManager.shared

    private enum Step { case intro, picker }
    @State private var step: Step = .intro

    @State private var visibleRegion: MKCoordinateRegion?
    @State private var lastSearchCenter: CLLocationCoordinate2D?
    @State private var nearby: [StoreCandidate] = []
    @State private var searchText = ""
    @State private var selected: StoreCandidate?
    @State private var size: GeofenceSize = .medium
    @State private var isSearching = false
    @State private var requestingPermission = false
    @State private var searchDebounce: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    var body: some View {
        ZStack {
            if step == .intro {
                intro
                    .transition(.move(edge: .leading).combined(with: .opacity))
            } else {
                picker
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.34), value: step)
        .presentationDetents(step == .intro ? [.height(350)] : [.large])
        .presentationDragIndicator(.visible)
        // Require *Always* before revealing the map.
        .onChange(of: reminders.authorizationStatus) { _, status in
            guard requestingPermission else { return }
            if status == .authorizedAlways {
                requestingPermission = false
                withAnimation(.snappy(duration: 0.34)) { step = .picker }
            } else if status != .notDetermined {
                // They answered, but not with Always — drop the spinner so the
                // intro can show the next step (upgrade prompt / Settings).
                requestingPermission = false
            }
        }
    }

    // MARK: - Intro

    private var intro: some View {
        VStack(spacing: 22) {
            HStack {
                Spacer()
                closeButton
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            Image(systemName: "bell.and.waves.left.and.right.fill")
                .font(.system(size: 46, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 92, height: 92)
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("Remember at the store")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Pick a store and Grocer will nudge you when you arrive.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 28)

            Spacer(minLength: 0)
        }
        .safeAreaInset(edge: .bottom) {
            introFooter
        }
    }

    private var introFooter: some View {
        Button(action: introPrimaryAction) {
            Group {
                if requestingPermission {
                    ProgressView().tint(.white)
                } else {
                    Text(introPrimaryTitle)
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 40)
        }
        .grocerGlassButton(prominent: true)
        .controlSize(.large)
        .tint(tint)
        .disabled(requestingPermission)
        .padding(.horizontal, 20)
        .padding(.top, 32)
        .padding(.bottom, 8)
    }

    private var introPrimaryTitle: String {
        switch reminders.authorizationStatus {
        case .denied, .restricted: return String(localized: "Open Settings")
        case .authorizedWhenInUse: return String(localized: "Allow Always Access")
        default: return String(localized: "Continue")
        }
    }

    private func introPrimaryAction() {
        Haptics.selection()
        switch reminders.authorizationStatus {
        case .authorizedAlways:
            withAnimation(.snappy(duration: 0.34)) { step = .picker }
        case .denied, .restricted:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        default:
            // notDetermined → first prompt; whenInUse → the Always upgrade prompt.
            requestingPermission = true
            reminders.requestAlwaysAuthorization()
            // Safety net: if iOS shows no prompt (e.g. already asked), clear the
            // spinner so the button doesn't hang.
            Task {
                try? await Task.sleep(for: .seconds(3))
                if requestingPermission { requestingPermission = false }
            }
        }
    }

    // MARK: - Picker

    private var picker: some View {
        ZStack(alignment: .top) {
            mapView.ignoresSafeArea()
            // Chrome lives in the safe area so it clears the status bar / Dynamic
            // Island while the map stays full-bleed behind it.
            VStack(spacing: 10) {
                pickerHeader
                searchHereButton
                Spacer(minLength: 0)
            }
        }
        .safeAreaInset(edge: .bottom) { pickerBottomBar }
    }

    private var mapView: some View {
        StorePickerMapView(
            candidates: nearby,
            selected: $selected,
            radius: size.meters,
            visibleRegion: $visibleRegion
        ) {
            if nearby.isEmpty { performSearch() }
        }
    }

    private var pickerHeader: some View {
        ZStack {
            Text("Pick the Store")
                .font(.headline.weight(.semibold))
                .shadow(color: .black.opacity(0.18), radius: 3)

            HStack {
                Button {
                    Haptics.tap()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                        .modifier(GlassCircle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel")

                Spacer()

                Button(action: confirm) {
                    Image(systemName: "checkmark")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background {
                            Circle().fill(selected == nil ? Color.gray.opacity(0.55) : Color.blue)
                        }
                        .modifier(GlassCircle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(selected == nil)
                .accessibilityLabel("Confirm store")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
    }

    /// Apple Maps–style "search this area" pill, shown after the map is panned
    /// away from the last results.
    @ViewBuilder
    private var searchHereButton: some View {
        if showSearchHere {
            Button {
                Haptics.tap()
                searchFocused = false
                performSearch()
            } label: {
                HStack(spacing: 6) {
                    if isSearching {
                        ProgressView().controlSize(.mini)
                            .tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text("Search This Area").fontWeight(.semibold)
                }
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
            }
            .modifier(GlassCapsule())
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var pickerBottomBar: some View {
        HStack(spacing: 10) {
            sizeMenu
            searchField
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var sizeMenu: some View {
        Menu {
            Picker("Reminder size", selection: $size) {
                ForEach(GeofenceSize.allCases) { Text($0.label).tag($0) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(size.label).fontWeight(.semibold)
                Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .modifier(GlassCapsule())
        }
        .accessibilityLabel("Reminder radius size")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $searchText)
                .textInputAutocapitalization(.words)
                .submitLabel(.search)
                .focused($searchFocused)
                .onSubmit(performSearch)
            if isSearching {
                ProgressView().controlSize(.mini)
            } else if !searchText.isEmpty {
                Button {
                    searchText = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .modifier(GlassCapsule())
        .onChange(of: searchText) { _, _ in scheduleSearch() }
    }

    private var showSearchHere: Bool {
        guard let visibleRegion, let lastSearchCenter else { return false }
        let moved = CLLocation(latitude: visibleRegion.center.latitude, longitude: visibleRegion.center.longitude)
            .distance(from: CLLocation(latitude: lastSearchCenter.latitude, longitude: lastSearchCenter.longitude))
        return moved > 600
    }

    // MARK: - Actions

    private var tint: Color { repo.currentHousehold?.tint ?? .accentColor }

    /// Debounce live searches so editing the field re-queries without firing on
    /// every keystroke.
    private func scheduleSearch() {
        searchDebounce?.cancel()
        searchDebounce = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            performSearch()
        }
    }

    private func performSearch() {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText.trimmingCharacters(in: .whitespaces).isEmpty
            ? String(localized: "grocery store")
            : searchText
        if let visibleRegion { request.region = visibleRegion }
        request.resultTypes = .pointOfInterest
        lastSearchCenter = visibleRegion?.center

        isSearching = true
        Task {
            let response = try? await MKLocalSearch(request: request).start()
            await MainActor.run {
                isSearching = false
                nearby = StoreCandidate.deduped(response?.mapItems ?? [], limit: 30)
                if let current = selected, !nearby.contains(current) {
                    selected = nil
                }
            }
        }
    }

    private func confirm() {
        guard let selected else { return }
        Haptics.success()
        repo.linkStore(
            latitude: selected.coordinate.latitude,
            longitude: selected.coordinate.longitude,
            radius: size.meters,
            name: selected.name
        )
        PostHogSDK.shared.capture("store_linked", properties: [
            "group_name": repo.currentHousehold?.name ?? "",
            "radius_m": Int(size.meters),
            "size": size.rawValue,
        ])
        dismiss()
    }

    private var closeButton: some View {
        Button {
            Haptics.tap()
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .modifier(GlassCircle())
        }
        .buttonStyle(.plain)
        .tint(.primary)
        .accessibilityLabel("Close")
    }
}

// MARK: - Glass helpers

/// Liquid-glass capsule on iOS 26+, material fallback below.
private struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        content.background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1) }
    }
}

/// Liquid-glass circle on iOS 26+, material fallback below.
private struct GlassCircle: ViewModifier {
    func body(content: Content) -> some View {
        content.background(.ultraThinMaterial, in: Circle())
    }
}

// MARK: - Pins & candidates

private struct StorePickerMapView: UIViewRepresentable {
    let candidates: [StoreCandidate]
    @Binding var selected: StoreCandidate?
    let radius: CLLocationDistance
    @Binding var visibleRegion: MKCoordinateRegion?
    let onRegionReady: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView(frame: .zero)
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.showsCompass = true
        mapView.userTrackingMode = .follow
        mapView.register(
            MKMarkerAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: StoreCandidateAnnotation.reuseIdentifier
        )
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncAnnotations(on: mapView)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: StorePickerMapView
        private var isSyncingSelection = false
        private var radiusOverlay: MKCircle?

        init(_ parent: StorePickerMapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region
            DispatchQueue.main.async {
                self.parent.visibleRegion = region
                if self.parent.candidates.isEmpty {
                    self.parent.onRegionReady()
                }
            }
        }

        func mapView(_ mapView: MKMapView, didSelect annotation: MKAnnotation) {
            guard !isSyncingSelection,
                  let annotation = annotation as? StoreCandidateAnnotation else { return }
            Haptics.selection()
            parent.selected = annotation.candidate
            syncRadiusOverlay(on: mapView)
        }

        func mapView(_ mapView: MKMapView, didDeselect annotation: MKAnnotation) {
            guard !isSyncingSelection,
                  let annotation = annotation as? StoreCandidateAnnotation,
                  parent.selected?.id == annotation.candidate.id else { return }
            parent.selected = nil
            syncRadiusOverlay(on: mapView)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? StoreCandidateAnnotation else { return nil }
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: StoreCandidateAnnotation.reuseIdentifier,
                for: annotation
            ) as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(
                annotation: annotation,
                reuseIdentifier: StoreCandidateAnnotation.reuseIdentifier
            )
            view.annotation = annotation
            view.canShowCallout = false
            view.titleVisibility = .visible
            view.subtitleVisibility = .hidden
            view.displayPriority = .required
            view.animatesWhenAdded = false
            style(view, selected: annotation.candidate.id == parent.selected?.id)
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard overlay is MKCircle else {
                return MKOverlayRenderer(overlay: overlay)
            }

            let renderer = MKCircleRenderer(overlay: overlay)
            renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.16)
            renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.62)
            renderer.lineWidth = 2
            return renderer
        }

        func syncAnnotations(on mapView: MKMapView) {
            let existing = mapView.annotations.compactMap { $0 as? StoreCandidateAnnotation }
            let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.candidate.id, $0) })
            let candidateIDs = Set(parent.candidates.map(\.id))

            let stale = existing.filter { !candidateIDs.contains($0.candidate.id) }
            if !stale.isEmpty {
                mapView.removeAnnotations(stale)
            }

            let additions = parent.candidates.compactMap { candidate -> StoreCandidateAnnotation? in
                existingByID[candidate.id] == nil ? StoreCandidateAnnotation(candidate: candidate) : nil
            }
            if !additions.isEmpty {
                mapView.addAnnotations(additions)
            }

            syncSelection(on: mapView)
            refreshVisibleMarkers(on: mapView)
            syncRadiusOverlay(on: mapView)
        }

        private func syncSelection(on mapView: MKMapView) {
            let selectedID = parent.selected?.id
            let annotations = mapView.annotations.compactMap { $0 as? StoreCandidateAnnotation }

            isSyncingSelection = true
            defer { isSyncingSelection = false }

            for annotation in annotations {
                let shouldSelect = annotation.candidate.id == selectedID
                let isSelected = mapView.selectedAnnotations.contains {
                    ($0 as? StoreCandidateAnnotation)?.candidate.id == annotation.candidate.id
                }

                if shouldSelect && !isSelected {
                    mapView.selectAnnotation(annotation, animated: false)
                } else if !shouldSelect && isSelected {
                    mapView.deselectAnnotation(annotation, animated: false)
                }
            }
        }

        private func refreshVisibleMarkers(on mapView: MKMapView) {
            for annotation in mapView.annotations.compactMap({ $0 as? StoreCandidateAnnotation }) {
                guard let view = mapView.view(for: annotation) as? MKMarkerAnnotationView else { continue }
                style(view, selected: annotation.candidate.id == parent.selected?.id)
            }
        }

        private func syncRadiusOverlay(on mapView: MKMapView) {
            if let radiusOverlay {
                mapView.removeOverlay(radiusOverlay)
                self.radiusOverlay = nil
            }

            guard let selected = parent.selected else { return }
            let overlay = MKCircle(center: selected.coordinate, radius: parent.radius)
            radiusOverlay = overlay
            mapView.addOverlay(overlay, level: .aboveRoads)
        }

        private func style(_ view: MKMarkerAnnotationView, selected: Bool) {
            view.markerTintColor = selected ? .systemRed : .systemBlue
            view.glyphImage = UIImage(systemName: selected ? "cart.fill" : "mappin")
        }
    }
}

private final class StoreCandidateAnnotation: NSObject, MKAnnotation {
    static let reuseIdentifier = "StoreCandidateAnnotation"

    let candidate: StoreCandidate
    let coordinate: CLLocationCoordinate2D
    let title: String?

    init(candidate: StoreCandidate) {
        self.candidate = candidate
        self.coordinate = candidate.coordinate
        self.title = candidate.name
        super.init()
    }
}

/// A pickable store result, wrapping an `MKMapItem` with the bits the UI needs.
private struct StoreCandidate: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String?
    let coordinate: CLLocationCoordinate2D

    init(_ item: MKMapItem) {
        let placemark = item.placemark
        self.name = item.name ?? String(localized: "Store")
        self.subtitle = placemark.thoroughfare.map { street in
            [placemark.subThoroughfare, street].compactMap { $0 }.joined(separator: " ")
        } ?? placemark.locality
        self.coordinate = placemark.coordinate
        self.id = "\(placemark.coordinate.latitude),\(placemark.coordinate.longitude)-\(name)"
    }

    /// Key collapsing entries at the same physical address so we don't list
    /// e.g. "Meijer" and "Meijer Pharmacy" or "Costco" and "Costco Pharmacy".
    var addressKey: String {
        String(format: "%.4f,%.4f", coordinate.latitude, coordinate.longitude)
    }

    /// Map results to candidates, keeping only one entry per address (the one
    /// with the shortest name — typically the primary store, not a sub-counter).
    static func deduped(_ items: [MKMapItem], limit: Int) -> [StoreCandidate] {
        var best: [String: StoreCandidate] = [:]
        var order: [String] = []
        for candidate in items.map(StoreCandidate.init) {
            let key = candidate.addressKey
            if let existing = best[key] {
                if candidate.name.count < existing.name.count { best[key] = candidate }
            } else {
                best[key] = candidate
                order.append(key)
            }
        }
        return order.compactMap { best[$0] }.prefix(limit).map { $0 }
    }

    static func == (lhs: StoreCandidate, rhs: StoreCandidate) -> Bool { lhs.id == rhs.id }
}

/// Top-of-list prompt nudging the member to link this list to a store. Dismissible
/// (✕) and styled to match `ActiveSessionBanner`.
struct StoreLinkBanner: View {
    var tint: Color = .green
    let onTap: () -> Void
    let onClose: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(tint.opacity(0.16)))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Connect this list to a store")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("Get reminded to start a trip when you arrive.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
