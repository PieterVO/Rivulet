# Native ASS Subtitle Styling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render embedded ASS/SSA subtitles with their authored styling (fonts, colors, outlines, positioning, `\an`/`\pos`, multi-region signs) on the aether VOD route, while keeping SRT/VTT and all other text formats on the existing system-caption overlay — so ASS looks the way its author intended and plain text still follows Apple TV caption settings.

**Architecture:** AetherEngine 5.23.3 already supports host-driven ASS: opting into `LoadOptions.preserveASSMarkup` makes it emit raw ASS event lines (`.text` cues carrying `ReadOrder,Layer,...,Text`) plus a `TrackInfo.assHeader`, and it ships `ASSScriptBuilder` to reassemble a complete, timed ASS script from those. We feed that script to [swift-ass-renderer](https://github.com/mihai8804858/swift-ass-renderer) (a libass wrapper, MIT, tvOS 15+), which composites frames onto a UIView we overlay on the player. A route/format switch decides per-playback whether the ASS overlay or the existing `AetherSubtitleOverlayView` is active. Nothing about SRT/VTT/PGS/DVB changes.

**Tech Stack:** Swift 6, UIKit + SwiftUI (tvOS 26), AetherEngine (`preserveASSMarkup`, `assHeader`, `ASSScriptBuilder`, `SubtitleImage`), swift-ass-renderer (`AssSubtitlesRenderer`, `AssSubtitlesView`, `FontConfig`), Combine, MediaAccessibility.

## Global Constraints

- **tvOS 26+ / Swift 6** — the app deployment target is `TVOS_DEPLOYMENT_TARGET = 26.0`. Do NOT raise or lower it (embedded FFmpeg framework `MinimumOSVersion` must stay >= target). swift-ass-renderer requires tvOS 15+, comfortably below.
- **AetherEngine is UPSTREAM, pinned `exactVersion`.** Do NOT edit engine sources. The engine already exposes everything this plan needs at 5.23.3 (`preserveASSMarkup` #30, `assHeader`, `ASSScriptBuilder` #48). No engine bump is required for this feature. (Note: Package.resolved currently shows 5.23.3 while CLAUDE.md/memory say 5.20.2 — verify the pin before starting; if it is below 5.23.3, use the `aether-update` skill first, because `preserveASSMarkup`/`ASSScriptBuilder` must be present.)
- **UIKit is the default on primary surfaces.** The player chrome is UIKit; the subtitle overlays are SwiftUI hosted inside the player container. The ASS overlay is UIKit (`AssSubtitlesView` is a `PlatformView`/`UIView`) hosted the same way the existing overlays are.
- **New dependency licensing:** swift-ass-renderer is MIT; its `swift-libass` binary is LGPL libass. Both are license-compatible with the app (already ships FFmpeg LGPL + libdovi MIT). Add SPDX/attribution entries (see Task 8). Confirm libdovi/FFmpeg attribution precedent in `OpenSourceLicenses.swift`.
- **App size:** swift-libass adds a prebuilt libass binary (an xcframework via SwiftPM). This is real added binary weight; it is the price of correct ASS and there is no host-only alternative. Note it in the changelog/PR, do not try to avoid it.
- **Do NOT touch the SRT/VTT/PGS/DVB paths.** `SubtitleOverlayView` (hls route), `SubtitleManager`/`SubtitleParser` text stripping, and the `.image`/`.richText` cue rendering in `AetherSubtitleOverlayView` all stay exactly as they are. This feature is additive and gated to ASS text tracks on the aether route.
- **Naming/copy:** repo is public — keep commit messages short and plain. Every AetherEngine bump (if one ends up needed) gets a changelog line. Settings rows are title-only with descriptions in the left panel (`SettingsDescriptors`).

---

## File Structure

New files (all under `Rivulet/`):

- `Services/Plex/Playback/Subtitles/ASSStyledSubtitleController.swift` — owns the `AssSubtitlesRenderer` + `ASSScriptBuilder`, subscribes to the engine's raw-event cues, feeds the reassembled script to the renderer, and drives `setTimeOffset` off the playback clock. One clear responsibility: bridge engine ASS-markup cues → libass renderer.
- `Views/Player/Aether/ASSStyledSubtitleOverlayView.swift` — a thin `UIViewRepresentable` (SwiftUI) that hosts the controller's `AssSubtitlesView` and sizes it to the video rect. Mirrors how `AetherSubtitleOverlayView` is placed.
- `Services/Plex/Playback/Subtitles/SubtitleRenderMode.swift` — a small enum + a pure decision function: given the active subtitle track's codec and the route, return `.assStyled` or `.systemStyled`. Keeps the switch testable in isolation.

Modified files:

- `Services/Plex/Playback/AetherPlayer.swift` — set `preserveASSMarkup: true` in the `LoadOptions` it builds; expose the active track's `assHeader` and codec so the controller/switch can read them; expose the playback clock the ASS controller needs (it already publishes position).
- `Views/Player/Aether/` host site (the view that today places `AetherSubtitleOverlayView`) — add the `ASSStyledSubtitleOverlayView` alongside it and show exactly one based on `SubtitleRenderMode`.
- `Rivulet.xcodeproj` / SwiftPM — add the swift-ass-renderer package dependency.
- `OpenSourceLicenses.swift` — add swift-ass-renderer + libass attributions.
- `Views/Components/WhatsNewView.swift` — changelog entry.

---

## Interfaces available from AetherEngine 5.23.3 (do not re-implement — consume)

These exist in the pinned engine; tasks below consume them. Signatures verified against the resolved SwiftPM checkout.

- `LoadOptions.preserveASSMarkup: Bool` (default `false`) — opt in to raw ASS event emission. `PlayerState.swift:207-208`.
- `TrackInfo.assHeader: String?` — `[Script Info]` + `[V4+ Styles]` + `[Events]` format line; nil for non-ASS. `PlayerState.swift:516-517`.
- `SubtitleCue.body`: `.text(String)` | `.image(SubtitleImage)` | `.richText([SubtitleTextRun])`. With `preserveASSMarkup` set, ASS cues arrive as `.text` carrying the raw libavcodec event line (`ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`), timing on `startTime`/`endTime`. `PlayerState.swift:631-660`, `Decoder/SubtitleDecoder.swift:25-30`.
- `ASSScriptBuilder(header: String)` with `func add(rawEventText: String, start: Double, end: Double) -> Bool` and a way to emit the full script string; dedupes by content. `Subtitles/ASSScriptBuilder.swift`. Read the file for the exact "emit full script" accessor name before Task 3 and use it verbatim.

## Interfaces available from swift-ass-renderer (verified against source, tag ≈ 1.3.x)

- `AssSubtitlesRenderer` — `public convenience init(fontConfig: FontConfig, ...)`; `func loadTrack(content: String)`; `func reloadTrack(content: String)`; `func freeTrack()`; `func setCanvasSize(_ size: CGSize, scale: CGFloat)`; `func setTimeOffset(_ offset: TimeInterval)`; `func framesPublisher() -> AnyPublisher<ProcessedImage?, Never>`. `Renderer/AssSubtitlesRenderer.swift`.
- `AssSubtitlesView(renderer: AssSubtitlesRenderer, scale: CGFloat = ...)` — a `UIView` that draws frames from the renderer; add as a subview and size it. `Overlay/AssSubtitlesView.swift`.
- `FontConfig(init: ...)` with a `FontProvider` (system fonts vs. a bundled fonts dir). `FontConfig/FontConfig.swift`. Read the init signature in source before Task 2 and pass values verbatim.

---

### Task 1: Add the swift-ass-renderer dependency and prove it links

**Files:**
- Modify: `Rivulet.xcodeproj/project.pbxproj` (SwiftPM package ref) and `Rivulet.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
- Modify: `Rivulet/OpenSourceLicenses.swift` (attribution stub, completed in Task 8)

**Interfaces:**
- Consumes: nothing.
- Produces: `import SwiftAssRenderer` compiles and links against the app target.

- [ ] **Step 1: Add the package**

In Xcode: File → Add Package Dependencies → `https://github.com/mihai8804858/swift-ass-renderer`, pin `.upToNextMajor(from: "1.3.0")` (verify latest tag at add time). Add the `SwiftAssRenderer` product to the `Rivulet` app target only.

- [ ] **Step 2: Write a link-proof compile check**

Add a temporary file `Rivulet/_ASSLinkCheck.swift`:

```swift
import SwiftAssRenderer
import Foundation

// Temporary: proves SwiftAssRenderer links. Deleted in Step 4.
private func _assLinkCheck() {
    _ = FontConfig.self
    _ = AssSubtitlesRenderer.self
}
```

- [ ] **Step 3: Build for the tvOS Simulator**

Run: `xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath /tmp/rivulet-ass-dd build`
Expected: BUILD SUCCEEDED. (Use a scratch `-derivedDataPath` per project convention to avoid colliding with an open Xcode.)

- [ ] **Step 4: Delete the link-proof file**

```bash
rm "Rivulet/_ASSLinkCheck.swift"
```

- [ ] **Step 5: Commit**

```bash
git add Rivulet.xcodeproj Rivulet/OpenSourceLicenses.swift
git commit -m "chore: add swift-ass-renderer dependency"
```

---

### Task 2: Font configuration

**Files:**
- Create: `Rivulet/Services/Plex/Playback/Subtitles/ASSFontConfig.swift`
- Test: `RivuletTests/Unit/Playback/ASSFontConfigTests.swift`

**Interfaces:**
- Consumes: swift-ass-renderer `FontConfig`, `FontProvider`.
- Produces: `enum ASSFontConfig { static func make() -> FontConfig }` — returns a `FontConfig` using the tvOS system font provider and a sane default family, reused by the controller.

Read `FontConfig/FontConfig.swift` in the dependency source for the exact `init` parameter names before writing this — pass them verbatim. libass needs at least one embeddable/system font to render; if the `FontProvider.system` path is insufficient on tvOS, bundle a permissively-licensed fallback (e.g. a Noto/DejaVu family) under `Rivulet/Resources/Fonts/` and point `FontConfig` at it. Decide this by running Task 5's on-screen check; wire the fallback here if system fonts don't resolve.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import SwiftAssRenderer
@testable import Rivulet

final class ASSFontConfigTests: XCTestCase {
    func test_make_returnsUsableConfig() {
        let config = ASSFontConfig.make()
        // FontConfig has no public equality; assert it constructs and
        // the default family is non-empty via the property we expose.
        XCTAssertFalse(ASSFontConfig.defaultFamily.isEmpty)
        _ = config // constructs without throwing
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:RivuletTests/ASSFontConfigTests`
Expected: FAIL — `ASSFontConfig` not defined.

- [ ] **Step 3: Implement**

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley
import Foundation
import SwiftAssRenderer

/// FontConfig for the libass ASS renderer. System fonts by default;
/// swap to a bundled fallback family if tvOS system fonts don't resolve.
enum ASSFontConfig {
    static let defaultFamily = "Helvetica Neue"

    static func make() -> FontConfig {
        // NOTE: match the real FontConfig init from the dependency source.
        FontConfig(fontProvider: .system, defaultFontName: defaultFamily)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:RivuletTests/ASSFontConfigTests`
Expected: PASS. If it fails to compile on the `FontConfig(...)` line, the init signature differs — read `FontConfig.swift` in the checkout and correct the call.

- [ ] **Step 5: Commit**

```bash
git add Rivulet/Services/Plex/Playback/Subtitles/ASSFontConfig.swift RivuletTests/Unit/Playback/ASSFontConfigTests.swift
git commit -m "feat: ASS renderer font config"
```

---

### Task 3: Render-mode decision (pure, testable)

**Files:**
- Create: `Rivulet/Services/Plex/Playback/Subtitles/SubtitleRenderMode.swift`
- Test: `RivuletTests/Unit/Playback/SubtitleRenderModeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum SubtitleRenderMode { case assStyled, systemStyled }`
  - `static func SubtitleRenderMode.resolve(codec: String?, isAetherRoute: Bool, hasASSHeader: Bool) -> SubtitleRenderMode`

The rule: ASS styling only when route is aether AND codec is `ass`/`ssa` AND an `assHeader` is present. Everything else → `.systemStyled` (the existing overlay). This is the single gate that keeps SRT/VTT/PGS/DVB untouched.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Rivulet

final class SubtitleRenderModeTests: XCTestCase {
    func test_assOnAetherWithHeader_isASSStyled() {
        XCTAssertEqual(SubtitleRenderMode.resolve(codec: "ass", isAetherRoute: true, hasASSHeader: true), .assStyled)
        XCTAssertEqual(SubtitleRenderMode.resolve(codec: "ssa", isAetherRoute: true, hasASSHeader: true), .assStyled)
    }
    func test_assWithoutHeader_isSystemStyled() {
        XCTAssertEqual(SubtitleRenderMode.resolve(codec: "ass", isAetherRoute: true, hasASSHeader: false), .systemStyled)
    }
    func test_assOnHLSRoute_isSystemStyled() {
        XCTAssertEqual(SubtitleRenderMode.resolve(codec: "ass", isAetherRoute: false, hasASSHeader: true), .systemStyled)
    }
    func test_srt_isSystemStyled() {
        XCTAssertEqual(SubtitleRenderMode.resolve(codec: "subrip", isAetherRoute: true, hasASSHeader: false), .systemStyled)
    }
    func test_nilCodec_isSystemStyled() {
        XCTAssertEqual(SubtitleRenderMode.resolve(codec: nil, isAetherRoute: true, hasASSHeader: true), .systemStyled)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:RivuletTests/SubtitleRenderModeTests`
Expected: FAIL — type not defined.

- [ ] **Step 3: Implement**

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley
import Foundation

/// Which overlay renders the active subtitle track.
enum SubtitleRenderMode: Equatable {
    /// libass-composited ASS/SSA with authored styling (aether route only).
    case assStyled
    /// The system-caption overlay (SRT/VTT/PGS/DVB, and ASS on the hls route).
    case systemStyled

    static func resolve(codec: String?, isAetherRoute: Bool, hasASSHeader: Bool) -> SubtitleRenderMode {
        guard isAetherRoute, hasASSHeader else { return .systemStyled }
        switch codec?.lowercased() {
        case "ass", "ssa": return .assStyled
        default: return .systemStyled
        }
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run the same command. Expected: PASS (all 5).

- [ ] **Step 5: Commit**

```bash
git add Rivulet/Services/Plex/Playback/Subtitles/SubtitleRenderMode.swift RivuletTests/Unit/Playback/SubtitleRenderModeTests.swift
git commit -m "feat: subtitle render-mode gate"
```

---

### Task 4: ASS styled subtitle controller

**Files:**
- Create: `Rivulet/Services/Plex/Playback/Subtitles/ASSStyledSubtitleController.swift`
- Test: `RivuletTests/Unit/Playback/ASSStyledSubtitleControllerTests.swift`

**Interfaces:**
- Consumes: `ASSFontConfig.make()`; AetherEngine `ASSScriptBuilder(header:)`; swift-ass-renderer `AssSubtitlesRenderer`, `AssSubtitlesView`.
- Produces:
  - `@MainActor final class ASSStyledSubtitleController`
  - `init(assHeader: String)`
  - `var view: AssSubtitlesView { get }`
  - `func ingest(rawEventText: String, start: Double, end: Double)` — appends to the builder and reloads the renderer track when a new event was added
  - `func setTime(_ seconds: Double)` — forwards to `renderer.setTimeOffset`
  - `func setCanvas(size: CGSize, scale: CGFloat)` — forwards to `renderer.setCanvasSize`
  - `func reset()` — frees the track and clears the builder

Confine to `@MainActor` (matches the engine's cue-sink discipline noted in the subtitle-dedupe memory and `ASSScriptBuilder`'s "not thread-safe; one actor" contract). Rebuild-and-reload on each new event is correct because `ASSScriptBuilder` dedupes and the reload preserves offset.

- [ ] **Step 1: Write the failing test**

Test the builder-driven behavior without a live renderer by asserting the controller forwards distinct events and dedupes repeats. Inject a seam: give the controller an internal `eventCount` passthrough from the builder.

```swift
import XCTest
@testable import Rivulet

@MainActor
final class ASSStyledSubtitleControllerTests: XCTestCase {
    func test_ingest_dedupesIdenticalEvents() {
        let c = ASSStyledSubtitleController(assHeader: Self.minimalHeader)
        c.ingest(rawEventText: "0,0,Default,,0,0,0,,Hello", start: 1.0, end: 2.0)
        c.ingest(rawEventText: "0,0,Default,,0,0,0,,Hello", start: 1.0, end: 2.0)
        XCTAssertEqual(c.eventCount, 1)
    }
    func test_ingest_keepsDistinctEvents() {
        let c = ASSStyledSubtitleController(assHeader: Self.minimalHeader)
        c.ingest(rawEventText: "0,0,Default,,0,0,0,,Hello", start: 1.0, end: 2.0)
        c.ingest(rawEventText: "0,0,Default,,0,0,0,,World", start: 3.0, end: 4.0)
        XCTAssertEqual(c.eventCount, 2)
    }

    static let minimalHeader = """
    [Script Info]
    ScriptType: v4.00+
    [V4+ Styles]
    Format: Name, Fontname, Fontsize
    Style: Default,Helvetica,48
    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    """
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:RivuletTests/ASSStyledSubtitleControllerTests`
Expected: FAIL — type not defined.

- [ ] **Step 3: Implement**

Read `ASSScriptBuilder.swift` in the checkout for the exact "full script" accessor (the doc comment names swift-ass-renderer `loadTrack(content:)` as the consumer). Use it verbatim where the code below says `builder.<fullScript>`.

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley
import Foundation
import SwiftAssRenderer
import AetherEngine

/// Bridges AetherEngine's raw ASS-markup cues into a libass renderer.
/// One instance per playback; MainActor-confined (ASSScriptBuilder is
/// not thread-safe and the engine's cue sink runs on MainActor).
@MainActor
final class ASSStyledSubtitleController {
    let view: AssSubtitlesView
    private let renderer: AssSubtitlesRenderer
    private let builder: ASSScriptBuilder

    var eventCount: Int { builder.eventCount }

    init(assHeader: String) {
        self.builder = ASSScriptBuilder(header: assHeader)
        self.renderer = AssSubtitlesRenderer(fontConfig: ASSFontConfig.make())
        self.view = AssSubtitlesView(renderer: renderer)
    }

    func ingest(rawEventText: String, start: Double, end: Double) {
        let added = builder.add(rawEventText: rawEventText, start: start, end: end)
        guard added else { return }
        renderer.reloadTrack(content: builder.fullScript) // reloadTrack preserves offset
    }

    func setTime(_ seconds: Double) {
        renderer.setTimeOffset(seconds)
    }

    func setCanvas(size: CGSize, scale: CGFloat) {
        renderer.setCanvasSize(size, scale: scale)
    }

    func reset() {
        renderer.freeTrack()
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run the same command. Expected: PASS (both). If it fails to compile on `builder.fullScript`, replace with the real accessor name from `ASSScriptBuilder.swift`.

- [ ] **Step 5: Commit**

```bash
git add Rivulet/Services/Plex/Playback/Subtitles/ASSStyledSubtitleController.swift RivuletTests/Unit/Playback/ASSStyledSubtitleControllerTests.swift
git commit -m "feat: ASS styled subtitle controller"
```

---

### Task 5: Enable preserveASSMarkup and surface header/codec/clock from AetherPlayer

**Files:**
- Modify: `Rivulet/Services/Plex/Playback/AetherPlayer.swift`
- Test: `RivuletTests/Unit/Playback/AetherPlayerASSTests.swift` (if AetherPlayer is unit-constructable with a mock engine; otherwise this task is verified in Task 7's integration check and skips its own unit test — state which in the commit)

**Interfaces:**
- Consumes: AetherEngine `LoadOptions.preserveASSMarkup`, `TrackInfo.assHeader`.
- Produces on `AetherPlayer`:
  - the `LoadOptions` it builds now sets `preserveASSMarkup: true`
  - `var activeSubtitleASSHeader: String?` — the `assHeader` of the currently-selected subtitle track (nil if none/off/non-ASS)
  - `var activeSubtitleCodec: String?` — codec string of the selected subtitle track
  - (position/clock is already published; confirm the property name the overlay host reads)

Find where `AetherPlayer` constructs `LoadOptions` and add `preserveASSMarkup: true`. Find where it tracks the selected subtitle `TrackInfo` and expose its `assHeader`/`codec`. This flag is safe globally: per engine docs it only affects ASS/SSA codecs; SRT/VTT/mov_text are unchanged, and the existing `.text` rendering for non-ASS is byte-identical.

- [ ] **Step 1: Locate the LoadOptions construction**

Run: `grep -n "LoadOptions(" Rivulet/Services/Plex/Playback/AetherPlayer.swift`
Read the surrounding call and the selected-track tracking.

- [ ] **Step 2: Write the failing test (if constructable)**

```swift
import XCTest
@testable import Rivulet
@testable import AetherEngine

final class AetherPlayerASSTests: XCTestCase {
    func test_loadOptions_enablePreserveASSMarkup() {
        // Assert the LoadOptions the player builds has preserveASSMarkup == true.
        // Use whatever seam AetherPlayer exposes for its built options;
        // if none exists, add an internal `makeLoadOptions(...)` and test that.
        let options = AetherPlayer.makeLoadOptions(/* minimal args */)
        XCTAssertTrue(options.preserveASSMarkup)
    }
}
```

- [ ] **Step 3: Run to verify failure**

Run: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -only-testing:RivuletTests/AetherPlayerASSTests`
Expected: FAIL.

- [ ] **Step 4: Implement**

Set `preserveASSMarkup: true` in the built `LoadOptions`. Add the two computed/published accessors reading the selected `TrackInfo`:

```swift
/// ASS header of the selected subtitle track, nil unless it is ASS/SSA.
var activeSubtitleASSHeader: String? { selectedSubtitleTrack?.assHeader }
/// Codec of the selected subtitle track.
var activeSubtitleCodec: String? { selectedSubtitleTrack?.codec }
```

(Adapt `selectedSubtitleTrack` to the real property name.)

- [ ] **Step 5: Run to verify pass**

Run the same command. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Rivulet/Services/Plex/Playback/AetherPlayer.swift RivuletTests/Unit/Playback/AetherPlayerASSTests.swift
git commit -m "feat: opt into ASS markup and expose subtitle header"
```

---

### Task 6: SwiftUI overlay host for the ASS view

**Files:**
- Create: `Rivulet/Views/Player/Aether/ASSStyledSubtitleOverlayView.swift`

**Interfaces:**
- Consumes: `ASSStyledSubtitleController` (its `view`, `setCanvas`).
- Produces: `struct ASSStyledSubtitleOverlayView: UIViewRepresentable` — hosts `controller.view`, sizes it to the video rect, and calls `setCanvas` on size changes.

Place it the same way `AetherSubtitleOverlayView` is placed over the video (same rect). libass composites at the canvas size, so `setCanvas(size:scale:)` must track the on-screen video rect and display scale.

- [ ] **Step 1: Implement**

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley
import SwiftUI
import SwiftAssRenderer

/// Hosts the libass AssSubtitlesView over the player video rect.
struct ASSStyledSubtitleOverlayView: UIViewRepresentable {
    let controller: ASSStyledSubtitleController
    let videoSize: CGSize

    func makeUIView(context: Context) -> AssSubtitlesView {
        let v = controller.view
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: AssSubtitlesView, context: Context) {
        guard videoSize.width > 0, videoSize.height > 0 else { return }
        let scale = uiView.window?.screen.scale ?? 2.0
        controller.setCanvas(size: videoSize, scale: scale)
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath /tmp/rivulet-ass-dd build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Rivulet/Views/Player/Aether/ASSStyledSubtitleOverlayView.swift
git commit -m "feat: ASS subtitle overlay host view"
```

---

### Task 7: Wire the switch into the player and drive it

**Files:**
- Modify: the aether overlay host site that today instantiates `AetherSubtitleOverlayView` (find it — see Step 1).

**Interfaces:**
- Consumes: `SubtitleRenderMode.resolve`, `AetherPlayer.activeSubtitleASSHeader`/`activeSubtitleCodec`/position, `ASSStyledSubtitleController`, `ASSStyledSubtitleoverlayView`, engine raw-event cues.
- Produces: exactly one overlay visible at a time; ASS text cues (raw event lines) routed to the controller; playback time forwarded via `setTime`.

The wiring:
1. Compute `mode = SubtitleRenderMode.resolve(codec: player.activeSubtitleCodec, isAetherRoute: true, hasASSHeader: player.activeSubtitleASSHeader != nil)`.
2. When `mode == .assStyled`: build one `ASSStyledSubtitleController(assHeader:)`; for each engine `.text` cue, call `controller.ingest(rawEventText: cue.text, start: cue.startTime, end: cue.endTime)`; on each position tick call `controller.setTime(position)`; show `ASSStyledSubtitleOverlayView`, hide `AetherSubtitleOverlayView`.
3. When `mode == .systemStyled`: unchanged — the existing `.text`/`.richText`/`.image` path renders in `AetherSubtitleOverlayView`; the ASS controller is nil/hidden.
4. On track change or teardown: `controller.reset()` and rebuild if needed (a new track = new header).

Critical: in `.assStyled` mode the engine's `.text` cues carry raw event lines, NOT display text. They must go ONLY to the controller, never to `AetherSubtitleOverlayView` (which would show the raw `0,0,Default,,...` string). The mode switch is what prevents that.

- [ ] **Step 1: Find the host site**

Run: `grep -rn "AetherSubtitleOverlayView(" Rivulet/Views`
Read that view and how it receives `SubtitleModel`/cues and the video rect.

- [ ] **Step 2: Add the mode-driven branch**

In the host view, add `@State` (or view-model) storage for an optional `ASSStyledSubtitleController` and the resolved `mode`. Build the controller when `mode` becomes `.assStyled` with a non-nil header; tear it down otherwise. Route cues and time per the wiring above. Show exactly one overlay via the mode.

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath /tmp/rivulet-ass-dd build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: On-device / on-simulator visual check (provisional in Simulator)**

Play an MKV with an embedded ASS track that uses positioning (an anime episode with `{\an8}` signs is the canonical test). Verify: ASS renders at authored position/font/color; simultaneous top-sign + bottom-dialogue both appear; switching to an SRT track falls back to the system overlay; no raw `0,0,Default` text ever shows. Use the `playback-test` skill / harness (`subtitle_track_test_content` memory lists ASS-bearing keys: 183665, 209281, 12974/63657). Say "verified on device" only after a real Apple TV check — Simulator subtitle rendering is provisional per CLAUDE.md.

- [ ] **Step 5: Commit**

```bash
git add Rivulet/Views
git commit -m "feat: render embedded ASS subtitles with authored styling"
```

---

### Task 8: Attribution, changelog, and cleanup

**Files:**
- Modify: `Rivulet/OpenSourceLicenses.swift`
- Modify: `Rivulet/Views/Components/WhatsNewView.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: license attribution for swift-ass-renderer (MIT) + libass (LGPL), and a user-facing changelog line.

- [ ] **Step 1: Add attributions**

Add entries to `OpenSourceLicenses.swift` mirroring the existing FFmpeg/libdovi entries: swift-ass-renderer (MIT, mihai8804858), libass (LGPL-2.1+), swift-libass (packaging). Match the existing struct shape.

- [ ] **Step 2: Add the changelog entry**

Use the `rivulet-changelog` skill. Add to the `changelogs` array in `WhatsNewView.swift`, keyed by the current build-qualified version, newest first. Example bullet (plain, user-facing, no em dashes):

```
Embedded ASS and SSA subtitles now keep their original styling and positioning. Plain text subtitles still follow your Apple TV caption settings.
```

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath /tmp/rivulet-ass-dd build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Run the full suite**

Run: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV'`
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add Rivulet/OpenSourceLicenses.swift Rivulet/Views/Components/WhatsNewView.swift
git commit -m "docs: attribute swift-ass-renderer and note ASS styling"
```

---

## Explicitly out of scope (do NOT build)

- **An in-app SRT/subtitle styling settings panel.** SRT carries no authored styling; the system caption settings are the correct and complete owner. This is a deliberate product decision (Apple-esque, avoid settings bloat), not an oversight. If a user asks, the answer is Settings → Accessibility → Subtitles on the Apple TV.
- **Extending MediaAccessibility per-property override to font/size/edge for the ASS path.** ASS renders as authored by design; a low-vision user who needs to override still has the option to select the SRT/plain track or the system overlay. Do not add a "force system style over ASS" toggle unless a real accessibility request lands — it fights the whole point of preserving ASS.
- **ASS on the hls route.** The hls route is a server transcode fallback; ASS styling there is not worth the complexity. `SubtitleRenderMode.resolve` already gates ASS styling to the aether route.
- **Live TV ASS styling.** Broadcast subtitles are teletext/DVB, already handled by the color-run and bitmap paths. No ASS there.
- **Editing AetherEngine.** Everything needed already exists at 5.23.3.

## Self-Review notes

- Spec coverage: the discussion's core ask (preserve embedded ASS styling incl. positioning) is Tasks 3–7; the "SRT in-app panel" ask is explicitly declined (out-of-scope section); the color-override behavior on other paths is untouched by design.
- The load-bearing risk is Task 7's cue routing: in `.assStyled` mode the engine's `.text` cues are raw event lines and must never reach the system overlay. The mode gate is the single guard; the on-device check in Task 7 Step 4 is where that's proven.
- Types are consistent across tasks: `SubtitleRenderMode.resolve`, `ASSStyledSubtitleController.ingest/setTime/setCanvas/reset`, `AetherPlayer.activeSubtitleASSHeader/activeSubtitleCodec` are defined once and consumed by name.
- Two accessor names must be confirmed against source before coding (flagged inline): `ASSScriptBuilder`'s full-script accessor, and swift-ass-renderer's `FontConfig` init parameters. Both are read-then-use, not guessed.
