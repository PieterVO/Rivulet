// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import MetalKit
import SwiftUI
import UIKit

/// The signed-out welcome's backdrop: `WelcomeGlowShader` draws the icon's R,
/// blurred, with its colors spilling across the screen and a soft stream
/// running down it; stars twinkle above in Core Animation.
final class WelcomeGlowView: UIView {

    private enum Layout {
        /// The R's canvas height in screen heights, and the R UV at the screen's centre
        /// (0.55 puts the top of the R's top stroke at the top of the screen).
        static let size: CGFloat = 1.25
        static let centerY: Float = 0.55
        static let starCount = 28
    }

    private let metalView = MTKView()
    private let renderer: Renderer?
    private let stars = CALayer()

    override init(frame: CGRect) {
        renderer = Renderer(view: metalView)
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        metalView.frame = bounds
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(metalView)
        layer.addSublayer(stars)
        NotificationCenter.default.addObserver(self, selector: #selector(updateMotion),
                                               name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        stars.frame = bounds
        if stars.sublayers == nil, bounds.width > 0 { scatterStars() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateMotion()
    }

    /// Draws only while on screen, and holds one still frame under Reduce Motion.
    @objc private func updateMotion() {
        let moving = window != nil && !UIAccessibility.isReduceMotionEnabled
        metalView.isPaused = !moving
        metalView.enableSetNeedsDisplay = !moving
        if !moving { metalView.setNeedsDisplay() }
        for star in stars.sublayers ?? [] {
            star.removeAllAnimations()
            guard moving else { continue }
            let twinkle = CABasicAnimation(keyPath: "opacity")
            twinkle.fromValue = Float.random(in: 0.1...0.3)
            twinkle.toValue = 1
            twinkle.duration = .random(in: 1.4...4)
            twinkle.autoreverses = true
            twinkle.repeatCount = .infinity
            twinkle.beginTime = CACurrentMediaTime() + .random(in: 0...4)
            twinkle.fillMode = .backwards
            twinkle.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            twinkle.isRemovedOnCompletion = false
            star.add(twinkle, forKey: "twinkle")
        }
    }

    /// Stars gathered around the R, thinning toward the edges.
    private func scatterStars() {
        let image = Self.starImage
        for _ in 0..<Layout.starCount {
            let x = (CGFloat.random(in: 0...1) + CGFloat.random(in: 0...1)) / 2
            let y = (CGFloat.random(in: 0...1) + CGFloat.random(in: 0...1)) / 2
            let size = CGFloat.random(in: 0...1) < 0.15 ? CGFloat.random(in: 13...19) : CGFloat.random(in: 6...11)
            let star = CALayer()
            star.contents = image
            star.compositingFilter = "screenBlendMode"
            star.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            star.position = CGPoint(x: bounds.width * (0.05 + x * 0.9),
                                    y: bounds.height * (0.05 + y * 0.9))
            star.opacity = 0.6
            stars.addSublayer(star)
        }
        updateMotion()
    }

    /// A hot core that falls off quickly, with no wide halo.
    private static let starImage: CGImage? = {
        let size = CGSize(width: 24, height: 24)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor.white.cgColor, UIColor(red: 1, green: 0.98, blue: 0.92, alpha: 0.55).cgColor,
                          UIColor(red: 1, green: 0.98, blue: 0.92, alpha: 0).cgColor] as CFArray
            guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                            locations: [0, 0.45, 1]) else { return }
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            context.cgContext.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                                                 endCenter: center, endRadius: size.width / 2, options: [])
        }.cgImage
    }()

    // MARK: - Renderer

    private struct Uniforms {
        var time: Float
        var flowScale: SIMD2<Float>
        var flowCenter: SIMD2<Float>
        var starScale: SIMD2<Float>
    }

    private final class Renderer: NSObject, MTKViewDelegate {
        private let queue: MTLCommandQueue
        private let pipeline: MTLRenderPipelineState
        private let textures: [MTLTexture]
        private let start = CACurrentMediaTime()

        init?(view: MTKView) {
            guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
                  let library = try? device.makeLibrary(source: WelcomeGlowShader.source, options: nil)
            else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "welcomeVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "welcomeFragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            let loader = MTKTextureLoader(device: device)
            // The maps are data, not pictures: no color conversion.
            let options: [MTKTextureLoader.Option: Any] = [.SRGB: false]
            guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor),
                  let flow = Bundle.main.url(forResource: "WelcomeFlow", withExtension: "png")
                    .flatMap({ try? loader.newTexture(URL: $0, options: options) }),
                  let spill = Bundle.main.url(forResource: "WelcomeSpill", withExtension: "png")
                    .flatMap({ try? loader.newTexture(URL: $0, options: options) }),
                  let sky = UIImage(named: "WelcomeStars")?.cgImage
                    .flatMap({ try? loader.newTexture(cgImage: $0, options: options) })
            else { return nil }
            self.queue = queue
            self.pipeline = pipeline
            textures = [flow, spill, sky]
            super.init()
            view.device = device
            view.colorPixelFormat = .bgra8Unorm
            view.framebufferOnly = true
            view.preferredFramesPerSecond = 30
            view.delegate = self
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard view.drawableSize.height > 0, let pass = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable, let buffer = queue.makeCommandBuffer(),
                  let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            let aspect = Float(view.drawableSize.width / view.drawableSize.height)
            let size = Float(Layout.size)
            var uniforms = Uniforms(
                time: view.isPaused ? 0 : Float(CACurrentMediaTime() - start),
                flowScale: SIMD2(aspect / (size * 5 / 3), 1 / size),
                flowCenter: SIMD2(0.5, Layout.centerY),
                starScale: SIMD2(aspect / (5 / 3), 1))
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            for (index, texture) in textures.enumerated() { encoder.setFragmentTexture(texture, index: index) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
        }
    }
}

/// SwiftUI host for the welcome overlay in `TVSidebarView`.
struct WelcomeGlowBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> WelcomeGlowView { WelcomeGlowView() }
    func updateUIView(_ uiView: WelcomeGlowView, context: Context) {}
}
