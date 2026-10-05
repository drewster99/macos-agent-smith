import AppKit
import SwiftUI

/// An SF Symbol that spins with a Core Animation layer animation instead of a SwiftUI one.
///
/// Why this exists: `.symbolEffect(.rotate, options: .repeat(.continuous))` and `.symbolEffect(
/// .variableColor, options: .repeating)` are driven by SwiftUI's own clock. Every frame each one is
/// an "External: Time" update, and on macOS every such update makes the window's `NSHostingView`
/// lay out again. Measured 2026-10-05 with the Instruments SwiftUI template on a session with four
/// running tasks: ~900 time-driven image updates a second, `NSHostingView.layout()` in 77% of
/// main-thread samples, and the app at ~55% of a core while nothing was happening — enough to make
/// the whole UI sluggish. A `CABasicAnimation` on a layer is performed by the render server: once
/// added, no frame of it touches the main thread, SwiftUI's graph, or the window's layout.
///
/// The glyph is drawn into a sublayer (rather than the view's own layer) so its anchor point can sit
/// at the centre for rotation; AppKit owns and resets the backing layer's geometry.
struct LayerSpinningSymbol: NSViewRepresentable {
    let systemName: String
    let pointSize: CGFloat
    let color: NSColor
    /// Spinning when true; at rest (the unrotated glyph) when false.
    let isSpinning: Bool
    /// One full turn, in seconds.
    var period: CFTimeInterval = 1.2
    var accessibilityLabel: String?

    func makeNSView(context: Context) -> SpinningSymbolView {
        SpinningSymbolView()
    }

    func updateNSView(_ view: SpinningSymbolView, context: Context) {
        view.configure(
            systemName: systemName,
            pointSize: pointSize,
            color: color,
            isSpinning: isSpinning,
            period: period,
            accessibilityLabel: accessibilityLabel
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SpinningSymbolView, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
}

/// The AppKit side of `LayerSpinningSymbol`. Only `configure` mutates it, and only when an input
/// actually changed, so an unchanged SwiftUI update restarts nothing.
final class SpinningSymbolView: NSView {
    private static let spinKey = "LayerSpinningSymbol.spin"

    private let glyphLayer = CALayer()
    private var systemName = ""
    private var pointSize: CGFloat = 0
    private var color: NSColor = .labelColor
    private var isSpinning = false
    private var period: CFTimeInterval = 1.2
    private var glyphSize = CGSize.zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        glyphLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(glyphLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SpinningSymbolView is only created in code")
    }

    override var intrinsicContentSize: NSSize { glyphSize }

    func configure(
        systemName: String,
        pointSize: CGFloat,
        color: NSColor,
        isSpinning: Bool,
        period: CFTimeInterval,
        accessibilityLabel: String?
    ) {
        let glyphChanged = systemName != self.systemName || pointSize != self.pointSize || color != self.color
        self.systemName = systemName
        self.pointSize = pointSize
        self.color = color
        self.period = period
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(accessibilityLabel ?? systemName)
        if glyphChanged {
            renderGlyph()
        }
        // Only a change of spinning state touches the animation. Swapping the layer's contents
        // (a new glyph or color) leaves a running animation in place, so it never jumps.
        if isSpinning != self.isSpinning {
            self.isSpinning = isSpinning
            updateSpin()
        }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyphLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        glyphLayer.bounds = CGRect(origin: .zero, size: glyphSize)
        glyphLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    /// Dynamic colors (label/secondary-label, system colors) resolve per appearance, so the glyph is
    /// re-rendered when the appearance changes.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        renderGlyph()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        renderGlyph()
    }

    private func renderGlyph() {
        // AppKit can report an appearance or backing change before the first `configure`.
        guard !systemName.isEmpty else { return }
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else {
            assertionFailure("Unknown SF Symbol \(systemName)")
            glyphLayer.contents = nil
            return
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        var contents: Any?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            contents = image.layerContents(forContentsScale: scale)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyphLayer.contents = contents
        glyphLayer.contentsScale = scale
        CATransaction.commit()
        if image.size != glyphSize {
            glyphSize = image.size
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    private func updateSpin() {
        glyphLayer.removeAnimation(forKey: Self.spinKey)
        guard isSpinning else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        // Negative is clockwise in the view's unflipped (y-up) layer space.
        spin.toValue = -2 * Double.pi
        spin.duration = period
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        glyphLayer.add(spin, forKey: Self.spinKey)
    }
}
