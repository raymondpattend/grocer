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
        case .small: return 64
        case .medium: return 128
        case .large: return 255
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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Observed so the flow reacts when the permission prompt resolves.
    private let reminders = StoreReminderManager.shared

    private enum Step { case intro, picker }
    @State private var step: Step

    /// When `true` the flow opens straight on the map picker, skipping the intro
    /// (used when changing an already-linked store).
    init(startAtPicker: Bool = false) {
        _step = State(initialValue: startAtPicker ? .picker : .intro)
    }

    @State private var visibleRegion: MKCoordinateRegion?
    @State private var nearby: [StoreCandidate] = []
    @State private var selected: StoreCandidate?
    @State private var size: GeofenceSize = .medium
    @State private var isSearching = false
    @State private var requestingPermission = false

    var body: some View {
        ZStack {
            if step == .intro {
                intro
                    .transition(.opacity)
            } else {
                picker
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.28), value: step)
        .presentationDetents(step == .intro ? [.height(370)] : [.large])
        .presentationDragIndicator(step == .intro ? .hidden : .visible)
        // Require *Always* before revealing the map.
        .onChange(of: reminders.authorizationStatus) { _, status in
            guard requestingPermission else { return }
            if status == .authorizedAlways {
                requestingPermission = false
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.34)) { step = .picker }
            } else if status != .notDetermined {
                // They answered, but not with Always — drop the spinner so the
                // intro can show the next step (upgrade prompt / Settings).
                requestingPermission = false
            }
        }
    }

    // MARK: - Intro

    private var intro: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                closeButton
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer(minLength: 0)

            VStack(spacing: 16) {
                introIcon

                VStack(spacing: 8) {
                    Text("Remember at the Store")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Link this list to a store and Grocer will remind you to start a trip when you arrive — even when the app is closed.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 28)
            }

            Spacer(minLength: 0)
        }
        .safeAreaInset(edge: .bottom) {
            introFooter
        }
    }

    private var introIcon: some View {
        Image(systemName: "mappin.and.ellipse")
            .font(.system(size: 38, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 84, height: 84)
            .background(
                LinearGradient(
                    colors: [tint, tint.opacity(0.72)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .shadow(color: tint.opacity(0.32), radius: 12, y: 6)
            .accessibilityHidden(true)
    }

    private var introFooter: some View {
        Button(action: introPrimaryAction) {
            Group {
                if requestingPermission {
                    ProgressView().tint(primaryButtonForeground)
                } else {
                    Text(introPrimaryTitle)
                }
            }
            .font(.headline)
            .foregroundStyle(primaryButtonForeground)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background(Capsule().fill(primaryButtonBackground))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(requestingPermission)
        .padding(.horizontal, 20)
        .padding(.top, 32)
        .padding(.bottom, 8)
    }

    private var primaryButtonForeground: Color {
        colorScheme == .dark ? .black : .white
    }

    private var primaryButtonBackground: Color {
        colorScheme == .dark ? .white : .black
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
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.34)) { step = .picker }
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
                searchingIndicator
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
            performSearch()
        }
    }

    private var pickerHeader: some View {
        ZStack {
            GrocerGlassTitle("Choose a store")

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
        .padding(.top, 20)
    }

    /// Transient pill confirming the store query is re-running as the member
    /// pans or zooms the map (the query now follows the visible region instead
    /// of an explicit "search this area" tap).
    @ViewBuilder
    private var searchingIndicator: some View {
        if isSearching {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini).tint(.white)
                Text("Finding stores…").fontWeight(.semibold)
            }
            .font(.subheadline)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .modifier(GlassCapsule())
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var pickerBottomBar: some View {
        HStack {
            sizeMenu
            Spacer(minLength: 0)
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

    // MARK: - Actions

    private var tint: Color { repo.currentHousehold?.tint ?? .accentColor }

    private func performSearch() {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = String(localized: "grocery store")
        if let visibleRegion { request.region = visibleRegion }
        request.resultTypes = .pointOfInterest

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
                .grocerLiquidGlass(in: Circle(), interactive: true)
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
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content.background(.ultraThinMaterial, in: Circle())
        }
    }
}

// MARK: - Pins & candidates

private struct StorePickerMapView: UIViewRepresentable {
    let candidates: [StoreCandidate]
    @Binding var selected: StoreCandidate?
    let radius: CLLocationDistance
    @Binding var visibleRegion: MKCoordinateRegion?
    /// Invoked (debounced) whenever the visible region settles after a pan or
    /// zoom, so the store query tracks whatever the member is looking at.
    let onSearch: () -> Void

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
        /// Pending debounced search, replaced on every region change so we only
        /// query once the map has settled.
        private var searchDebounce: Task<Void, Never>?
        /// Set while we drive the camera ourselves (zoom-to-fit) so the
        /// resulting region change doesn't kick off another search.
        private var isProgrammaticRegionChange = false
        /// Guards the one-time "zoom out to reveal the nearest stores" pass so
        /// later searches don't fight the member's own panning.
        private var hasFitResults = false

        init(_ parent: StorePickerMapView) {
            self.parent = parent
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            let region = mapView.region
            DispatchQueue.main.async { self.parent.visibleRegion = region }

            if isProgrammaticRegionChange {
                isProgrammaticRegionChange = false
                return
            }
            scheduleSearch()
        }

        /// Coalesces rapid region changes (pinch / drag momentum) into a single
        /// query fired shortly after the map stops moving.
        private func scheduleSearch() {
            searchDebounce?.cancel()
            searchDebounce = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard let self, !Task.isCancelled else { return }
                self.parent.onSearch()
            }
        }

        /// Zooms the camera out so every result sits comfortably in view. Runs
        /// once, the first time results arrive.
        private func fitResultsIfNeeded(on mapView: MKMapView) {
            guard !hasFitResults, !parent.candidates.isEmpty else { return }
            let annotations = mapView.annotations.filter { $0 is StoreCandidateAnnotation }
            guard !annotations.isEmpty else { return }
            hasFitResults = true
            // Stop following the user so the fitted region sticks.
            mapView.userTrackingMode = .none
            isProgrammaticRegionChange = true
            // Generous insets clear the header pill at the top and the size bar
            // at the bottom so no marker hides behind the chrome.
            let padding = UIEdgeInsets(top: 140, left: 48, bottom: 120, right: 48)
            mapView.setVisibleMapRect(
                mapView.mapRectThatFits(boundingMapRect(for: annotations), edgePadding: padding),
                animated: true
            )
        }

        private func boundingMapRect(for annotations: [MKAnnotation]) -> MKMapRect {
            let rect = annotations.reduce(MKMapRect.null) { rect, annotation in
                let point = MKMapPoint(annotation.coordinate)
                return rect.union(MKMapRect(x: point.x, y: point.y, width: 0, height: 0))
            }
            guard !rect.isNull else { return rect }
            // Floor the span so a lone result (or a tight cluster) doesn't slam
            // the camera to maximum zoom. ~800m at the rect's centre.
            let metersPerPoint = MKMetersPerMapPointAtLatitude(rect.origin.coordinate.latitude)
            let minSide = (metersPerPoint > 0 ? 800 / metersPerPoint : rect.size.width)
            let width = max(rect.size.width, minSide)
            let height = max(rect.size.height, minSide)
            let centerX = rect.midX
            let centerY = rect.midY
            return MKMapRect(
                x: centerX - width / 2,
                y: centerY - height / 2,
                width: width,
                height: height
            )
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

            fitResultsIfNeeded(on: mapView)
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
            view.glyphImage = UIImage(systemName: selected ? "cart.fill" : "storefront.fill")
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
                    .accessibilityHidden(true)

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
        .accessibilityLabel("Connect this list to a store")
        .accessibilityHint("Get reminded to start a trip when you arrive")
    }
}

// MARK: - Linked store card (Settings)

/// Settings card shown once a list is linked to a store: a Find My–style map
/// snapshot with the geofence ring and store address plus a "Change" button,
/// followed by the personal arrival-reminder toggle and a remove action.
struct StoreLocationCard: View {
    let household: Household
    @Binding var remindersEnabled: Bool
    let onChange: () -> Void
    let onRemove: () -> Void

    private var coordinate: CLLocationCoordinate2D? {
        guard let latitude = household.storeLatitude,
              let longitude = household.storeLongitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var body: some View {
        VStack(spacing: 14) {
            if let coordinate {
                StoreMapSnapshot(
                    coordinate: coordinate,
                    radius: household.storeRadius ?? Household.defaultStoreRadius,
                    storeName: household.storeName,
                    tint: household.tint,
                    onChange: onChange,
                    onRemove: onRemove
                )
            }
            controls
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            Toggle(isOn: $remindersEnabled) {
                Label {
                    Text("Notify me when I arrive")
                } icon: {
                    Image(systemName: "location.fill.viewfinder")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(
            Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 1)
        }
    }
}

/// Non-interactive map preview of the linked store with its geofence ring and an
/// address/Change bar overlaid along the bottom edge.
private struct StoreMapSnapshot: View {
    let coordinate: CLLocationCoordinate2D
    let radius: CLLocationDistance
    let storeName: String?
    let tint: Color
    let onChange: () -> Void
    let onRemove: () -> Void

    @State private var address: String?

    /// Map frame height and the approximate height of the address bar that
    /// overlays its bottom edge — used to recentre the pin in the visible area.
    private let mapHeight: CGFloat = 190
    private let addressBarInset: CGFloat = 52

    private var region: MKCoordinateRegion {
        // Frame the geofence ring with comfortable padding on every side.
        let span = max(radius * 4, 400)
        // Nudge the camera south so the pin lands in the centre of the *visible*
        // map rather than behind the address bar overlaying the bottom edge.
        let metersPerPoint = span / mapHeight
        let offsetMeters = metersPerPoint * (addressBarInset / 2)
        let center = CLLocationCoordinate2D(
            latitude: coordinate.latitude - offsetMeters / 111_320,
            longitude: coordinate.longitude
        )
        return MKCoordinateRegion(center: center, latitudinalMeters: span, longitudinalMeters: span)
    }

    private var primaryLabel: String {
        storeName?.nilIfBlank ?? address ?? String(localized: "Linked store")
    }

    private var secondaryLabel: String? {
        // Only show the address as a subtitle when a store name owns the title.
        storeName?.nilIfBlank == nil ? nil : address
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(initialPosition: .region(region), interactionModes: []) {
                MapCircle(center: coordinate, radius: radius)
                    .foregroundStyle(Color.blue.opacity(0.16))
                    .stroke(Color.blue.opacity(0.65), lineWidth: 2)

                Annotation("", coordinate: coordinate) {
                    Image(systemName: "mappin")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.red, in: Circle())
                        .overlay { Circle().strokeBorder(.white, lineWidth: 2) }
                        .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                }
                .annotationTitles(.hidden)
            }
            .frame(height: mapHeight)
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            addressBar
        }
        .overlay(alignment: .topLeading) { unlinkButton }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 1)
        }
        .task(id: "\(coordinate.latitude),\(coordinate.longitude)") {
            await reverseGeocode()
        }
    }

    /// Circular unlink control floating in the map's top-left corner.
    private var unlinkButton: some View {
        Button {
            Haptics.warning()
            onRemove()
        } label: {
            Image(systemName: "trash.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.red)
                .frame(width: 38, height: 38)
                .contentShape(Circle())
                .modifier(GlassCircle())
        }
        .buttonStyle(.plain)
        .padding(12)
        .accessibilityLabel("Remove store")
    }

    private var addressBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(primaryLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let secondaryLabel {
                    Text(secondaryLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button {
                Haptics.tap()
                onChange()
            } label: {
                Text("Change")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(tint, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Change store")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private func reverseGeocode() async {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first else { return }
        let street = [placemark.subThoroughfare, placemark.thoroughfare]
            .compactMap { $0 }
            .joined(separator: " ")
            .nilIfBlank
        let parts = [street, placemark.locality].compactMap { $0 }
        address = parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
