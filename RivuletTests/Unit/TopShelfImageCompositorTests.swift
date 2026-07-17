// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TopShelfImageCompositorTests.swift
//  RivuletTests
//
//  Tests for TopShelfImageCompositor — pure UIImage-in/UIImage-out
//  backdrop+logo compositor for Top Shelf carousel images.
//

import XCTest
import UIKit
@testable import Rivulet

final class TopShelfImageCompositorTests: XCTestCase {

    private func solid(_ color: UIColor, _ size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    func testOutputMatchesCanvasSize() {
        let backdrop = solid(.red, CGSize(width: 400, height: 225))
        let logo = solid(.white, CGSize(width: 200, height: 80))
        let canvas = CGSize(width: 1920, height: 1080)
        let out = TopShelfImageCompositor.compose(backdrop: backdrop, logo: logo, canvasSize: canvas)
        XCTAssertEqual(out.size.width, canvas.width, accuracy: 0.5)
        XCTAssertEqual(out.size.height, canvas.height, accuracy: 0.5)
    }

    func testOutputMatchesCanvasSizeWithNoLogo() {
        let backdrop = solid(.blue, CGSize(width: 400, height: 225))
        let canvas = CGSize(width: 1920, height: 1080)
        let out = TopShelfImageCompositor.compose(backdrop: backdrop, logo: nil, canvasSize: canvas)
        XCTAssertEqual(out.size.width, canvas.width, accuracy: 0.5)
        XCTAssertEqual(out.size.height, canvas.height, accuracy: 0.5)
    }

    func testDefaultCanvasSizeIs1920x1080() {
        let backdrop = solid(.green, CGSize(width: 400, height: 225))
        let out = TopShelfImageCompositor.compose(backdrop: backdrop, logo: nil)
        XCTAssertEqual(out.size.width, 1920, accuracy: 0.5)
        XCTAssertEqual(out.size.height, 1080, accuracy: 0.5)
    }
}
