// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ExtraPlaybackKeyTests.swift
//  RivuletTests
//
//  Issue #255: trailers failed to play "more times than not". The play path fed
//  an extra's `id` into /library/metadata/{id}, but Plex's IVA-supplied extras
//  have no library ratingKey — their only handle is an absolute part path. That
//  built a nonsense URL which 404'd, and IVA extras are the common case, hence
//  "more times than not".
//
//  The regression guard is `test_ivaAssetPath_routesToDirectPartPath`: if an IVA
//  path ever routes back to .libraryMetadata, issue #255 is back.
//
//  The keyShape tests matter for a second reason — extra paths carry asset
//  identifiers, so the telemetry label must never be derived from the key's
//  contents. That property must not regress.
//
//  Pure tests: no network, no view controller.
//

import XCTest
@testable import Rivulet

final class ExtraPlaybackKeyTests: XCTestCase {

    // MARK: - Library-addressable extras (user-added / disc rips)

    func test_bareNumericKey_routesToLibraryMetadata() {
        XCTAssertEqual(ExtraPlaybackKey.route(for: "12345"), .libraryMetadata(ratingKey: "12345"))
    }

    func test_libraryMetadataPath_reducesToRatingKey() {
        XCTAssertEqual(
            ExtraPlaybackKey.route(for: "/library/metadata/12345"),
            .libraryMetadata(ratingKey: "12345")
        )
    }

    func test_libraryMetadataPathWithTrailingSegments_reducesToRatingKey() {
        XCTAssertEqual(
            ExtraPlaybackKey.route(for: "/library/metadata/12345/children"),
            .libraryMetadata(ratingKey: "12345")
        )
    }

    // MARK: - Non-library extras (Plex IVA) — the #255 regression guard

    func test_ivaAssetPath_routesToDirectPartPath() {
        let key = "/services/iva/assets/abc123/video.mp4"
        XCTAssertEqual(ExtraPlaybackKey.route(for: key), .directPartPath(key))
    }

    func test_ivaAssetPath_isNotTreatedAsRatingKey() {
        // The exact #255 failure: this must NOT become /library/metadata/{path}.
        XCTAssertNil(ExtraPlaybackKey.libraryRatingKey(from: "/services/iva/assets/abc123/video.mp4"))
    }

    func test_partsPath_routesToDirectPartPath() {
        let key = "/library/parts/98765/1234567890/file.mkv"
        XCTAssertEqual(ExtraPlaybackKey.route(for: key), .directPartPath(key))
    }

    // MARK: - Malformed keys degrade to the direct path, never a bogus ratingKey

    func test_nonNumericMetadataSegment_isNotARatingKey() {
        XCTAssertNil(ExtraPlaybackKey.libraryRatingKey(from: "/library/metadata/plex%3A%2F%2Fmovie%2Fabc"))
    }

    func test_emptyKey_routesToDirectPartPath() {
        XCTAssertEqual(ExtraPlaybackKey.route(for: ""), .directPartPath(""))
    }

    func test_alphanumericKey_isNotARatingKey() {
        XCTAssertNil(ExtraPlaybackKey.libraryRatingKey(from: "12345abc"))
    }

    // MARK: - keyShape: low cardinality, and never echoes the key

    func test_keyShape_categorizesEachFlavor() {
        XCTAssertEqual(ExtraPlaybackKey.keyShape("12345"), "numeric_rating_key")
        XCTAssertEqual(ExtraPlaybackKey.keyShape("/library/metadata/12345"), "library_metadata_path")
        XCTAssertEqual(ExtraPlaybackKey.keyShape("/services/iva/assets/abc/v.mp4"), "iva_asset_path")
        XCTAssertEqual(ExtraPlaybackKey.keyShape("/library/parts/1/2/f.mkv"), "other_absolute_path")
        XCTAssertEqual(ExtraPlaybackKey.keyShape(""), "empty")
        XCTAssertEqual(ExtraPlaybackKey.keyShape("something-else"), "other")
    }

    /// Extra paths carry asset identifiers and Plex tokens ride in query strings.
    /// Nothing derived from the key's contents may appear in the telemetry label.
    func test_keyShape_neverEchoesKeyContents() {
        let sensitive = "/services/iva/assets/SECRET-ASSET-ID/v.mp4?X-Plex-Token=abc123"
        let shape = ExtraPlaybackKey.keyShape(sensitive)
        XCTAssertFalse(shape.contains("SECRET-ASSET-ID"))
        XCTAssertFalse(shape.contains("abc123"))
        XCTAssertFalse(shape.contains("X-Plex-Token"))
        XCTAssertEqual(shape, "iva_asset_path")
    }

    func test_keyShape_vocabularyIsClosed() {
        let allowed: Set<String> = [
            "empty", "numeric_rating_key", "library_metadata_path",
            "iva_asset_path", "other_absolute_path", "other"
        ]
        let samples = [
            "", "1", "/library/metadata/9", "/services/iva/x", "/anything", "bare",
            "/library/metadata/plex://movie/x", "12345abc"
        ]
        for sample in samples {
            XCTAssertTrue(
                allowed.contains(ExtraPlaybackKey.keyShape(sample)),
                "keyShape produced an unexpected label for \(sample)"
            )
        }
    }
}
