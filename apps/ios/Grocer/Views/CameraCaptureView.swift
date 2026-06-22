import AVFoundation
import Observation
import SwiftUI
import UIKit

/// Full-screen custom camera that returns the photo the instant the shutter is
/// tapped — there is no "Retake / Use Photo" confirmation step (unlike
/// `UIImagePickerController`, which always interposes one for the camera source).
///
/// Use `isAvailable` to decide whether to present this; on hardware without a
/// camera (e.g. the Simulator) callers fall back to `ImagePicker` (the library).
struct CameraCaptureView: UIViewControllerRepresentable {
    /// Delivers the captured photo, or nil when the user cancels / capture fails.
    var onCapture: (UIImage?) -> Void

    /// Whether a usable capture device exists. False on the Simulator.
    static var isAvailable: Bool {
        AVCaptureDevice.default(for: .video) != nil
    }

    func makeUIViewController(context: Context) -> CameraCaptureController {
        let controller = CameraCaptureController()
        controller.onCapture = onCapture
        return controller
    }

    func updateUIViewController(_ uiViewController: CameraCaptureController, context: Context) {}
}

/// UIKit controller driving an `AVCaptureSession`. Owns a full-bleed preview, a
/// shutter, and a cancel control; on shutter tap it captures a single frame and
/// immediately hands the resulting image back, dismissing nothing itself (the
/// SwiftUI caller drives presentation).
final class CameraCaptureController: UIViewController, AVCapturePhotoCaptureDelegate {
    var onCapture: ((UIImage?) -> Void)?

    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    // Session setup/teardown runs off the main thread, as Apple recommends.
    private let sessionQueue = DispatchQueue(label: "org.narro.grocer.camera.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    /// The active capture device, retained so the zoom controls can drive it.
    private var videoDevice: AVCaptureDevice?
    /// Guards against delivering more than once (double shutter tap, or a tap
    /// racing a cancel).
    private var didFinish = false
    private var isConfigured = false

    private lazy var shutterButton = makeShutterButton()
    private lazy var cancelButton = makeCancelButton()
    /// Drives the SwiftUI zoom selector overlay; the controller publishes the
    /// supported options and the current selection here.
    private let zoomModel = CameraZoomModel()
    private var hintHost: UIHostingController<CameraHintView>?
    private var zoomHost: UIHostingController<CameraZoomSelector>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview

        addControls()
        requestAccessAndConfigure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    override var prefersStatusBarHidden: Bool { true }

    // MARK: - Session

    private func requestAccessAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            sessionQueue.suspend()
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                self.sessionQueue.resume()
                if granted {
                    self.configureAndStart()
                } else {
                    DispatchQueue.main.async { self.finish(with: nil) }
                }
            }
        default:
            // Denied / restricted: bow out so the caller can react (the photo
            // library remains reachable from Settings-driven flows elsewhere).
            finish(with: nil)
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self, !self.isConfigured else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .photo

            let device = self.bestBackVideoDevice()
            if let device,
               let input = try? AVCaptureDeviceInput(device: device),
               self.session.canAddInput(input) {
                self.session.addInput(input)
                self.videoDevice = device
            }
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }
            self.session.commitConfiguration()

            // Work out the zoom stops this hardware actually supports and open at
            // the wide-angle "1×". A multi-lens device otherwise starts at its
            // ultra-wide minimum (i.e. 0.5×), which isn't the expected framing.
            if let device = self.videoDevice {
                let options = self.makeZoomOptions(for: device)
                let oneXIndex = options.firstIndex { $0.label == "1" } ?? 0
                if options.indices.contains(oneXIndex) {
                    self.applyZoomFactor(options[oneXIndex].videoZoomFactor, to: device)
                }
                DispatchQueue.main.async {
                    self.publishZoomOptions(options, selectedIndex: oneXIndex)
                }
            }

            self.isConfigured = true
            self.session.startRunning()
        }
    }

    /// Prefer a virtual multi-lens device so a single `videoZoomFactor` can move
    /// across the ultra-wide / wide / tele lenses — that's what makes true 0.5×
    /// and 2× framing possible — falling back to the plain wide camera.
    ///
    /// `nonisolated`: pure device lookup, invoked from the session queue.
    private nonisolated func bestBackVideoDevice() -> AVCaptureDevice? {
        let preferred: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera,
        ]
        for type in preferred {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) {
                return device
            }
        }
        return AVCaptureDevice.default(for: .video)
    }

    // MARK: - Zoom

    /// The zoom presets this device supports, in display order. 0.5× appears only
    /// when an ultra-wide lens is present; 2× only when it's within the device's
    /// max zoom. 1× (the wide camera) is always offered.
    ///
    /// `nonisolated`: derives everything from `device`, invoked from the session queue.
    private nonisolated func makeZoomOptions(for device: AVCaptureDevice) -> [CameraZoomOption] {
        let minZoom = device.minAvailableVideoZoomFactor
        let maxZoom = device.maxAvailableVideoZoomFactor
        let hasUltraWide = device.deviceType == .builtInUltraWideCamera
            || device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }

        // The device-space `videoZoomFactor` at which the wide lens fills the
        // frame — the user-facing "1×". On a virtual device whose base lens is
        // the ultra-wide, that's the first switch-over factor; otherwise the base
        // lens is already the wide camera at 1.0.
        let wideFactor: CGFloat
        if hasUltraWide, let firstSwitchOver = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            wideFactor = CGFloat(truncating: firstSwitchOver)
        } else {
            wideFactor = 1.0
        }

        var options: [CameraZoomOption] = []
        let halfFactor = wideFactor * 0.5
        if hasUltraWide, halfFactor >= minZoom {
            options.append(CameraZoomOption(label: "0.5", videoZoomFactor: halfFactor))
        }
        options.append(CameraZoomOption(label: "1", videoZoomFactor: wideFactor))
        let doubleFactor = wideFactor * 2.0
        if doubleFactor <= maxZoom {
            options.append(CameraZoomOption(label: "2", videoZoomFactor: doubleFactor))
        }
        return options
    }

    /// Publishes the supported options to the SwiftUI selector (main thread). A
    /// lone "1×" stop isn't worth a control, so the selector stays hidden.
    private func publishZoomOptions(_ options: [CameraZoomOption], selectedIndex: Int) {
        zoomModel.options = options
        zoomModel.selectedIndex = selectedIndex
        zoomHost?.view.isHidden = options.count <= 1
    }

    /// Invoked from the SwiftUI selector on the main thread; updates the
    /// selection immediately and applies the zoom on the session queue.
    private func selectZoom(_ index: Int) {
        guard zoomModel.options.indices.contains(index) else { return }
        zoomModel.selectedIndex = index
        UISelectionFeedbackGenerator().selectionChanged()
        let factor = zoomModel.options[index].videoZoomFactor
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoDevice else { return }
            self.applyZoomFactor(factor, to: device)
        }
    }

    /// `nonisolated`: only touches `device`, invoked from the session queue.
    private nonisolated func applyZoomFactor(_ factor: CGFloat, to device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = min(max(factor, device.minAvailableVideoZoomFactor),
                                         device.maxAvailableVideoZoomFactor)
            device.unlockForConfiguration()
        } catch {
            // Leave the zoom where it is if the device can't be locked.
        }
    }

    // MARK: - Controls

    private func addControls() {
        shutterButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shutterButton)
        view.addSubview(cancelButton)

        // The hint and zoom selector live in Liquid Glass overlays so they share
        // the app's glass styling (and its pre-iOS-26 material fallback).
        let hint = addHostedView(CameraHintView(), interactive: false)
        hintHost = hint
        let zoom = addHostedView(
            CameraZoomSelector(model: zoomModel) { [weak self] index in self?.selectZoom(index) },
            interactive: true
        )
        zoom.view.isHidden = true
        zoomHost = zoom

        NSLayoutConstraint.activate([
            shutterButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            shutterButton.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -28),
            shutterButton.widthAnchor.constraint(equalToConstant: 74),
            shutterButton.heightAnchor.constraint(equalToConstant: 74),

            cancelButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            cancelButton.centerYAnchor.constraint(equalTo: shutterButton.centerYAnchor),

            // Hint pinned near the top, centered, inset from both edges so the text
            // wraps rather than running under the notch/edges.
            hint.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            hint.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.view.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            hint.view.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            hint.view.widthAnchor.constraint(lessThanOrEqualToConstant: 360),

            // Zoom selector floats just above the shutter.
            zoom.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            zoom.view.bottomAnchor.constraint(equalTo: shutterButton.topAnchor, constant: -22),
        ])
    }

    /// Adds a SwiftUI overlay as a child view controller sized to its content.
    /// `interactive: false` lets touches pass straight through (e.g. the hint).
    @discardableResult
    private func addHostedView<V: View>(_ rootView: V, interactive: Bool) -> UIHostingController<V> {
        let host = UIHostingController(rootView: rootView)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.isUserInteractionEnabled = interactive
        host.sizingOptions = .intrinsicContentSize
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        return host
    }

    private func makeShutterButton() -> UIButton {
        let button = UIButton(type: .custom)
        button.backgroundColor = .white
        button.layer.cornerRadius = 37
        button.layer.borderColor = UIColor.white.withAlphaComponent(0.6).cgColor
        button.layer.borderWidth = 4
        // Inner ring gap for the classic shutter look.
        let ring = CALayer()
        ring.frame = CGRect(x: 4, y: 4, width: 66, height: 66)
        ring.cornerRadius = 33
        ring.borderColor = UIColor.black.withAlphaComponent(0.15).cgColor
        ring.borderWidth = 2
        button.layer.addSublayer(ring)
        button.addTarget(self, action: #selector(captureTapped), for: .touchUpInside)
        button.accessibilityLabel = String(localized: "Take photo")
        return button
    }

    private func makeCancelButton() -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(String(localized: "Cancel"), for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        return button
    }

    // MARK: - Capture

    @objc private func captureTapped() {
        guard !didFinish else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let settings = AVCapturePhotoSettings()
        // A tap before configuration finishes simply no-ops at the output; once
        // configured, the delegate fires with the frame.
        sessionQueue.async { [photoOutput, weak self] in
            guard let self else { return }
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    @objc private func cancelTapped() {
        finish(with: nil)
    }

    // AVFoundation delivers this off the main thread; keep it nonisolated and hop
    // back to the main actor to hand the image over.
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        // `fileDataRepresentation()` carries correct orientation metadata, so
        // `UIImage(data:)` yields an upright image without manual rotation.
        let image: UIImage? = (error == nil)
            ? photo.fileDataRepresentation().flatMap(UIImage.init(data:))
            : nil
        Task { @MainActor [weak self] in self?.finish(with: image) }
    }

    private func finish(with image: UIImage?) {
        guard !didFinish else { return }
        didFinish = true
        onCapture?(image)
    }
}

// MARK: - Liquid Glass overlays

/// A short hint telling the shopper what's worth pointing the camera at — a
/// single product, a written list, or a receipt — sitting in a Liquid Glass
/// capsule so it stays legible over a bright camera preview.
private struct CameraHintView: View {
    var body: some View {
        Text("Snap a photo of a grocery item, a written list, or a receipt — we'll add the items for you.")
            .font(.system(size: 15, weight: .semibold))
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 10)
            .padding(.horizontal, 18)
            .grocerLiquidGlass(in: Capsule())
    }
}

/// One supported zoom stop, e.g. `0.5` mapped to the device-space zoom factor
/// that achieves it.
struct CameraZoomOption: Identifiable {
    let id = UUID()
    /// Display label without the "×" suffix (e.g. "0.5", "1", "2").
    let label: String
    /// The `AVCaptureDevice.videoZoomFactor` that produces this framing.
    let videoZoomFactor: CGFloat
}

/// Observable backing for the zoom selector; the controller publishes the
/// supported options and the active selection, the SwiftUI view renders them.
@Observable
final class CameraZoomModel {
    var options: [CameraZoomOption] = []
    var selectedIndex: Int = 0
}

/// A Liquid Glass capsule of zoom buttons, mirroring the system Camera control:
/// the selected stop is highlighted and shows its "×" suffix.
private struct CameraZoomSelector: View {
    let model: CameraZoomModel
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.options.enumerated()), id: \.element.id) { index, option in
                let isSelected = index == model.selectedIndex
                Button {
                    onSelect(index)
                } label: {
                    Text(isSelected ? "\(option.label)×" : option.label)
                        .font(.system(size: isSelected ? 15 : 13, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.yellow : Color.white)
                        .frame(minWidth: 40, minHeight: 40)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(option.label)× zoom"))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(5)
        .grocerLiquidGlass(in: Capsule())
        .animation(.easeInOut(duration: 0.15), value: model.selectedIndex)
    }
}
