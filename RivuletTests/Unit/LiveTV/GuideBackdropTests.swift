// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  GuideBackdropTests.swift
//  RivuletTests
//
//  The Guide's backdrop. Moving between two programmes with art must read as
//  one crossfade: never a dip to the bare background in between.
//

import XCTest
@testable import Rivulet

@MainActor
final class GuideBackdropTests: XCTestCase {
    private let art = URL(string: "https://example.com/art.jpg")!
    private let wide = URL(string: "https://example.com/wide.jpg")!
    private let poster = URL(string: "https://example.com/poster.jpg")!

    private func program(icon: URL? = nil, landscape: URL? = nil, poster: URL? = nil) -> UnifiedProgram {
        UnifiedProgram(id: "p", channelId: "c", title: "t", startTime: .now, endTime: .now + 1800,
                       iconURL: icon, posterURL: poster, landscapeURL: landscape)
    }

    /// Declared wide art first, then any art at all: a portrait poster fills
    /// the backdrop rather than leaving it bare (#360).
    func test_backdropURL() {
        XCTAssertEqual(GuideLayoutView.backdropURL(for: program(icon: art, landscape: wide)), wide)
        XCTAssertEqual(GuideLayoutView.backdropURL(for: program(icon: art, poster: poster)), art)
        XCTAssertEqual(GuideLayoutView.backdropURL(for: program(poster: poster)), poster)
        XCTAssertNil(GuideLayoutView.backdropURL(for: program()))
        XCTAssertNil(GuideLayoutView.backdropURL(for: nil))
    }

    /// Art to art: the outgoing image stays opaque under the incoming one, so
    /// the page behind never shows through mid-fade. Art to none: it fades out.
    func test_outgoingOpacity() {
        XCTAssertEqual(GuideLayoutView.outgoingBackdropOpacity(progress: 0.5, hasIncoming: true), 1)
        XCTAssertEqual(GuideLayoutView.outgoingBackdropOpacity(progress: 0.5, hasIncoming: false), 0.5)
    }
}
