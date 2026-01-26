//
//  CacheManagerTests.swift
//  RivuletTests
//
//  Unit tests for CacheManager
//

import XCTest
@testable import Rivulet

final class CacheManagerTests: XCTestCase {

    // Note: CacheManager is an actor with a shared singleton and uses
    // Codable types that are complex to instantiate for testing.
    // These tests verify the observable behavior of the cache validity system.

    var cacheManager: CacheManager!

    override func setUp() async throws {
        try await super.setUp()
        cacheManager = CacheManager.shared
    }

    // MARK: - Cache Validity Tests

    func testCacheValidityReturnsFalseForNonExistentKey() async {
        let isValid = await cacheManager.isCacheValid(for: "nonexistent_key_test_12345")
        XCTAssertFalse(isValid, "Cache should not be valid for non-existent key")
    }

    func testCacheTimestampReturnsNilForNonExistentKey() async {
        let timestamp = await cacheManager.getCacheTimestamp(for: "nonexistent_key_test_12345")
        XCTAssertNil(timestamp, "Timestamp should be nil for non-existent key")
    }

    func testCacheValidityReturnsFalseForRandomKey() async {
        let randomKey = "test_random_\(UUID().uuidString)"
        let isValid = await cacheManager.isCacheValid(for: randomKey)
        XCTAssertFalse(isValid)
    }

    // MARK: - Cache Key Consistency Tests

    func testLibrariesCacheKeyIsConsistent() async {
        // The cache uses consistent file names for each type of cached data
        // This test verifies the expected behavior
        let librariesKey = "libraries_cache.json"

        // Initially should not be valid (unless there's cached data from app usage)
        let timestamp = await cacheManager.getCacheTimestamp(for: librariesKey)

        // If timestamp exists, validity should be true (within 1 year TTL)
        if let timestamp = timestamp {
            let isValid = await cacheManager.isCacheValid(for: librariesKey)
            let age = Date().timeIntervalSince(timestamp)

            // Cache validity is 1 year
            if age < 365 * 24 * 60 * 60 {
                XCTAssertTrue(isValid, "Cache should be valid if timestamp is within TTL")
            }
        }
    }

    func testHubsCacheKeyIsConsistent() async {
        let hubsKey = "hubs_cache.json"
        let timestamp = await cacheManager.getCacheTimestamp(for: hubsKey)

        if let timestamp = timestamp {
            let isValid = await cacheManager.isCacheValid(for: hubsKey)
            let age = Date().timeIntervalSince(timestamp)

            if age < 365 * 24 * 60 * 60 {
                XCTAssertTrue(isValid)
            }
        }
    }

    // MARK: - Cache File Name Pattern Tests

    func testMoviesCacheKeyPattern() async {
        // Movies cache uses pattern: movies_<libraryKey>.json
        let libraryKey = "test_lib_123"
        let expectedFileName = "movies_\(libraryKey).json"

        // Just verify the cache returns false for non-existent library
        let isValid = await cacheManager.isCacheValid(for: expectedFileName)
        XCTAssertFalse(isValid, "Non-existent library cache should be invalid")
    }

    func testShowsCacheKeyPattern() async {
        // Shows cache uses pattern: shows_<libraryKey>.json
        let libraryKey = "test_lib_456"
        let expectedFileName = "shows_\(libraryKey).json"

        let isValid = await cacheManager.isCacheValid(for: expectedFileName)
        XCTAssertFalse(isValid, "Non-existent library cache should be invalid")
    }

    // MARK: - Actor Isolation Tests

    func testCacheManagerIsActorIsolated() async {
        // This test verifies that CacheManager methods can be called concurrently
        // without data races (actor isolation ensures this)
        async let validity1 = cacheManager.isCacheValid(for: "test_key_1")
        async let validity2 = cacheManager.isCacheValid(for: "test_key_2")
        async let validity3 = cacheManager.isCacheValid(for: "test_key_3")

        let results = await [validity1, validity2, validity3]

        // All should be false (non-existent keys)
        XCTAssertTrue(results.allSatisfy { $0 == false })
    }

    func testConcurrentTimestampReads() async {
        // Verify concurrent reads don't cause issues
        async let ts1 = cacheManager.getCacheTimestamp(for: "key1")
        async let ts2 = cacheManager.getCacheTimestamp(for: "key2")
        async let ts3 = cacheManager.getCacheTimestamp(for: "key3")

        let _ = await (ts1, ts2, ts3)
        // Test passes if no crashes or deadlocks occur
    }
}
