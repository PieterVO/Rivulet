// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AetherSubtitleOverlayView.swift
//  Rivulet
//
//  SwiftUI overlay that renders subtitle cues from a SubtitleModel.
//  Mounted in UniversalPlayerView above the video surface, below the
//  UIKit transport bar hosted by PlayerContainerViewController.
//
//  Sizing and placement mirror AVPlayer's own caption rendering:
//    - point size = a fraction of the PRESENTATION height x the system's
//      relative-character-size multiplier
//    - the resting bottom margin is a fraction of the PICTURE height, so a
//      letterboxed film is captioned on the image, not in its black bar
//    - with the rail up, the same margin is measured off the rail's top edge
//      (344 pt) instead, so the caption keeps its distance either way; shared
//      with the HLS-route overlay via SubtitleAdjustments so the routes agree
//
//  That margin is a FLOOR every cue obeys (`placementFloor`), including one
//  that positioned itself: a cue placed into the rail is lifted clear of it.
//  There is a matching no-go zone at each side (`sideSafeFraction`), because
//  AVPlayer will not draw to the picture edge either.
//
//  Within those, a cue that gave an exact position keeps it. Vertically the
//  position names the box's TOP edge (WebVTT's default `line-align: start`),
//  so the box hangs down from it, which is where AVPlayer draws it.
//  Horizontally the box is centred on the position. A cue that gave only a
//  coarse band (teletext) takes that band's resting anchor instead.
//
//  Only the user's Height stepper is placement-exempt.
//
//  See the Metrics block below for the derivations.
//

import SwiftUI

// MARK: - AetherSubtitleOverlayView

struct AetherSubtitleOverlayView: View {

    @ObservedObject var model: SubtitleModel

    /// Current caption appearance. Replaced wholesale on CaptionAppearance changes.
    var style: CaptionStyle

    /// True when the player rail is visible; lifts text above it.
    var controlsVisible: Bool

    /// The video's presentation size (`AetherPlayer.videoSize`). `.zero` means
    /// "unknown" — the overlay then measures against its full bounds, which is
    /// the pre-existing behaviour and correct for a 16:9 picture filling the
    /// screen.
    var videoSize: CGSize = .zero

    /// Height adjustment for THIS media, in stepper units. Sticky per title /
    /// channel like the delay stepper and defaulting to 0.
    ///
    /// Pushed in by the host rather than read from defaults here: the key
    /// changes under a channel switch or a next-episode swap while the view
    /// keeps its identity, and re-binding a dynamic-key `@AppStorage` across
    /// that is not something to rely on.
    var heightUnits: Int = 0

    // MARK: Apple-matching caption metrics
    //
    // Tuned against AVPlayer's own caption rendering (screenshot comparison at
    // the smallest system caption size). Three differences mattered: Apple
    // sizes type from the VIDEO height rather than a fixed point size, boxes
    // the text tightly, and draws one background per LINE rather than one
    // around the whole cue.

    /// Caption point size as a fraction of the PRESENTATION height (the
    /// player's own bounds), before the user's relative-size multiplier.
    ///
    /// The model is: base fraction × the system's own multiplier. The WebVTT
    /// caption spec default is 5% (`5vh`); this sits near it, tuned on device
    /// against AVPlayer's own rendering — at the smallest system caption size
    /// `MACaptionAppearanceGetRelativeCharacterSize` reports 0.35, and
    /// 1080 × 0.0529 × 0.35 = 20pt is the match. Every other size follows
    /// from the multiplier.
    ///
    /// Do NOT re-tune this to compensate for a size problem: if captions are
    /// the wrong size, suspect the multiplier reaching us instead (see
    /// `CaptionAppearance.fontScale`, whose clamp used to swallow 0.35 and
    /// silently flatten the bottom of the range).
    ///
    /// Deliberately NOT the letterboxed picture height: Apple sizes captions
    /// from the presentation and only *positions* them against the picture,
    /// so a 2.39:1 film gets the same type as a 16:9 one rather than shrunken
    /// type. tvOS always presents 1080 points tall regardless of whether the
    /// display is 1080p or 4K, so this is stable across outputs.
    private static let fontHeightFraction: CGFloat = 0.0529

    /// Fallback presentation height, for the degenerate case of a zero-height
    /// layout pass.
    private static let assumedVideoHeight: CGFloat = 1080

    // Box geometry is expressed as MULTIPLES OF THE POINT SIZE, not fixed
    // points, because Apple's caption box grows with the type — a fixed radius
    // reads as a hard rectangle against much bigger glyphs at a large caption
    // size, and as an over-rounded pill at a small one.
    //
    // Radius is tuned by eye against AVPlayer: 0.25 gives 5pt at the smallest
    // setting (20pt type), against the 8pt fixed radius this replaced. The
    // padding ratios are deliberately NOT tied to it — they set how tightly the
    // box hugs the text, which is already matched, so change one without the
    // other.
    private static let cornerRadiusRatio: CGFloat = 0.25
    private static let paddingHRatio: CGFloat = 0.30
    private static let paddingVRatio: CGFloat = 0.075

    /// Extra leading between the lines of one cue, on top of the font's own
    /// line height. Zero matches Apple, whose caption lines sit on natural
    /// leading inside a single background.
    private static let textLineSpacing: CGFloat = 0

    /// Gap between separate simultaneous cues (two speakers), which SHOULD
    /// read as distinct blocks.
    private static let cueSpacing: CGFloat = 4

    /// Where a TOP-band cue lands when its source gave only a coarse band and
    /// no fine position — teletext through the engine demux, which quantises
    /// the 24-row grid to three bands and supplies no percentage.
    ///
    /// Free to tune, because nothing measurable pins it: the source genuinely
    /// does not say where in the top third the caption belongs. Set near where
    /// the same page's proxied WebVTT resolves (it carries an exact `line:`,
    /// typically around 10%), so the two routes look similar even though only
    /// one of them can be precise. The bottom band needs no equivalent — it
    /// rests on the shared floor, which already matched.
    private static let bandTopFraction: CGFloat = 0.10

    /// Anchor for a LEFT or RIGHT column that came with no fine position —
    /// teletext through the engine demux, which gives `\anN` but no percentage.
    ///
    /// Deliberately the same 10% / 90% the proxy writes into its WebVTT
    /// (`align:left position:10%`), so the same page lands in the same place
    /// whichever route it arrived by. Anchoring rather than edge-aligning also
    /// keeps a short caption off the very edge: the box centres on 10% and is
    /// then clamped into the safe zone, instead of hugging it.
    private static let bandSideFraction: CGFloat = 0.10

    /// Horizontal no-go zone at each edge of the PICTURE, as a fraction of its
    /// width. AVPlayer will not draw a caption to the very edge — it keeps one
    /// inside a safe inset, the same idea as tvOS's title-safe area — so a cue
    /// positioned near the side sat visibly closer to the edge for us than for
    /// AVPlayer until this existed. Matches the 90pt the player chrome insets
    /// itself by at 1920 wide.
    private static let sideSafeFraction: CGFloat = 0.05

    /// Nominal ASS font size that a cue's `\fs` is judged against. libavcodec
    /// synthesises its ASS lines at a 384x288 play resolution whose default
    /// style is 16pt, so `\fs32` means "twice normal", not "32 points".
    private static let assNominalFontSize: CGFloat = 16

    /// The picture's rect inside `bounds`, aspect-fit (how both the engine
    /// surface and AVPlayerLayer place video). Falls back to the full bounds
    /// when the size is unknown.
    private func videoRect(in bounds: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0,
              bounds.width > 0, bounds.height > 0 else {
            return CGRect(origin: .zero, size: bounds)
        }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let w = videoSize.width * scale
        let h = videoSize.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    /// The lowest any caption may sit, as a distance from the bottom of the
    /// CONTAINER. EVERY cue obeys this, placed or not.
    ///
    /// Two anchors compete and the larger wins: the caption must sit
    /// `SubtitleAdjustments.bottomMarginFraction` of the PICTURE above its
    /// bottom edge (so letterboxed
    /// content is not captioned into its black bar), and it must clear the
    /// rail when the rail is up (which is anchored to the SCREEN). Taking the
    /// max means a 2.39:1 film with the rail hidden lifts by its letterbox,
    /// while the same film with the rail up still clears the chrome.
    ///
    /// Placed cues obey it too — Live TV is almost entirely placed cues, and
    /// exempting them is what made its captions sit lower than VOD's. It is a
    /// floor only: a cue asking to sit higher keeps its own position.
    private func placementFloor(in bounds: CGSize) -> CGFloat {
        let rect = videoRect(in: bounds)
        let letterbox = max(0, bounds.height - rect.maxY)
        var base = letterbox + rect.height * SubtitleAdjustments.bottomMarginFraction
        if controlsVisible {
            // Same margin, measured off the rail's top edge instead of the
            // picture's bottom, so the caption keeps its distance either way.
            base = max(base, SubtitleAdjustments.controlsFloor(pictureHeight: rect.height))
        }
        return base
    }

    /// Distance from the bottom of the CONTAINER to an UNPLACED cue: the
    /// shared floor plus the user's Height stepper, which applies to the
    /// default band only.
    private func bottomPadding(in bounds: CGSize) -> CGFloat {
        max(0, placementFloor(in: bounds) + SubtitleAdjustments.heightOffset(forUnits: heightUnits))
    }

    /// Caption point size for this presentation, before per-cue styling.
    private func baseFontSize(in bounds: CGSize) -> CGFloat {
        let height = bounds.height > 0 ? bounds.height : Self.assumedVideoHeight
        return height * Self.fontHeightFraction * style.fontScale
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Bitmap cues: render all simultaneously (PGS can emit multiples).
                //
                // Keyed by contentKey, NOT by cue.id: the engine's cue id is a
                // per-decoder monotonic counter that restarts at 0 whenever a
                // seek resets the decoder, so it collides with older cues still
                // in the array and hands SwiftUI duplicate ForEach identities.
                ForEach(model.activeCues.filter(\.isBitmap), id: \.contentKey) { cue in
                    if case .image(let cgImage, let pos) = cue.body {
                        bitmapCue(cgImage: cgImage, position: pos, size: geo.size)
                    }
                }

                // Text cues: stack vertically at bottom-centre. Also keyed by
                // contentKey; see the note above.
                //
                // ORDER MATTERS: the bottom padding must be applied INSIDE the
                // full-screen frame (padding first, then frame). Padding after
                // the frame grows the composite beyond the screen — the frame
                // stays screen-height, the ZStack top-anchors it, and the
                // padding hangs invisibly off the bottom edge, so the inset
                // never lifted the text at all (subs sat glued to the edge and
                // the rail lift was a no-op).
                // Unpositioned text cues: the default bottom band, and the
                // ONLY place the user's Height adjustment applies.
                VStack(spacing: Self.cueSpacing) {
                    ForEach(model.activeCues.filter { $0.isText && $0.placement == nil },
                            id: \.contentKey) { cue in
                        styledText(cue.body, size: geo.size)
                    }
                }
                .padding(.bottom, bottomPadding(in: geo.size))
                .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)

                // Cues the SOURCE placed (ASS \an / \pos — signs, top-of-frame
                // captions the broadcaster moved off on-screen graphics).
                // Positioned against the picture, and deliberately exempt from
                // the Height stepper: an authored position must not drift with
                // an app-level offset.
                ForEach(model.activeCues.filter { $0.isText && $0.placement != nil },
                        id: \.contentKey) { cue in
                    if let placement = cue.placement {
                        placedCue(cue.body, placement: placement, size: geo.size)
                    }
                }
            }
            // Both bands move only when the rail appears or dismisses, so the
            // lift reads as the captions sliding out of the chrome's way
            // rather than snapping. Cues the rail never covered are unaffected
            // by definition — their geometry doesn't change.
            //
            // Matches the chrome's own fade: `UIView.animate(withDuration:)`
            // with no options is a 0.25s ease-in-out, so the caption travels
            // on exactly the curve the rail arrives on. Keep these in step —
            // PlayerContainerViewController.applyChromeVisibility and the Live
            // TV showRail/hideRail pair are the other half.
            .animation(.easeInOut(duration: 0.25), value: controlsVisible)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Bitmap cue

    @ViewBuilder
    private func bitmapCue(cgImage: CGImage, position: CGRect, size: CGSize) -> some View {
        // `SubtitleImage.position` is normalized against the SOURCE VIDEO
        // FRAME, not the player's bounds — upstream is explicit that a host
        // maps it onto the on-screen video rect, and `SubtitleTextPlacement`
        // shares the convention (AE #233). Multiplying by the full bounds
        // put PGS/DVB cues wrong on anything letterboxed: a 2.39:1 film
        // stretched them vertically and pushed them toward the black bar.
        // Falls back to the full bounds when the video size is unknown,
        // which is what the old behaviour assumed anyway.
        let rect = videoRect(in: size)
        let frameW = position.width  * rect.width
        let frameH = position.height * rect.height
        let originX = rect.minX + position.minX * rect.width
        let originY = rect.minY + position.minY * rect.height

        Image(decorative: cgImage, scale: 1, orientation: .up)
            .resizable()
            .interpolation(.high)
            .frame(width: frameW, height: frameH)
            .offset(x: originX, y: originY)
    }

    // MARK: - Text cue

    /// One cue in ONE rounded box, sized to its longest line.
    ///
    /// A multi-line cue keeps its author's line breaks and stays inside a
    /// single background — the box hugs the widest line and the shorter lines
    /// centre within it. (An earlier attempt boxed each line separately; that
    /// reads as detached labels rather than one caption.)
    @ViewBuilder
    private func styledText(_ body: AetherSubtitleCue.Body,
                            size: CGSize,
                            widthLimit: CGFloat? = nil) -> some View {
        // `widthLimit` only ever NARROWS the default: a cue placed off-centre
        // has less room before it runs off the picture than one in the middle.
        let maxWidth = min(widthLimit ?? .greatestFiniteMagnitude, max(0, size.width - 240))
        let pointSize = baseFontSize(in: size)
        let baseFont = style.font(ofSize: pointSize)

        switch style.edge {
        case .uniform:
            // 8-direction black outline (no per-character stroke on tvOS).
            let offsets: [(CGFloat, CGFloat)] = [
                (-2, -2), ( 0, -2), ( 2, -2),
                (-2,  0),           ( 2,  0),
                (-2,  2), ( 0,  2), ( 2,  2)
            ]
            ZStack {
                ForEach(Array(offsets.enumerated()), id: \.offset) { _, delta in
                    // Outline layers are always solid black, but keep the
                    // per-run fonts so the outline tracks styled glyphs.
                    cueText(body, baseSize: pointSize, forcedColor: .black)
                        .font(baseFont)
                        .multilineTextAlignment(.center)
                        .lineSpacing(Self.textLineSpacing)
                        .offset(x: delta.0, y: delta.1)
                }
                cueText(body, baseSize: pointSize)
                    .font(baseFont)
                    .multilineTextAlignment(.center)
                    .lineSpacing(Self.textLineSpacing)
            }
            .frame(maxWidth: maxWidth)

        case .dropShadow:
            boxed(cueText(body, baseSize: pointSize).font(baseFont),
                  maxWidth: maxWidth, fontSize: pointSize)
                .shadow(color: .black.opacity(0.85), radius: 3, x: 0, y: 1)

        default:
            // .none / .raised / .depressed: solid background box.
            boxed(cueText(body, baseSize: pointSize).font(baseFont),
                  maxWidth: maxWidth, fontSize: pointSize)
        }
    }

    /// A cue the source positioned itself, placed against the PICTURE (so a
    /// letterboxed film's signs land on the image, not in the black bar).
    ///
    /// Two kinds of placement arrive here and they are resolved differently:
    ///
    /// **With a fine position** (proxied WebVTT `line:` / `position:`, ASS
    /// `\pos`) the cue is anchored by its CENTRE on that point. That is what
    /// `kCMTextMarkupAttribute_OrthogonalLinePositionPercentage…` means — a
    /// percentage locating the centre of the text — so anchoring the same way
    /// puts a WebVTT cue exactly where AVPlayer draws it. An earlier version
    /// pinned the box's bottom edge at `1 - line`, which sat roughly half a box
    /// too high on multi-line cues.
    ///
    /// **Without one** (teletext through the engine demux, which quantises the
    /// grid row to a coarse `\an` and supplies no percentage) the numpad band
    /// is all there is, so the cue takes that band's natural resting place:
    /// the shared floor at the bottom, the matching margin at the top, dead
    /// centre in the middle. It cannot be as precise as the WebVTT case, but it
    /// lands somewhere captions belong instead of hard against an edge.
    private func placedCue(_ body: AetherSubtitleCue.Body,
                           placement: AetherSubtitleCue.TextPlacement,
                           size: CGSize) -> some View {
        let rect = videoRect(in: size)
        // Numpad: rows 7-9 top, 4-6 middle, 1-3 bottom; columns 1/4/7 left,
        // 2/5/8 centre, 3/6/9 right. 2 (bottom-centre) is the ASS default.
        let an = placement.alignment ?? 2
        let col = (an - 1) % 3
        let row = (an - 1) / 3

        // Clamped so a wild coordinate cannot push a caption off screen.
        let ax = placement.position.map { min(max($0.x, 0), 1) }
        let ay = placement.position.map { min(max($0.y, 0), 1) }

        let letterbox = max(0, size.height - rect.maxY)
        let floor = placementFloor(in: size)

        // Vertical. A fine position wins; the band is the fallback.
        let vertical: VerticalAlignment = ay != nil ? .center
            : (row == 2 ? .top : row == 1 ? .center : .bottom)
        let topInset: CGFloat = (ay == nil && row == 2) ? rect.height * Self.bandTopFraction : 0
        let bottomInset: CGFloat = (ay == nil && row == 0) ? max(0, floor - letterbox) : 0

        // Centre offset, positive downward.
        //
        // The line position names the box's TOP edge, not its centre: WebVTT's
        // default `line-align` is `start`, so the box hangs DOWN from the
        // stated line, and AVPlayer draws it there. Anchoring the centre on it
        // instead sits half a box high — visible as our captions reading a
        // touch above AVPlayer's on the same stream.
        //
        // The box cannot be measured without a layout pass, so half of it is
        // estimated as a one-line box (line height plus vertical padding). A
        // taller cue therefore sits slightly high rather than slightly low,
        // which is the safer way to be wrong.
        //
        // The same half-box keeps the floor clamp honest: the lowest the
        // centre may sit is the floor plus half a box, so the clamp protects
        // the TEXT rather than just its midpoint.
        var dy: CGFloat = 0
        if let ay {
            let halfBox = baseFontSize(in: size) * 0.7
            let lowestCentre = max(0, floor - letterbox) + halfBox
            let requestedCentre = (1 - ay) * rect.height - halfBox
            dy = rect.height / 2 - max(requestedCentre, lowestCentre)
        }

        // Horizontal. A column with no fine position (teletext) borrows the
        // anchor the proxy writes for that column, so both routes resolve
        // through the identical maths below and land together.
        let anchorX: CGFloat? = ax
            ?? (col == 0 ? Self.bandSideFraction
                : col == 2 ? 1 - Self.bandSideFraction : nil)

        // Everything stays inside the safe inset at each edge.
        let sideSafe = rect.width * Self.sideSafeFraction
        let usable = max(0, rect.width - sideSafe * 2)
        // Smallest half-width worth wrapping into, so a cue anchored near an
        // edge is nudged inward rather than squeezed to a column one word wide.
        let minHalf = usable * 0.15

        // Every placed cue is centred on its anchor; the clamp keeps the box
        // inside the safe region, and the width follows the placement or a cue
        // pushed to one side keeps wrapping at the full picture width and
        // overhangs it.
        var dx: CGFloat = 0
        var widthLimit: CGFloat?
        if let anchorX {
            let lo = sideSafe + minHalf
            let hi = max(lo, rect.width - sideSafe - minHalf)
            let centre = min(max(anchorX * rect.width, lo), hi)
            let half = max(minHalf, min(centre - sideSafe, rect.width - sideSafe - centre))
            dx = centre - rect.width / 2
            widthLimit = half * 2
        }

        return styledText(body, size: size, widthLimit: widthLimit)
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)
            .frame(width: rect.width, height: rect.height,
                   alignment: Alignment(horizontal: .center, vertical: vertical))
            .offset(x: rect.minX + dx, y: rect.minY + dy)
    }

    /// The tight background box Apple draws behind a caption, with padding and
    /// radius proportional to `fontSize`.
    private func boxed(_ text: some View, maxWidth: CGFloat, fontSize: CGFloat) -> some View {
        text
            .multilineTextAlignment(.center)
            .lineSpacing(Self.textLineSpacing)
            .padding(.horizontal, fontSize * Self.paddingHRatio)
            .padding(.vertical, fontSize * Self.paddingVRatio)
            .background(
                RoundedRectangle(cornerRadius: fontSize * Self.cornerRadiusRatio, style: .continuous)
                    .fill(style.backgroundColor.opacity(style.backgroundOpacity))
            )
            // Centring here is correct ONLY because every placed cue is
            // anchored by its centre and offset into position. `.frame(maxWidth:)`
            // expands to whatever the parent proposes and centres its child in
            // that width, so any future edge-aligned path must pass an explicit
            // alignment or it will silently land in the middle of the picture.
            .frame(maxWidth: maxWidth)
    }

    /// Builds the cue's `Text`, applying the colour policy per run:
    ///  - Video Override ON (`style.allowsContentColor`): a run's
    ///    content-specified colour wins; runs without one get the user colour.
    ///  - Video Override OFF: every run renders in the user's colour.
    /// The system foreground opacity applies either way.
    /// Builds the cue's `Text`, applying each content attribute only where
    /// the matching system Video Override allows it:
    ///  - colour                → `allowsContentColor`
    ///  - bold/italic/underline/strikethrough, font face → `allowsContentFont`
    ///  - relative size         → `allowsContentFontSize`
    /// A gated-off or content-silent attribute renders the system value. The
    /// system foreground opacity applies either way.
    ///
    /// `forcedColor` repaints every run in one colour while KEEPING per-run
    /// fonts, so the uniform-edge outline layers track styled glyph metrics
    /// instead of misaligning under a bold or resized run.
    private func cueText(_ body: AetherSubtitleCue.Body,
                         baseSize: CGFloat,
                         forcedColor: Color? = nil) -> Text {
        let userColor = style.foreground.opacity(style.foregroundOpacity)
        switch body {
        case .text(let string):
            return Text(string).foregroundStyle(forcedColor ?? userColor)
        case .styledText(let runs):
            return runs.reduce(Text(verbatim: "")) { acc, run in
                var piece = Text(run.text)

                let contentColor = style.allowsContentColor ? run.color : nil
                piece = piece.foregroundStyle(
                    forcedColor ?? contentColor?.opacity(style.foregroundOpacity) ?? userColor)

                // A run's own font only replaces the system caption font when
                // it actually asks for something; otherwise the outer .font()
                // modifier applies and the user's face is preserved.
                if let font = runFont(for: run, baseSize: baseSize) {
                    piece = piece.font(font)
                }
                if style.allowsContentFont {
                    if run.isUnderlined { piece = piece.underline() }
                    if run.isStruckThrough { piece = piece.strikethrough() }
                }
                return acc + piece
            }
        case .image:
            return Text(verbatim: "")
        }
    }

    /// The font for one run, or nil when the content asked for nothing and
    /// the view-level caption font should apply unchanged.
    private func runFont(for run: AetherSubtitleCue.StyledRun, baseSize: CGFloat) -> Font? {
        let wantsFace = style.allowsContentFont && (run.isBold || run.isItalic || run.fontName != nil)
        let scale = contentSizeScale(for: run)
        guard wantsFace || scale != nil else { return nil }

        let size = baseSize * (scale ?? 1)
        // A content font FACE is honoured by name; an unknown name falls back
        // to the system caption font at the same size rather than to a
        // default that would ignore the user's choice entirely.
        var font: Font
        if style.allowsContentFont, let name = run.fontName, !name.isEmpty {
            font = .custom(name, fixedSize: size)
        } else {
            font = style.font(ofSize: size)
        }
        if style.allowsContentFont {
            if run.isBold { font = font.bold() }
            if run.isItalic { font = font.italic() }
        }
        return font
    }

    /// A run's `\fs` as a multiplier, or nil when it asks for nothing.
    ///
    /// `fontSize` is in ASS play-resolution points, so it is meaningful only
    /// RELATIVE to the script's nominal size — libavcodec's synthesised lines
    /// use a 384x288 play resolution whose default style is 16pt. Treating it
    /// as a point size directly would make a `\fs20` line tiny. Clamped so a
    /// wild value cannot fill the screen.
    private func contentSizeScale(for run: AetherSubtitleCue.StyledRun) -> CGFloat? {
        guard style.allowsContentFontSize, let size = run.fontSize, size > 0 else { return nil }
        let ratio = CGFloat(size) / Self.assNominalFontSize
        guard abs(ratio - 1) > 0.01 else { return nil }
        return min(max(ratio, 0.5), 2.0)
    }
}

// MARK: - AetherSubtitleCue helpers

private extension AetherSubtitleCue {
    var isText: Bool {
        switch body {
        case .text, .styledText: return true
        case .image: return false
        }
    }
    var isBitmap: Bool {
        if case .image = body { return true }
        return false
    }
}

