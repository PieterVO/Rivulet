//
//  TopShelfImageCompositor.swift
//  Rivulet
//
//  Draws Top Shelf carousel image: backdrop aspect-filled to 16:9 canvas,
//  subtle bottom gradient for caption legibility, (optionally) shows a
//  clearLogo top-center — Apple TV+ carousel look. Pure UIImage in/out.
//

import UIKit

enum TopShelfImageCompositor {

    static func compose(
        backdrop: UIImage,
        logo: UIImage?,
        canvasSize: CGSize = CGSize(width: 1920, height: 1080)
    ) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        return renderer.image { ctx in
            let canvasRect = CGRect(origin: .zero, size: canvasSize)

            // Backdrop: aspect-fill. Clip is scoped so it can't affect the
            // gradient/logo draws that follow.
            drawAspectFill(backdrop, in: canvasRect, cgContext: ctx.cgContext)

            // Subtle bottom gradient for caption legibility.
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor.clear.cgColor, UIColor.black.withAlphaComponent(0.55).cgColor] as CFArray,
                locations: [0.55, 1.0]) {
                ctx.cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: canvasSize.height * 0.5),
                    end: CGPoint(x: 0, y: canvasSize.height),
                    options: [])
            }

            // Logo top-center, target-area sized with clamps.
            if let logo {
                let rect = logoRect(for: logo.size, canvas: canvasSize)
                logo.draw(in: rect)
            }
        }
    }

    /// Draws `image` into `rect`, aspect-filling (cropping to fill, no letterboxing).
    /// The clip is scoped to a saved graphics state so it can't affect later draws.
    private static func drawAspectFill(_ image: UIImage, in rect: CGRect, cgContext: CGContext) {
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        let imageAspect = imageSize.width / imageSize.height
        let rectAspect = rect.width / rect.height

        var drawRect = rect
        if imageAspect > rectAspect {
            // Image is wider than target: scale to fill height, crop width.
            let scaledWidth = rect.height * imageAspect
            drawRect = CGRect(
                x: rect.midX - scaledWidth / 2,
                y: rect.minY,
                width: scaledWidth,
                height: rect.height)
        } else {
            // Image is taller than target: scale to fill width, crop height.
            let scaledHeight = rect.width / imageAspect
            drawRect = CGRect(
                x: rect.minX,
                y: rect.midY - scaledHeight / 2,
                width: rect.width,
                height: scaledHeight)
        }

        cgContext.saveGState()
        cgContext.clip(to: rect)
        image.draw(in: drawRect)
        cgContext.restoreGState()
    }

    /// Computes the logo's draw rect: top-center, area-budgeted to the logo's own aspect ratio,
    /// clamped to 55% canvas width / 28% canvas height, with ~6% top inset.
    private static func logoRect(for logoSize: CGSize, canvas: CGSize) -> CGRect {
        let ratio = logoSize.height > 0 ? logoSize.width / logoSize.height : 3.0
        let targetArea = (canvas.width * 0.35) * (canvas.height * 0.14) // area budget
        var w = (targetArea * ratio).squareRoot()
        var h = (targetArea / ratio).squareRoot()
        let maxW = canvas.width * 0.55
        let maxH = canvas.height * 0.28
        if w > maxW { w = maxW; h = w / ratio }
        if h > maxH { h = maxH; w = h * ratio }
        let x = canvas.width / 2 - w / 2
        let y = canvas.height * 0.06
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
