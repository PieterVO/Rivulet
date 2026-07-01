import Testing
import UIKit
@testable import Rivulet

@Suite("PlayerProgressBarView marker coloring")
struct PlayerProgressBarViewTests {
    @Test("intro marker is blue")
    func introMarkerColor() {
        let marker = PlexMarker(type: "intro", startTimeOffset: 0, endTimeOffset: 30000)
        #expect(PlayerProgressBarView.color(for: marker) == UIColor.systemBlue)
    }

    @Test("credits marker is purple")
    func creditsMarkerColor() {
        let marker = PlexMarker(type: "credits", startTimeOffset: 0, endTimeOffset: 30000)
        #expect(PlayerProgressBarView.color(for: marker) == UIColor.systemPurple)
    }

    @Test("commercial marker is yellow")
    func commercialMarkerColor() {
        let marker = PlexMarker(type: "commercial", startTimeOffset: 0, endTimeOffset: 30000)
        #expect(PlayerProgressBarView.color(for: marker) == UIColor.systemYellow)
    }
}
