import SwiftUI

// AI photo-identify confirm card + thinking animation, extracted from
// AddItemView.swift.

// MARK: - Identify confirm card

/// Post-capture sheet for a single photographed product. It opens in a playful
/// "thinking" state — a circle of dots twinkling under a spinning gradient ring —
/// while the vision request is in flight, then cross-dissolves into the editable item card
/// once the model answers. The card leads with the AI-generated product image
/// (the user's own photo tucked in small), and the shopper can adjust the name,
/// category, a big quantity stepper, and notes before adding.
struct IdentifyItemCard: View {
    /// The shopper's own photo, shown small — the saved item attaches this, but
    /// only its detail screen ever surfaces it. A binding (not a plain value) so
    /// the sheet content tracks it as a SwiftUI dependency and re-renders live.
    @Binding var userPhoto: UIImage?
    /// True while the vision request is in flight. Must be a binding: a plain
    /// value isn't tracked as a sheet dependency, so the content wouldn't
    /// re-render when it flips — the "thinking" animation would never appear and
    /// the sheet would open straight to the empty result form.
    @Binding var isIdentifying: Bool
    @Binding var name: String
    @Binding var category: GroceryCategory
    @Binding var quantity: String
    @Binding var notes: String
    var tint: Color
    /// Whether the leading toolbar button offers "Retake" (the photo flow, which
    /// can re-open the camera) or a plain "Cancel" (manual entry, where there's no
    /// photo to retake).
    var allowsRetake: Bool = true
    var onAdd: () -> Void
    var onRetake: () -> Void
    /// Dismiss the card without adding — used by manual entry's "Cancel".
    var onCancel: () -> Void = {}
    /// Open the camera/library to attach a photo to this item (manual entry, or
    /// re-attaching after a removal).
    var onAddPhoto: () -> Void = {}
    /// Detach the item's photo.
    var onRemovePhoto: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Natural unit proposed for the current name, offered by the stepper.
    private var proposedUnit: String? {
        let unit = UnitGuess.guess(for: trimmedName)
        return unit.isEmpty ? nil : unit
    }

    private var canAdd: Bool {
        !trimmedName.isEmpty
    }

    var body: some View {
        ZStack {
            if isIdentifying {
                IdentifyThinkingView(onRetake: onRetake)
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .opacity.combined(with: .scale(scale: 1.05))
                    ))
            } else {
                resultForm
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.97)),
                        removal: .opacity
                    ))
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.86),
                   value: isIdentifying)
    }

    /// The editable item card the thinking animation resolves into.
    private var resultForm: some View {
        NavigationStack {
            Form {
                Section {
                    heroImages
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }

                Section("Item") {
                    TextField("Item name", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                    Picker("Category", selection: $category) {
                        ForEach(GroceryCategory.ordered) { Text($0.localizedName).tag($0) }
                    }
                }

                Section("Quantity") {
                    QuantityStepperField(
                        quantity: $quantity,
                        proposedUnit: proposedUnit,
                        tint: tint,
                        large: true,
                        fill: true
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }

                Section("Notes (optional)") {
                    TextField("Notes", text: $notes, axis: .vertical)
                }
            }
            .navigationTitle("Add Item")
            .navigationBarTitleDisplayMode(.inline)
            .tint(tint)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if allowsRetake {
                        Button("Retake") {
                            Haptics.tap()
                            onRetake()
                        }
                    } else {
                        Button("Cancel") {
                            Haptics.tap()
                            onCancel()
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Haptics.success()
                        onAdd()
                    }
                    .bold()
                    .disabled(!canAdd)
                }
            }
        }
    }

    /// AI product image up top with the shopper's own photo — or, when none is
    /// attached yet, a tappable "Add Photo" tile — overlaid small in the corner.
    private var heroImages: some View {
        ZStack(alignment: .bottomTrailing) {
            aiImage
            photoCorner
                .padding(10)
        }
    }

    /// The corner photo slot. With a photo attached it shows the thumbnail and a
    /// remove badge; empty, it's a dashed "Add Photo" button that opens the
    /// camera/library — the photo affordance lives on the image itself rather than
    /// in a separate form row.
    @ViewBuilder
    private var photoCorner: some View {
        if let userPhoto {
            Image(uiImage: userPhoto)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(.systemBackground), lineWidth: 3)
                }
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                .overlay(alignment: .topTrailing) {
                    Button {
                        Haptics.tap()
                        onRemovePhoto()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.black.opacity(0.55))
                    }
                    .offset(x: 7, y: -7)
                    .accessibilityLabel("Remove photo")
                }
        } else {
            Button {
                Haptics.tap()
                onAddPhoto()
            } label: {
                VStack(spacing: 5) {
                    Image(systemName: "camera.fill")
                        .font(.title3)
                    Text("Add Photo")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(tint)
                .frame(width: 72, height: 72)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color(.systemBackground))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(tint.opacity(0.5),
                                              style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        }
                }
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add Photo")
        }
    }

    /// The AI-generated product image, or a placeholder until a name is known
    /// (the image is keyed off the identified name).
    @ViewBuilder
    private var aiImage: some View {
        if trimmedName.isEmpty {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(.systemGray6))
                .frame(width: 200, height: 200)
                .overlay {
                    Image(systemName: "photo")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                }
                .accessibilityHidden(true)
        } else {
            ProductImageView(itemName: trimmedName, size: 200)
        }
    }
}

// MARK: - Identify thinking animation

/// The "thinking" state shown while the vision model works out what was
/// photographed. A dense field of monochrome dots (black in light mode, white in
/// dark) is clipped to a circle and twinkles on and off, fading out toward the
/// rim so the disc reads as a soft orb breathing in and out, with status copy
/// blur-replacing beneath it. It fills the sheet until `isIdentifying` clears, at
/// which point `IdentifyItemCard` cross-dissolves it into the editable item form.
/// Honors Reduce Motion: the twinkle gives way to a static dot field and the
/// status copy holds on its first line.
struct IdentifyThinkingView: View {
    var onRetake: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Flipped true on appear to start the halo's breathing.
    @State private var animate = false
    /// Index into `messages` for the cycling status line.
    @State private var messageIndex = 0

    /// Diameter of the twinkling dot circle; the spinner ring sweeps just outside it.
    private let circleSize: CGFloat = 200

    private let messages = [
        String(localized: "Thinking…"),
        String(localized: "Looking at your photo…"),
        String(localized: "Spotting the product…"),
        String(localized: "Reading the label…"),
        String(localized: "Checking the details…"),
        String(localized: "Matching it to groceries…"),
        String(localized: "Sorting the shelves…"),
        String(localized: "Picking a category…"),
        String(localized: "Tidying things up…"),
        String(localized: "Almost done…"),
    ]

    private var currentMessageIndex: Int { reduceMotion ? 0 : messageIndex }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            artwork
            status
                .padding(.top, 40)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .onAppear { animate = true }
        .task {
            // Cycle the status line while the model thinks. Cancelled automatically
            // when the view is removed for the transition to the item form.
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                messageIndex = (messageIndex + 1) % messages.count
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button(String(localized: "Retake")) {
                Haptics.tap()
                onRetake()
            }
            .font(.body.weight(.medium))
            .tint(.secondary)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
    }

    /// The twinkling dot circle behind a soft halo.
    private var artwork: some View {
        ZStack {
            halo
            TwinklingDotCircle(diameter: circleSize, reduceMotion: reduceMotion)
        }
        .frame(width: circleSize + 80, height: circleSize + 80)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Identifying item from your photo"))
    }

    /// A soft monochrome glow that breathes behind the dot circle.
    private var halo: some View {
        Circle()
            .fill(Color.primary.opacity(0.12))
            .frame(width: circleSize, height: circleSize)
            .blur(radius: 34)
            .scaleEffect(reduceMotion ? 1 : (animate ? 1.06 : 0.9))
            .opacity(reduceMotion ? 0.5 : (animate ? 0.85 : 0.4))
            .animation(reduceMotion ? nil :
                .easeInOut(duration: 2).repeatForever(autoreverses: true), value: animate)
    }

    private var status: some View {
        // Each new line blur-replaces the previous one (the system text transition)
        // rather than cross-fading in place. The `id` makes every message a fresh
        // view so the transition fires; Reduce Motion swaps with no effect.
        VStack {
            Text(messages[currentMessageIndex])
                .font(.headline)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .id(currentMessageIndex)
                .transition(reduceMotion ? .identity : AnyTransition(.blurReplace))
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: currentMessageIndex)
        .accessibilityHidden(true)
    }
}

/// A dense field of dots clipped to a circle, each fading in and out on its own
/// rhythm so the whole disc reads as quietly "thinking". The field is drawn in a
/// single `Canvas` (cheap even at a few hundred dots) and laid out from a seeded
/// generator so it stays put across redraws. Under Reduce Motion it renders once,
/// static.
struct TwinklingDotCircle: View {
    var diameter: CGFloat
    var reduceMotion: Bool

    /// One dot in the field: where it sits, its size, the phase/speed of its
    /// twinkle, and how much the rim falloff dims it.
    private struct Dot {
        let position: CGPoint
        let radius: CGFloat
        let phase: Double
        let speed: Double
        let baseOpacity: Double
        /// 1 at the center, easing to 0 at the rim so the disc has no hard edge.
        let edgeFade: Double
    }

    private let dots: [Dot]

    init(diameter: CGFloat, reduceMotion: Bool) {
        self.diameter = diameter
        self.reduceMotion = reduceMotion

        var generator = SeededGenerator(seed: 0x6D5A4C3B2A19)
        var built: [Dot] = []
        let spacing: CGFloat = 8
        let center = CGPoint(x: diameter / 2, y: diameter / 2)
        // Keep every dot (plus its radius) inside the circle's edge.
        let limit = diameter / 2 - 3

        var y = spacing / 2
        while y <= diameter - spacing / 2 {
            var x = spacing / 2
            while x <= diameter - spacing / 2 {
                // Jitter each dot off the lattice so the field reads organic rather
                // than as a visible grid. RNG is consumed for every cell (even ones
                // outside the circle) so the layout stays deterministic.
                let jx = CGFloat(generator.nextUnit() - 0.5) * spacing * 0.7
                let jy = CGFloat(generator.nextUnit() - 0.5) * spacing * 0.7
                let radius = 1.1 + CGFloat(generator.nextUnit()) * 0.9
                let phase = generator.nextUnit() * 2 * .pi
                let speed = 0.8 + generator.nextUnit() * 2.2
                let base = 0.05 + generator.nextUnit() * 0.12
                let p = CGPoint(x: x + jx, y: y + jy)
                let dx = p.x - center.x
                let dy = p.y - center.y
                let dist = (dx * dx + dy * dy).squareRoot()
                if dist <= limit {
                    // Fade dots out across the outer half of the radius so the disc
                    // dissolves into the background instead of ending on a hard
                    // circular edge — the whole orb then reads as softly breathing.
                    let normalized = Double(dist / limit)
                    let t = max(0, (normalized - 0.5) / 0.5)
                    let edgeFade = 1 - (t * t * (3 - 2 * t))   // smoothstep falloff
                    built.append(Dot(position: p, radius: radius, phase: phase,
                                     speed: speed, baseOpacity: base, edgeFade: edgeFade))
                }
                x += spacing
            }
            y += spacing
        }
        dots = built
    }

    var body: some View {
        Group {
            if reduceMotion {
                Canvas { context, _ in draw(in: context, time: nil) }
            } else {
                TimelineView(.animation) { timeline in
                    Canvas { context, _ in
                        draw(in: context, time: timeline.date.timeIntervalSinceReferenceDate)
                    }
                }
            }
        }
        .frame(width: diameter, height: diameter)
    }

    /// Paint every dot. With `time == nil` (Reduce Motion) each dot is drawn once
    /// at a steady mid brightness; otherwise its opacity rides a sharpened sine so
    /// it spends most of its time dim and pops bright briefly — "on and off".
    private func draw(in context: GraphicsContext, time: Double?) {
        for dot in dots {
            let twinkle: Double
            if let time {
                let wave = (sin(time * dot.speed + dot.phase) + 1) / 2
                twinkle = min(dot.baseOpacity + pow(wave, 3) * 0.9, 1)
            } else {
                twinkle = dot.baseOpacity + 0.3
            }
            let opacity = twinkle * dot.edgeFade
            let rect = CGRect(x: dot.position.x - dot.radius,
                              y: dot.position.y - dot.radius,
                              width: dot.radius * 2, height: dot.radius * 2)
            // Black in light mode, white in dark — resolved from the environment.
            context.fill(Path(ellipseIn: rect), with: .color(Color.primary.opacity(opacity)))
        }
    }
}

/// A tiny deterministic generator (xorshift64*) so the dot field lands in the
/// same place on every redraw — the view is re-initialized whenever the status
/// line cycles, and a fresh random layout each time would make the field jump.
struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    /// Next value in [0, 1).
    mutating func nextUnit() -> Double {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let value = (state &* 0x2545F4914F6CDD1D) >> 11
        return Double(value) / Double(UInt64(1) << 53)
    }
}
