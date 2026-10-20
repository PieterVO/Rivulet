// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

private final class StubFolderProvider: FolderProvider, @unchecked Sendable {
    var pages: [Int: Result<FolderPage, Error>] = [:]
    var asked: [Page] = []
    /// Holds a page until the test releases it.
    var gate: CheckedContinuation<Void, Never>?
    var gated: Int?

    func folderPage(in library: MediaLibrary, folder: MediaItemRef?, page: Page) async throws -> FolderPage {
        asked.append(page)
        let result = pages[page.offset] ?? .failure(MediaProviderError.notFound)
        if page.offset == gated { await withCheckedContinuation { gate = $0 } }
        return try result.get()
    }
}

@MainActor
final class FolderListingTests: XCTestCase {
    private let provider = StubFolderProvider()
    private let library = MediaLibrary(id: "lib", providerID: "stub", title: "Misc", kind: .mixed)
    private var changes: [FolderListing.Change] = []

    private func folder(_ id: String) -> FolderEntry {
        let ref = MediaItemRef(providerID: "stub", itemID: id)
        return FolderEntry(id: ref, title: id, content: .folder(ref, childCount: nil))
    }

    private func page(_ ids: [String], next: Int?) -> Result<FolderPage, Error> {
        .success(FolderPage(entries: ids.map(folder), nextPage: next.map { Page(offset: $0, limit: FolderListing.pageSize) }))
    }

    private func listing() -> FolderListing {
        let listing = FolderListing(folder: nil) { [provider, library] in (provider, library) }
        listing.onChange = { [weak self] in self?.changes.append($0) }
        return listing
    }

    func test_pagesAppend_andDedupeByID() async {
        provider.pages = [0: page(["a", "b"], next: 100), 100: page(["b", "c"], next: nil)]
        let listing = listing()
        await listing.loadFirst()?.value
        await listing.loadMore()?.value
        XCTAssertEqual(listing.entries.map(\.title), ["a", "b", "c"], "a duplicate row would crash the data source")
        XCTAssertNil(listing.loadMore(), "nothing left to ask for")
        XCTAssertEqual(provider.asked.map(\.offset), [0, 100])
        XCTAssertEqual(provider.asked.first?.limit, 100)
        guard case .appended(let range)? = changes.last else { return XCTFail("no append reported") }
        XCTAssertEqual(range, 2..<3)
    }

    func test_aStaleGenerationsPage_isDroppedAfterLoadFirst() async {
        provider.pages = [0: page(["old"], next: nil)]
        provider.gated = 0
        let listing = listing()
        let stale = listing.loadFirst()
        while provider.gate == nil { await Task.yield() }
        provider.gated = nil
        provider.pages = [0: page(["new"], next: nil)]
        let fresh = listing.loadFirst()
        provider.gate?.resume()
        await stale?.value
        await fresh?.value
        XCTAssertEqual(listing.entries.map(\.title), ["new"])
    }

    func test_aFailedPage_keepsLoadedEntries_andCanBeAskedAgain() async {
        provider.pages = [0: page(["a"], next: 100)]
        let listing = listing()
        await listing.loadFirst()?.value
        await listing.loadMore()?.value
        XCTAssertNotNil(listing.error)
        XCTAssertEqual(listing.entries.map(\.title), ["a"])
        guard case .failed? = changes.last else { return XCTFail("no failure reported") }

        provider.pages[100] = page(["b"], next: nil)
        await listing.loadMore()?.value
        XCTAssertNil(listing.error)
        XCTAssertEqual(listing.entries.map(\.title), ["a", "b"])
    }

    func test_refresh_keepsEntriesUntilTheNewOnesArrive_inOneRequest() async {
        provider.pages = [0: page(["a"], next: 100), 100: page(["b"], next: 200)]
        let listing = listing()
        await listing.loadFirst()?.value
        await listing.loadMore()?.value
        provider.pages = [0: page(["a", "b2"], next: 200)]
        provider.asked = []
        let task = listing.refresh()
        XCTAssertEqual(listing.entries.map(\.title), ["a", "b"], "rows stay while the refresh is in flight")
        await task?.value
        XCTAssertEqual(listing.entries.map(\.title), ["a", "b2"])
        XCTAssertEqual(provider.asked, [Page(offset: 0, limit: 100)])
        XCTAssertTrue(listing.hasMore)
    }

    func test_refreshDuringALoad_runsAfterIt() async {
        provider.pages = [0: page(["a"], next: 100), 100: page(["b"], next: nil)]
        let listing = listing()
        await listing.loadFirst()?.value
        provider.gated = 100
        let load = listing.loadMore()
        while provider.gate == nil { await Task.yield() }
        provider.gated = nil
        provider.pages = [0: page(["a", "b2"], next: nil)]
        XCTAssertNil(listing.refresh())
        provider.gate?.resume()
        await load?.value
        while listing.isLoading { await Task.yield() }
        XCTAssertEqual(listing.entries.map(\.title), ["a", "b2"])
    }
}
