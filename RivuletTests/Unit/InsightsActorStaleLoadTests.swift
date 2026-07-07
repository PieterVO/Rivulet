//
//  InsightsActorStaleLoadTests.swift
//  RivuletTests
//
//  Integration coverage for the stale-load guard behind the in-panel actor
//  view (Docs/superpowers/plans/2026-07-07-insights-in-panel-actor.md, Task
//  B/D). `InsightsActorLoadCoordinatorTests` already covers the token
//  bookkeeping in isolation; this test drives the REAL
//  `InsightsPanelContainerView` + `InsightsActorView` wiring end to end
//  through the injectable `PersonFilmographyProviding` seam, to prove a
//  slow `load` that resolves AFTER the user has moved on (backed out to the
//  cast list, or switched to a different actor) never populates the actor
//  view with the late, now-irrelevant result.
//

import XCTest
@testable import Rivulet

@MainActor
private final class ManuallyResolvableFilmographyProvider: PersonFilmographyProviding {
    private var continuations: [String: CheckedContinuation<PersonDetail, Error>] = [:]

    /// Resolves the in-flight `load(person:)` call for `person.id`, if one
    /// is currently awaited. No-op if none is pending (e.g. the call was
    /// never made, or was already resolved).
    func resolve(personID: String, with detail: PersonDetail) {
        continuations.removeValue(forKey: personID)?.resume(returning: detail)
    }

    /// `InsightsPanelContainerView.crossfadeToActor` spawns a plain `Task {}`
    /// from its own (MainActor-isolated, `UIView` is `@MainActor` by
    /// default) body, which inherits MainActor — so this `nonisolated` func
    /// actually runs its body on the main actor already. Registering the
    /// continuation SYNCHRONOUSLY (no inner `Task` hop) is what lets the
    /// test call `resolve(...)` immediately afterwards with no race: by the
    /// time `crossfadeToActor`'s `await load(...)` line has been reached and
    /// suspended, this closure has already run and stored the continuation.
    nonisolated func load(person: MediaPerson) async throws -> PersonDetail {
        try await withCheckedThrowingContinuation { continuation in
            MainActor.assumeIsolated {
                self.continuations[person.id] = continuation
            }
        }
    }
}

@MainActor
final class InsightsActorStaleLoadTests: XCTestCase {

    private func makePerson(_ id: String) -> MediaPerson {
        MediaPerson(id: id, name: "Actor \(id)", role: nil, imageURL: nil)
    }

    private func makeDetail(for person: MediaPerson) -> PersonDetail {
        PersonDetail(id: person.id, name: person.name, biography: "Bio for \(person.name)",
                     portraitURL: nil, movies: [], shows: [])
    }

    /// A slow load that resolves AFTER the user has already backed out to
    /// the cast list must not populate the (now torn-down) actor view.
    func test_lateLoadAfterReturnToList_isDropped() async throws {
        let provider = ManuallyResolvableFilmographyProvider()
        let personA = makePerson("A")
        let container = InsightsPanelContainerView(cast: [personA], provider: provider)

        container.crossfadeToActor(personA)
        let actorViewForA = try XCTUnwrap(container.actorView)
        XCTAssertNil(actorViewForA.detail, "no result has resolved yet")

        // User backs out to the cast list before A's load resolves. Note:
        // `state`/`coordinator.cancel()` fire synchronously inside
        // `reverseCrossfadeToList`, but the actual `actorView = nil` teardown
        // is deferred to the 0.2s crossfade animation's completion block —
        // wait past that before asserting on it below.
        container.reverseCrossfadeToList()

        // A's slow load resolves now — late, after the user moved on.
        provider.resolve(personID: personA.id, with: makeDetail(for: personA))
        // Let the awaiting Task inside crossfadeToActor observe the
        // continuation's result and run its post-await guard.
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(actorViewForA.detail,
                      "a load that resolves after returning to the list must be dropped, not applied")

        // Wait past the reverse-crossfade's animation completion (0.2s) so
        // the deferred `actorView = nil` teardown has actually run.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(container.actorView, "the container should have torn down the actor view on return-to-list")
    }

    /// A slow load for the FIRST actor selected must not populate the
    /// SECOND actor's view when it resolves after the user switched.
    func test_lateLoadAfterSwitchingActors_isDroppedAndDoesNotLeakIntoNewActorView() async throws {
        let provider = ManuallyResolvableFilmographyProvider()
        let personA = makePerson("A")
        let personB = makePerson("B")
        let container = InsightsPanelContainerView(cast: [personA, personB], provider: provider)

        container.crossfadeToActor(personA)
        let actorViewForA = try XCTUnwrap(container.actorView)

        // User backs out and picks a different actor before A's load resolves.
        container.reverseCrossfadeToList()
        container.crossfadeToActor(personB)
        let actorViewForB = try XCTUnwrap(container.actorView)
        XCTAssertFalse(actorViewForA === actorViewForB, "switching actors must build a fresh actor view")

        // A's stale load resolves now.
        provider.resolve(personID: personA.id, with: makeDetail(for: personA))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(actorViewForA.detail, "the stale actor A view must never be populated")
        XCTAssertNil(actorViewForB.detail, "B's slow load hasn't resolved yet, so B must still be unpopulated")

        // B's load resolves — this one IS current and must apply normally.
        provider.resolve(personID: personB.id, with: makeDetail(for: personB))
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(actorViewForB.detail?.name, personB.name, "the current actor's own load must still apply")
        XCTAssertNil(actorViewForA.detail, "the stale actor A view must still never be populated")
    }
}
