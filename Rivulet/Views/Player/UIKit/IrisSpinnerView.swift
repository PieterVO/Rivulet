import UIKit

// MARK: - IrisSpinnerView (Task 7)

/// 64pt accent ring with the conic gradient flowing around it, 1.4s/rev.
/// The ring mask is static on the view's layer; only the gradient — an
/// oversized sublayer — rotates beneath it, so the colors sweep around a
/// stationary ring (flow, not motion). Rotating the view's own layer is
/// what broke before: Auto Layout owns that layer's frame, and setting
/// frame during a transform animation (undefined) drifted the position,
/// making the whole ring orbit. Animation is re-added on window attach
/// (CAAnimations die on removal).
final class IrisSpinnerView: UIView {

    private let diameter: CGFloat
    private let stroke: CGFloat
    private let gradientLayer = CAGradientLayer()
    private let ringMask = CAShapeLayer()

    init(diameter: CGFloat = 64, stroke: CGFloat = 8) {
        self.diameter = diameter
        self.stroke = stroke
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        gradientLayer.type = .conic
        gradientLayer.colors = Self.basePalette
        gradientLayer.locations = [0, 0.25, 0.5, 0.75, 1]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradientLayer.endPoint = CGPoint(x: 0.5, y: 0)
        layer.addSublayer(gradientLayer)

        ringMask.fillColor = UIColor.clear.cgColor
        ringMask.strokeColor = UIColor.white.cgColor
        ringMask.lineWidth = stroke
        layer.mask = ringMask

        // Self-constrained: stack rows stretch un-sized arranged views to
        // absorb spare width, which turned the ring into an ellipse.
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: diameter),
            heightAnchor.constraint(equalToConstant: diameter),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize { CGSize(width: diameter, height: diameter) }

    // Both palettes are cyclic (first == last) so the conic ring never
    // shows a seam; the shimmer animates between them while the rotation
    // carries the colors around.
    private static let basePalette: [CGColor] = [
        UIColor(red: 0x7f/255, green: 0xb8/255, blue: 0xff/255, alpha: 1).cgColor,
        UIColor(red: 0xb9/255, green: 0xa3/255, blue: 0xff/255, alpha: 1).cgColor,
        UIColor(red: 0xff/255, green: 0xce/255, blue: 0x93/255, alpha: 1).cgColor,
        UIColor(red: 0x8f/255, green: 0xe9/255, blue: 0xd4/255, alpha: 1).cgColor,
        UIColor(red: 0x7f/255, green: 0xb8/255, blue: 0xff/255, alpha: 1).cgColor,
    ]
    private static let brightPalette: [CGColor] = [
        UIColor(red: 0x9c/255, green: 0xc8/255, blue: 0xff/255, alpha: 1).cgColor,
        UIColor(red: 0xcb/255, green: 0xb8/255, blue: 0xff/255, alpha: 1).cgColor,
        UIColor(red: 0xff/255, green: 0xdc/255, blue: 0xae/255, alpha: 1).cgColor,
        UIColor(red: 0xa8/255, green: 0xf0/255, blue: 0xde/255, alpha: 1).cgColor,
        UIColor(red: 0x9c/255, green: 0xc8/255, blue: 0xff/255, alpha: 1).cgColor,
    ]

    override func layoutSubviews() {
        super.layoutSubviews()
        // bounds+position (never frame) — frame is undefined while the
        // rotation transform animates. The gradient outsizes the view so
        // its corners never sweep inside the ring as it turns.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Draw from a centered square so the ring stays circular even if
        // some future layout hands this view a non-square frame.
        let diameter = min(bounds.width, bounds.height)
        let square = CGRect(x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2,
                            width: diameter, height: diameter)
        let side = diameter * 1.5
        gradientLayer.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradientLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        ringMask.path = UIBezierPath(ovalIn: square.insetBy(dx: stroke / 2, dy: stroke / 2)).cgPath
        ringMask.frame = bounds
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = 2 * Double.pi
        spin.duration = 1.4
        spin.repeatCount = .infinity
        gradientLayer.add(spin, forKey: "spin")

        // Sparkle: the stops breathe brighter and back on their own clock
        // (deliberately not a multiple of the spin period, so the shimmer
        // never syncs with the rotation).
        let shimmer = CABasicAnimation(keyPath: "colors")
        shimmer.fromValue = Self.basePalette
        shimmer.toValue = Self.brightPalette
        shimmer.duration = 2.3
        shimmer.autoreverses = true
        shimmer.repeatCount = .infinity
        shimmer.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gradientLayer.add(shimmer, forKey: "shimmer")

        // Slosh: the interior color bands stretch and compress like
        // currents while they circulate. Endpoints stay pinned at 0/1 so
        // the cyclic seam never opens. Third offset period (no common
        // multiple with 1.4s spin or 2.3s shimmer) keeps the motion from
        // ever visibly repeating.
        // Amplitude matters here: the ring rotates a full turn every 1.4s,
        // so boundary swings need to be large (up to ~0.15 of the circle,
        // bands moving in opposition) to stay visible over the spin.
        let slosh = CAKeyframeAnimation(keyPath: "locations")
        slosh.values = [
            [0, 0.25, 0.5, 0.75, 1],
            [0, 0.40, 0.55, 0.62, 1],
            [0, 0.15, 0.42, 0.85, 1],
            [0, 0.32, 0.65, 0.72, 1],
            [0, 0.25, 0.5, 0.75, 1],
        ]
        slosh.duration = 3.7
        slosh.repeatCount = .infinity
        slosh.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: 4)
        gradientLayer.add(slosh, forKey: "slosh")
    }
}
