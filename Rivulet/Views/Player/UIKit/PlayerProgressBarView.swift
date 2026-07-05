//
//  PlayerProgressBarView.swift
//  Rivulet
//
//  Transport scrubber styled after AVPlayerViewController (tvOS 15+):
//  a thin rounded white bar with a 26pt circular knob — the fill edge is
//  the playhead. While scrubbing, the bar morphs into a 130pt timeline-
//  first filmstrip of BIF trickplay frames with a glowing playhead bar
//  (overhanging above/below the strip) and a fainter line marking the
//  actual playback position; an oversized readout (chapter eyebrow +
//  large timecode) follows the playhead above the strip, and a bottom
//  progress line (accent-gradient fill on a faint track) runs along the
//  strip's own bottom edge. If no filmstrip data is available (still
//  loading, or the title has no BIF), scrubbing looks exactly like
//  before: thin bar + floating single thumbnail. Time remaining sits
//  below the right end, with an "Ends at" clock-time label beside it at
//  rest (hidden while the strip is open). Plex markers (intro/credits)
//  tint their range on both the thin bar and the strip.
//
//  The view's own height covers only the track + label band; the
//  thumbnail/strip overhangs above it (clipsToBounds = false) so the
//  transport bar doesn't reserve blank space when not scrubbing.
//
//  One-clock rule: the strip's alpha/height and the thin-bar fill all
//  ride the SAME `UIView.animate` block in `update(...)` that already
//  animates `trackHeightConstraint` + `layoutIfNeeded`. No second
//  animator, no CABasicAnimation, no separate CADisplayLink.
//

import UIKit

/// Horizontal accent gradient used for the progress fill. A
/// `CAGradientLayer`-backed view resizes its layer automatically via
/// `layerClass`, so it stays a drop-in frame-driven replacement for the
/// plain white `progressFill` view laid out by `update(...)`'s animate block.
final class AccentGradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        let g = layer as! CAGradientLayer
        g.colors = [
            UIColor(red: 0x7f/255, green: 0xb8/255, blue: 0xff/255, alpha: 1).cgColor,
            UIColor(red: 0xb9/255, green: 0xa3/255, blue: 0xff/255, alpha: 1).cgColor,
            UIColor(red: 0xff/255, green: 0xce/255, blue: 0x93/255, alpha: 1).cgColor,
            UIColor(red: 0x8f/255, green: 0xe9/255, blue: 0xd4/255, alpha: 1).cgColor,
        ]
        g.locations = [0, 0.45, 0.8, 1]
        g.startPoint = CGPoint(x: 0, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 0.5)
        layer.cornerRadius = 5
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// Played-side dim: black .5 → .08 across the played region of the strip.
final class StripDimView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame)
        let g = layer as! CAGradientLayer
        g.colors = [UIColor.black.withAlphaComponent(0.5).cgColor,
                    UIColor.black.withAlphaComponent(0.08).cgColor]
        g.startPoint = CGPoint(x: 0, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 0.5)
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class PlayerProgressBarView: UIView {

    // MARK: - Metrics (AVPlayerViewController-matched)

    private enum Metrics {
        static let trackHeight: CGFloat = 10
        static let stripHeight: CGFloat = 130
        static let stripTileAspect: CGFloat = 16.0 / 9.0
        static let labelBandSpacing: CGFloat = 14
        static let thumbnailWidth: CGFloat = 320
        static let thumbnailHeight: CGFloat = 180
        static let thumbnailGap: CGFloat = 20
        static let endsAtGap: CGFloat = 24
        static let wheelRingDiameter: CGFloat = 44
        static let wheelRingBorderWidth: CGFloat = 3
        static let wheelDotDiameter: CGFloat = 6
        static let wheelRingGap: CGFloat = 16
    }

    // MARK: - Marker coloring

    static func color(for marker: PlexMarker) -> UIColor {
        if marker.isIntro {
            return .systemBlue
        } else if marker.isCredits {
            return .systemPurple
        } else {
            return .systemYellow
        }
    }

    // MARK: - Subviews

    private let trackBackground = UIView()
    private let currentPositionGhost = UIView()
    private let progressFill = AccentGradientView()
    private let handleView = UIView()          // white core
    private let handleRing = UIView()          // ring behind it
    private let markersContainer = UIView()
    private let currentTimeLabel = UILabel()
    private let remainingTimeLabel = UILabel()
    private let endsAtLabel = UILabel()
    private let scrubStepLabel = UILabel()
    private let thumbnailImageView = UIImageView()
    private let thumbnailContainer = UIView()

    // Filmstrip morph subviews.
    private let stripContainer = UIView()
    private var stripTiles: [UIImageView] = []
    private let livePositionLine = UIView()
    private let dimOverlay = StripDimView()

    /// Timeline-first playhead bar: an 8pt white glowing bar on a 16pt
    /// black@0.4 rounded backing, both siblings of `stripContainer` on
    /// `self` (not clipped by the track), spanning from `stripTop − 14` to
    /// `stripBottom + 14`. Replaces the old hairline `playheadLine` (inside
    /// the strip) and the 3pt `playheadThread` (connecting the strip down
    /// to the track) — positioned together in `layoutStripOverlay(...)`.
    private let playheadBarBacking = UIView()
    private let playheadBar = UIView()

    /// Bottom progress line: a 5pt ribbon pinned inside the strip's own
    /// bottom edge, full width. `progressLineTrack` is the white@0.12
    /// base; `progressLineFill` is an `AccentGradientView` sized to the
    /// seek fraction, both children of `stripContainer` so they clip/scale
    /// with it. Positioned in `layoutStripOverlay(...)`.
    private let progressLineTrack = UIView()
    private let progressLineFill = AccentGradientView()

    /// Oversized scrub readout: replaces the old `PaddedChipLabel` chip.
    /// `readoutContainer` is a small frame-driven container (a sibling of
    /// `stripContainer` on `self`, positioned/clamped exactly like the old
    /// callout) holding a small-caps chapter eyebrow above a large
    /// timecode. The eyebrow hides when the playhead isn't inside a named
    /// chapter, leaving just the timecode.
    private let readoutContainer = UIView()
    private let readoutEyebrowLabel = UILabel()
    private let readoutTimecodeLabel = UILabel()

    // Chapter-proportional segment geometry for the currently open strip
    // (recomputed in `populateStrip`). Each segment gets its own rounded,
    // clipping container so BIF tiles crop to chapter-width blocks with
    // gaps between them; `nil` / empty means the pre-segment (or
    // chapterless single-segment) rendering.
    private var segmentLayout: ChapterSegmentLayout?
    private var segmentContainers: [UIView] = []

    // Jog wheel indicator: shown beside the readout only while a circular
    // clickpad rotation is actively driving the scrub (`isWheelScrubbing`).
    // Frame-driven like readoutContainer, positioned in
    // `layoutStripOverlay(...)`.
    private let wheelRing = UIView()
    private let wheelDot = UIView()
    private var isWheelScrubbing = false

    // Chapter seam hairlines, drawn at each chapter start's x position
    // while the strip is open. Rebuilt only when chapters/width change.
    private var chapterSeams: [UIView] = []
    private var lastChapters: [PlexChapter] = []
    private var lastSeamsChapterIds: [Int?] = []
    private var lastSeamWidth: CGFloat = 0

    /// Supplies filmstrip frames for `times` (evenly spaced across the
    /// track width), downsampled to `maxPixelWidth`. Wired by
    /// PlayerContainerViewController to `UniversalPlayerViewModel.filmstripImages`.
    var filmstripProvider: (([TimeInterval], CGFloat) async -> [UIImage?])?

    private var stripLoadTask: Task<Void, Never>?
    /// Sticky for the scrub session once a filmstrip is confirmed to
    /// have real frames; avoids re-fetching (and re-flickering the
    /// thin-bar fallback) on every scrub start/stop within one playback.
    private var stripLoaded = false
    private var duration: TimeInterval = 0
    /// Cached from the last `update(...)` call so `reapplyStripMorph()`
    /// (fired from an async load completion, off the normal update path)
    /// can redraw the marker band and playhead without losing state.
    private var lastMarkers: [PlexMarker] = []
    private var lastProgress: Double = 0
    private var lastCurrentProgress: Double = 0

    private var trackHeightConstraint: NSLayoutConstraint!
    private var thumbnailCenterXConstraint: NSLayoutConstraint!

    /// Loading placeholder mode; see `setSkeleton(_:)`.
    private var isSkeleton = false

    /// Paused presentation: the accent fill dims while paused (2a spec).
    /// Stored and folded into update()'s alpha computation; applied
    /// immediately here because time ticks stop while the player is paused.
    private var isPausedDim = false

    private static let endsAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stripLoadTask?.cancel()
    }

    private func setupViews() {
        clipsToBounds = false

        trackBackground.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        trackBackground.layer.cornerCurve = .continuous
        trackBackground.clipsToBounds = true

        // Actual playback position while previewing elsewhere.
        currentPositionGhost.backgroundColor = UIColor.white.withAlphaComponent(0.45)
        currentPositionGhost.isHidden = true

        handleRing.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        handleView.backgroundColor = .white
        handleView.layer.shadowColor = UIColor.black.cgColor
        handleView.layer.shadowOpacity = 0.5
        handleView.layer.shadowRadius = 16
        handleView.layer.shadowOffset = CGSize(width: 0, height: 4)

        currentTimeLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        currentTimeLabel.textColor = UIColor.white.withAlphaComponent(0.82)

        remainingTimeLabel.font = .monospacedDigitSystemFont(ofSize: 22, weight: .medium)
        remainingTimeLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        remainingTimeLabel.textAlignment = .right

        endsAtLabel.font = .systemFont(ofSize: 17, weight: .medium)
        endsAtLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        endsAtLabel.textAlignment = .right

        scrubStepLabel.font = .systemFont(ofSize: 20, weight: .medium)
        scrubStepLabel.textColor = UIColor.white.withAlphaComponent(0.8)
        scrubStepLabel.isHidden = true

        thumbnailImageView.contentMode = .scaleAspectFill
        thumbnailImageView.clipsToBounds = true

        thumbnailContainer.isHidden = true
        thumbnailContainer.layer.cornerRadius = 12
        thumbnailContainer.layer.cornerCurve = .continuous
        thumbnailContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
        thumbnailContainer.layer.borderWidth = 1
        thumbnailContainer.layer.shadowColor = UIColor.black.cgColor
        thumbnailContainer.layer.shadowOpacity = 0.4
        thumbnailContainer.layer.shadowRadius = 16
        thumbnailContainer.layer.shadowOffset = CGSize(width: 0, height: 6)
        thumbnailContainer.clipsToBounds = false
        thumbnailImageView.layer.cornerRadius = 12
        thumbnailImageView.layer.cornerCurve = .continuous
        thumbnailContainer.addSubview(thumbnailImageView)

        // Filmstrip: clipped, rounded, pinned to trackBackground's own
        // bounds so it grows/shrinks with trackHeightConstraint for free.
        stripContainer.clipsToBounds = true
        stripContainer.layer.cornerCurve = .continuous
        stripContainer.alpha = 0
        stripContainer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        stripContainer.frame = trackBackground.bounds

        // Played-side dim sits above the tiles but below the playhead/live
        // lines, sized to the played width in `layoutStripOverlay(...)`.
        dimOverlay.isHidden = true
        stripContainer.addSubview(dimOverlay)

        livePositionLine.backgroundColor = UIColor.white.withAlphaComponent(0.5)
        stripContainer.addSubview(livePositionLine)

        // Bottom progress line: 5pt ribbon pinned inside the strip's own
        // bottom edge. Track + gradient fill are children of stripContainer
        // so they clip/scale with it; sized in `layoutStripOverlay(...)`.
        progressLineTrack.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        progressLineTrack.layer.cornerRadius = 2.5
        progressLineTrack.layer.cornerCurve = .continuous
        progressLineTrack.clipsToBounds = true
        progressLineTrack.isHidden = true
        stripContainer.addSubview(progressLineTrack)
        progressLineTrack.addSubview(progressLineFill)

        // Oversized readout: replaces the old pill chip. A small-caps
        // chapter eyebrow above a large monospaced timecode, laid out
        // frame-wise (no constraints — 2a lesson: cross-view constraints
        // must not be introduced inside the strip's frame-driven overlays).
        readoutEyebrowLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        readoutEyebrowLabel.textColor = UIColor.white.withAlphaComponent(0.5)
        readoutEyebrowLabel.textAlignment = .center
        readoutEyebrowLabel.isHidden = true

        readoutTimecodeLabel.font = .monospacedDigitSystemFont(ofSize: 50, weight: .bold)
        readoutTimecodeLabel.textColor = .white
        readoutTimecodeLabel.textAlignment = .center

        readoutContainer.addSubview(readoutEyebrowLabel)
        readoutContainer.addSubview(readoutTimecodeLabel)
        readoutContainer.isHidden = true

        // Playhead bar: 8pt white glowing bar on a 16pt black@0.4 rounded
        // backing. Siblings of stripContainer on self (not clipped by the
        // track), hidden until the strip is open. Replaces the old
        // in-strip playheadLine hairline and the playheadThread connector.
        playheadBarBacking.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        playheadBarBacking.layer.cornerRadius = 8
        playheadBarBacking.layer.cornerCurve = .continuous
        playheadBarBacking.isHidden = true

        playheadBar.backgroundColor = .white
        playheadBar.layer.cornerRadius = 6
        playheadBar.layer.cornerCurve = .continuous
        playheadBar.layer.shadowColor = UIColor(red: 180/255, green: 205/255, blue: 1, alpha: 1).cgColor
        playheadBar.layer.shadowOpacity = 0.6
        playheadBar.layer.shadowRadius = 13
        playheadBar.layer.shadowOffset = .zero
        playheadBar.isHidden = true

        wheelRing.backgroundColor = .clear
        wheelRing.layer.borderWidth = Metrics.wheelRingBorderWidth
        wheelRing.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
        wheelRing.layer.cornerRadius = Metrics.wheelRingDiameter / 2
        wheelRing.isHidden = true

        wheelDot.backgroundColor = .white
        wheelDot.layer.cornerRadius = Metrics.wheelDotDiameter / 2
        wheelDot.isHidden = true

        [trackBackground, thumbnailContainer, currentTimeLabel, remainingTimeLabel,
         endsAtLabel, scrubStepLabel, readoutContainer, wheelRing, wheelDot].forEach {
            addSubview($0)
        }
        [currentPositionGhost, progressFill, markersContainer, stripContainer].forEach {
            trackBackground.addSubview($0)
        }
        // Handle views, and the playhead bar + its backing, are
        // frame-driven siblings of trackBackground (not children of it —
        // the track clips its contents, which would clip the handle's
        // shadow / the playhead bar's overhang above and below the track).
        addSubview(handleRing)
        addSubview(handleView)
        addSubview(playheadBarBacking)
        addSubview(playheadBar)

        [trackBackground, thumbnailContainer, thumbnailImageView,
         currentTimeLabel, remainingTimeLabel, endsAtLabel, scrubStepLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        trackHeightConstraint = trackBackground.heightAnchor.constraint(equalToConstant: Metrics.trackHeight)
        thumbnailCenterXConstraint = thumbnailContainer.centerXAnchor.constraint(equalTo: leadingAnchor)

        NSLayoutConstraint.activate([
            trackBackground.topAnchor.constraint(equalTo: topAnchor),
            trackBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            trackBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            trackHeightConstraint,

            // Thumbnail overhangs above the view; no reserved space.
            thumbnailContainer.bottomAnchor.constraint(equalTo: trackBackground.topAnchor, constant: -Metrics.thumbnailGap),
            thumbnailContainer.widthAnchor.constraint(equalToConstant: Metrics.thumbnailWidth),
            thumbnailContainer.heightAnchor.constraint(equalToConstant: Metrics.thumbnailHeight),
            thumbnailCenterXConstraint,

            thumbnailImageView.topAnchor.constraint(equalTo: thumbnailContainer.topAnchor),
            thumbnailImageView.leadingAnchor.constraint(equalTo: thumbnailContainer.leadingAnchor),
            thumbnailImageView.trailingAnchor.constraint(equalTo: thumbnailContainer.trailingAnchor),
            thumbnailImageView.bottomAnchor.constraint(equalTo: thumbnailContainer.bottomAnchor),

            // Label band below the track. The elapsed time is pinned to
            // the left (always visible); remaining time is pinned below
            // the right end, with "Ends at" to its left.
            currentTimeLabel.topAnchor.constraint(equalTo: trackBackground.bottomAnchor, constant: Metrics.labelBandSpacing),
            currentTimeLabel.leadingAnchor.constraint(equalTo: leadingAnchor),

            scrubStepLabel.centerYAnchor.constraint(equalTo: currentTimeLabel.centerYAnchor),
            scrubStepLabel.leadingAnchor.constraint(equalTo: currentTimeLabel.trailingAnchor, constant: 16),

            remainingTimeLabel.topAnchor.constraint(equalTo: trackBackground.bottomAnchor, constant: Metrics.labelBandSpacing),
            remainingTimeLabel.trailingAnchor.constraint(equalTo: trailingAnchor),

            endsAtLabel.centerYAnchor.constraint(equalTo: remainingTimeLabel.centerYAnchor),
            endsAtLabel.trailingAnchor.constraint(equalTo: remainingTimeLabel.leadingAnchor, constant: -Metrics.endsAtGap),

            bottomAnchor.constraint(equalTo: currentTimeLabel.bottomAnchor),
        ])
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        trackBackground.layer.cornerRadius = trackHeightConstraint.constant / 2
        // With more than one chapter segment, each segment container owns
        // its own rounding + clipping (see `populateStrip`), so
        // stripContainer itself goes unclipped/square. With zero or one
        // segment (no chapters), stripContainer keeps the old single
        // rounded-rect behavior so there's no regression on chapterless
        // titles.
        if segmentContainers.count > 1 {
            stripContainer.layer.cornerRadius = 0
            stripContainer.clipsToBounds = false
        } else {
            stripContainer.layer.cornerRadius = trackBackground.layer.cornerRadius
            stripContainer.clipsToBounds = true
        }
        // Keep the shimmer's gradient layer sized to the track (skeleton
        // mode never coexists with the strip morph, so the track stays at
        // its resting height, but width can still change on layout).
        // Disable implicit actions so this frame sync doesn't animate.
        if let shimmerLayer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shimmerLayer.frame = trackBackground.bounds
            CATransaction.commit()
        }
    }

    // MARK: - Update

    func update(
        currentTime: TimeInterval,
        duration: TimeInterval,
        isScrubbing: Bool,
        scrubTime: TimeInterval,
        scrubStepLabelText: String?,
        scrubThumbnail: UIImage?,
        markers: [PlexMarker],
        chapters: [PlexChapter],
        isWheelScrubbing: Bool = false
    ) {
        guard !isSkeleton else { return }

        let wasScrubbing = self.isScrubbing
        self.isScrubbing = isScrubbing
        self.isWheelScrubbing = isWheelScrubbing
        self.duration = duration
        self.lastMarkers = markers
        self.lastChapters = chapters

        let displayTime = isScrubbing ? scrubTime : currentTime
        let progress: Double = duration > 0 ? min(1, max(0, displayTime / duration)) : 0

        let width = trackBackground.bounds.width
        let currentProgress: Double = duration > 0 ? min(1, max(0, currentTime / duration)) : 0
        lastProgress = progress
        lastCurrentProgress = currentProgress

        if isScrubbing && !wasScrubbing {
            beginFilmstripLoad()
        } else if !isScrubbing && wasScrubbing {
            stripLoadTask?.cancel()
            stripLoadTask = nil
        }

        let stripOpen = isScrubbing && stripLoaded
        let trackHeight: CGFloat = stripOpen ? Metrics.stripHeight : Metrics.trackHeight

        currentPositionGhost.isHidden = !isScrubbing || stripOpen
        trackHeightConstraint.constant = trackHeight

        UIView.animate(withDuration: 0.15) {
            self.progressFill.alpha = stripOpen ? 0 : (self.isPausedDim ? 0.55 : 1)
            self.stripContainer.alpha = stripOpen ? 1 : 0
            self.progressFill.frame = CGRect(x: 0, y: 0, width: width * progress, height: trackHeight)
            if isScrubbing && !stripOpen {
                self.currentPositionGhost.frame = CGRect(
                    x: 0, y: 0,
                    width: width * currentProgress,
                    height: trackHeight
                )
            }

            // Handle: a plain 26pt circle at rest, always — no morph to a
            // tall bar anymore (the strip's own playhead bar takes over
            // that role while scrubbing; see layoutStripOverlay). Hidden
            // entirely while the strip is open (below). Frame-driven,
            // positioned at the fill edge and vertically centered on the
            // track — a sibling of trackBackground so it isn't clipped by
            // the track's own clipsToBounds.
            let handleSize = CGSize(width: 26, height: 26)
            let ringInset: CGFloat = 6
            let handleX = width * CGFloat(progress)
            let trackMidY = self.trackBackground.frame.minY + trackHeight / 2
            self.handleView.frame = CGRect(x: handleX - handleSize.width / 2, y: trackMidY - handleSize.height / 2,
                                           width: handleSize.width, height: handleSize.height)
            self.handleView.layer.cornerRadius = handleSize.width / 2
            self.handleRing.frame = self.handleView.frame.insetBy(dx: -ringInset, dy: -ringInset)
            self.handleRing.layer.cornerRadius = self.handleRing.frame.width / 2
            self.handleRing.backgroundColor = UIColor.white.withAlphaComponent(0.14)
            self.handleView.isHidden = stripOpen
            self.handleRing.isHidden = stripOpen

            self.layoutIfNeeded()
        }

        renderMarkers(markers, duration: duration, trackWidth: width,
                      trackHeight: stripOpen ? 4 : trackHeight, bottomAligned: stripOpen)

        // stripContainer's opaque tiles are a sibling of markersContainer
        // inside trackBackground; when the strip is open it must sit
        // behind the marker band (a 4pt strip pinned to the bottom edge)
        // rather than covering it. At rest / thin-bar, stripContainer is
        // fully transparent (alpha 0) so ordering there doesn't matter,
        // but bring markersContainer back to front so it doesn't stay
        // trapped behind stripContainer's view hierarchy once raised.
        trackBackground.bringSubviewToFront(markersContainer)

        if stripOpen {
            layoutStripOverlay(progress: progress, currentProgress: currentProgress, width: width)
        }

        // The elapsed time label is static and left-pinned — always
        // visible, showing the live/scrub position (no playhead-following
        // or clamping needed; the oversized readout above the strip covers
        // the scrub-position readout while the strip is open).
        currentTimeLabel.text = Self.formatTime(displayTime)

        remainingTimeLabel.text = "-\(Self.formatTime(max(0, duration - displayTime)))"

        let endsAt = Date().addingTimeInterval(max(0, duration - displayTime))
        endsAtLabel.text = "Ends at \(Self.endsAtFormatter.string(from: endsAt))"
        endsAtLabel.isHidden = duration <= 0 || stripOpen

        scrubStepLabel.isHidden = !isScrubbing || scrubStepLabelText == nil
        scrubStepLabel.text = scrubStepLabelText

        // No-BIF fallback: unchanged floating single-thumbnail behavior.
        thumbnailContainer.isHidden = !(isScrubbing && !stripOpen && scrubThumbnail != nil)
        thumbnailImageView.image = scrubThumbnail
        if isScrubbing && !stripOpen {
            // Clamp the thumbnail inside the track bounds like
            // AVPlayerViewController does at the extremes.
            let halfThumb = Metrics.thumbnailWidth / 2
            let clampedCenter = min(max(width * CGFloat(progress), halfThumb), max(halfThumb, width - halfThumb))
            thumbnailCenterXConstraint.constant = clampedCenter
        }

        readoutContainer.isHidden = !stripOpen
        dimOverlay.isHidden = !stripOpen
        playheadBar.isHidden = !stripOpen
        playheadBarBacking.isHidden = !stripOpen

        let showWheelIndicator = stripOpen && isScrubbing && isWheelScrubbing
        wheelRing.isHidden = !showWheelIndicator
        wheelDot.isHidden = !showWheelIndicator
    }

    /// Loading placeholder: keeps the locked geometry and vertical rhythm
    /// while playback starts. update(...) is a no-op while on.
    func setSkeleton(_ on: Bool) {
        guard on != isSkeleton else { return }
        isSkeleton = on
        trackBackground.backgroundColor = UIColor.white.withAlphaComponent(on ? 0.08 : 0.16)
        progressFill.isHidden = on
        handleView.isHidden = on
        handleRing.isHidden = on
        endsAtLabel.isHidden = on || duration <= 0
        markersContainer.isHidden = on
        let skeletonColor = UIColor.white.withAlphaComponent(0.22)
        if on {
            currentTimeLabel.text = "--:--"
            remainingTimeLabel.text = "--:--"
            currentTimeLabel.textColor = skeletonColor
            remainingTimeLabel.textColor = skeletonColor
            addSkeletonShimmer()
        } else {
            currentTimeLabel.textColor = UIColor.white.withAlphaComponent(0.82)
            remainingTimeLabel.textColor = UIColor.white.withAlphaComponent(0.55)
            removeSkeletonShimmer()
        }
    }

    /// Dedicated-layer shimmer sanctioned outside the one-clock rule: the
    /// skeleton never coexists with the strip morph (`update(...)` guards
    /// on `isSkeleton` as its very first line), so this `CAGradientLayer` +
    /// `CABasicAnimation` never competes with the UIView-animation clock
    /// that drives the morph. Masked to `trackBackground`'s rounded bounds
    /// so the shimmer stays inside the track.
    private static let shimmerAnimationKey = "skeletonShimmer"
    private var shimmerLayer: CAGradientLayer?

    private func addSkeletonShimmer() {
        removeSkeletonShimmer()
        let layer = CAGradientLayer()
        layer.colors = [UIColor.clear.cgColor,
                        UIColor.white.withAlphaComponent(0.22).cgColor,
                        UIColor.clear.cgColor]
        layer.startPoint = CGPoint(x: 0, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 0.5)
        layer.locations = [-0.4, -0.2, 0]
        layer.frame = trackBackground.bounds
        trackBackground.layer.addSublayer(layer)
        shimmerLayer = layer

        let animation = CABasicAnimation(keyPath: "locations")
        animation.fromValue = [-0.4, -0.2, 0] as [NSNumber]
        animation.toValue = [1, 1.2, 1.4] as [NSNumber]
        animation.duration = 1.8
        animation.repeatCount = .infinity
        layer.add(animation, forKey: Self.shimmerAnimationKey)
    }

    private func removeSkeletonShimmer() {
        guard let layer = shimmerLayer else { return }
        layer.removeAnimation(forKey: Self.shimmerAnimationKey)
        layer.removeFromSuperlayer()
        shimmerLayer = nil
    }

    /// Paused presentation: the accent fill dims while paused (2a spec).
    /// Applied immediately here (not via `update(...)`) because time ticks
    /// stop while the player is paused, so no later `update(...)` would
    /// pick up the change. The immediate setter only runs when the strip is
    /// closed and no skeleton, so it never races the morph block or the
    /// skeleton's own fill handling (one-clock rule).
    func setPausedDim(_ dimmed: Bool) {
        guard dimmed != isPausedDim else { return }
        isPausedDim = dimmed
        guard !isSkeleton, !isScrubbing else { return }
        UIView.animate(withDuration: 0.25) {
            self.progressFill.alpha = dimmed ? 0.55 : 1
        }
    }

    /// Tracked purely so `update(...)` can detect the scrub-start/scrub-
    /// end edge without adding a parameter to every call site.
    private var isScrubbing = false

    // MARK: - Filmstrip load

    private func beginFilmstripLoad() {
        guard stripLoadTask == nil, !stripLoaded, let provider = filmstripProvider else { return }
        let width = trackBackground.bounds.width
        guard width > 0, duration > 0 else { return }
        let tileWidth = Metrics.stripHeight * Metrics.stripTileAspect
        let count = max(1, Int(ceil(width / tileWidth)))
        let times = (0..<count).map { duration * (Double($0) + 0.5) / Double(count) }
        stripLoadTask = Task { [weak self] in
            let images = await provider(times, tileWidth * 2)  // 2x for scale
            guard let self, !Task.isCancelled else { return }
            let loaded = images.contains { $0 != nil }
            if loaded { self.populateStrip(images: images, tileWidth: tileWidth) }
            self.stripLoaded = loaded
            self.stripLoadTask = nil
            // Re-run the morph now that data exists, if still scrubbing.
            if loaded && self.isScrubbing {
                self.reapplyStripMorph()
            }
        }
    }

    /// Re-applies the strip-open morph after an async filmstrip load
    /// completes mid-scrub. Rides the same single animate block as
    /// `update(...)` so it stays on the one clock.
    private func reapplyStripMorph() {
        let width = trackBackground.bounds.width
        trackHeightConstraint.constant = Metrics.stripHeight
        UIView.animate(withDuration: 0.15) {
            self.progressFill.alpha = 0
            self.stripContainer.alpha = 1
            self.handleView.isHidden = true
            self.handleRing.isHidden = true
            self.layoutIfNeeded()
        }
        currentPositionGhost.isHidden = true
        readoutContainer.isHidden = false
        renderMarkers(lastMarkers, duration: duration, trackWidth: width, trackHeight: 4, bottomAligned: true)
        trackBackground.bringSubviewToFront(markersContainer)
        layoutStripOverlay(progress: lastProgress, currentProgress: lastCurrentProgress, width: width)
    }

    /// Clears all cached filmstrip state so the next scrub re-fetches
    /// frames from scratch. Must be called whenever the view model swaps
    /// to a different playable item (e.g. auto-advancing to the next
    /// episode) on this same, reused `PlayerProgressBarView` instance —
    /// otherwise `stripLoaded` stays sticky and the old item's tiles are
    /// shown instantly on the next scrub. Safe to call mid-scrub: if the
    /// strip is currently open, it's closed back to the thin-bar rest
    /// state first so nothing is left showing stale frames.
    func resetFilmstrip() {
        stripLoadTask?.cancel()
        stripLoadTask = nil
        stripLoaded = false
        stripTiles.forEach { $0.removeFromSuperview() }
        stripTiles.removeAll()

        // Segment containers (and the tiles they parent) are per-item —
        // clear them along with the layout so the next scrub rebuilds
        // from the new item's chapters rather than reusing stale geometry.
        segmentContainers.forEach { $0.removeFromSuperview() }
        segmentContainers.removeAll()
        segmentLayout = nil

        // Chapters change per item — clear cached seam state so the next
        // scrub rebuilds seams from the new item's chapters rather than
        // reusing stale x positions from the previous title.
        chapterSeams.forEach { $0.removeFromSuperview() }
        chapterSeams.removeAll()
        lastChapters = []
        lastSeamsChapterIds = []
        lastSeamWidth = 0

        let wasStripOpen = stripContainer.alpha > 0
        guard wasStripOpen else { return }

        trackHeightConstraint.constant = Metrics.trackHeight
        UIView.animate(withDuration: 0.15) {
            self.stripContainer.alpha = 0
            self.progressFill.alpha = 1
            self.handleView.isHidden = false
            self.handleRing.isHidden = false
            self.layoutIfNeeded()
        }
        currentPositionGhost.isHidden = !isScrubbing
        readoutContainer.isHidden = true
        wheelRing.isHidden = true
        wheelDot.isHidden = true
        livePositionLine.isHidden = true
        dimOverlay.isHidden = true
        playheadBar.isHidden = true
        playheadBarBacking.isHidden = true
        progressLineTrack.isHidden = true
        progressLineFill.isHidden = true
        renderMarkers(lastMarkers, duration: duration, trackWidth: trackBackground.bounds.width,
                      trackHeight: Metrics.trackHeight, bottomAligned: false)
    }

    /// Builds one full-width row of BIF tiles per chapter segment, each
    /// parented inside that segment's own rounded, clipping container so
    /// the tiles crop to chapter-proportional blocks with gaps between
    /// them. Each container gets its own copy of the tile row offset by
    /// `-segment.rect.minX`, so the container's `clipsToBounds` alone does
    /// the cropping — the same tile image just repeats across containers,
    /// but only the portion inside each container's bounds is visible.
    private func populateStrip(images: [UIImage?], tileWidth: CGFloat) {
        stripTiles.forEach { $0.removeFromSuperview() }
        stripTiles.removeAll()
        segmentContainers.forEach { $0.removeFromSuperview() }
        segmentContainers.removeAll()

        let width = trackBackground.bounds.width
        let layout = ChapterSegmentLayout(chapters: lastChapters, duration: duration,
                                           width: width, height: Metrics.stripHeight, gap: 6)
        segmentLayout = layout

        for segment in layout.segments {
            let container = UIView()
            container.layer.cornerRadius = 14
            container.layer.cornerCurve = .continuous
            container.clipsToBounds = true
            container.frame = segment.rect
            stripContainer.insertSubview(container, at: 0)
            segmentContainers.append(container)

            for (index, image) in images.enumerated() {
                let tile = UIImageView(image: image)
                tile.contentMode = .scaleAspectFill
                tile.clipsToBounds = true
                tile.backgroundColor = UIColor.white.withAlphaComponent(0.08)
                let tileX = CGFloat(index) * tileWidth
                tile.frame = CGRect(x: tileX - segment.rect.minX, y: 0, width: tileWidth, height: Metrics.stripHeight)
                container.addSubview(tile)
                stripTiles.append(tile)
            }
        }

        // Keep the dim overlay, live-position line, and bottom progress
        // line above the segment containers (and their tiles). The
        // playhead bar itself is a sibling of stripContainer on self, not
        // a child, so it isn't part of this stack.
        stripContainer.bringSubviewToFront(dimOverlay)
        stripContainer.bringSubviewToFront(livePositionLine)
        stripContainer.bringSubviewToFront(progressLineTrack)

        // Segments changed identity — force the seam ticks to rebuild
        // against the new layout on the next overlay pass.
        lastSeamsChapterIds = []
        lastSeamWidth = 0

        setNeedsLayout()
    }

    private func layoutStripOverlay(progress: Double, currentProgress: Double, width: CGFloat) {
        // The scrub-position → time mapping stays LINEAR (unchanged) —
        // segments are a display treatment only. `segmentLayout.x(for:)`
        // is used purely to position strip overlays (playhead bar, live
        // line, dim width, readout, bottom progress line) against the
        // chapter-proportional segment geometry.
        let displayTime = duration > 0 ? Double(progress) * duration : 0
        let currentTime = duration > 0 ? Double(currentProgress) * duration : 0

        let lineWidth: CGFloat = 2
        let playheadX = segmentLayout?.x(for: displayTime) ?? width * CGFloat(progress)

        let liveX = segmentLayout?.x(for: currentTime) ?? width * CGFloat(currentProgress)
        livePositionLine.isHidden = false
        livePositionLine.frame = CGRect(x: liveX - lineWidth / 2, y: 0, width: lineWidth, height: Metrics.stripHeight)

        // Played-side dim: black .5 → .08 gradient from the strip's start
        // up to the playhead.
        dimOverlay.isHidden = false
        dimOverlay.frame = CGRect(x: 0, y: 0, width: max(0, playheadX), height: Metrics.stripHeight)

        rebuildChapterSeamsIfNeeded(width: width)

        // Bottom progress line: 5pt ribbon pinned inside the strip's own
        // bottom edge, full ribbon width; the gradient fill is sized to
        // the seek fraction (playheadX / width, i.e. the SAME fraction the
        // playhead bar uses, so the two stay visually in lockstep).
        let progressLineHeight: CGFloat = 5
        progressLineTrack.frame = CGRect(x: 0, y: Metrics.stripHeight - progressLineHeight,
                                         width: width, height: progressLineHeight)
        progressLineTrack.isHidden = false
        progressLineFill.frame = CGRect(x: 0, y: 0, width: max(0, playheadX), height: progressLineHeight)
        progressLineFill.isHidden = false

        // Oversized readout: eyebrow (chapter name, hidden when the
        // playhead isn't inside a named chapter) + large timecode, clamped
        // fully on-screen exactly like the old chip.
        let eyebrowText = chapterEyebrowText(at: displayTime)
        readoutEyebrowLabel.isHidden = eyebrowText == nil
        if let eyebrowText {
            readoutEyebrowLabel.attributedText = NSAttributedString(
                string: eyebrowText,
                attributes: [.kern: 16 * 0.12]
            )
        }
        readoutTimecodeLabel.text = Self.formatTime(displayTime)

        readoutEyebrowLabel.sizeToFit()
        readoutTimecodeLabel.sizeToFit()
        let readoutWidth = max(readoutEyebrowLabel.bounds.width, readoutTimecodeLabel.bounds.width)
        let readoutSpacing: CGFloat = readoutEyebrowLabel.isHidden ? 0 : 4
        let readoutHeight = (readoutEyebrowLabel.isHidden ? 0 : readoutEyebrowLabel.bounds.height + readoutSpacing)
            + readoutTimecodeLabel.bounds.height
        readoutContainer.bounds = CGRect(x: 0, y: 0, width: readoutWidth, height: readoutHeight)

        readoutEyebrowLabel.center = CGPoint(x: readoutWidth / 2, y: readoutEyebrowLabel.bounds.height / 2)
        readoutTimecodeLabel.center = CGPoint(
            x: readoutWidth / 2,
            y: readoutHeight - readoutTimecodeLabel.bounds.height / 2
        )

        let halfReadout = readoutWidth / 2
        let clampedCenter = min(max(playheadX, halfReadout), max(halfReadout, width - halfReadout))
        readoutContainer.center = CGPoint(x: clampedCenter, y: trackBackground.frame.minY - Metrics.thumbnailGap - readoutHeight / 2)

        // Playhead bar: 8pt white glowing bar on a 16pt black@0.4 rounded
        // backing, both spanning from stripTop − 14 to stripBottom + 14 —
        // anchored to the STRIP's playhead x (which can differ slightly
        // from the thin-bar handle x below by design — segments distort x
        // but the bar only ever connects to the strip directly above it).
        let barTop = trackBackground.frame.minY - 14
        let barHeight = Metrics.stripHeight + 28
        playheadBar.isHidden = false
        playheadBar.frame = CGRect(x: playheadX - 4, y: barTop, width: 8, height: barHeight)
        // Explicit shadowPath: without it CA rasterizes the glow offscreen on
        // every frame the bar moves (60fps while scrubbing).
        playheadBar.layer.shadowPath = UIBezierPath(
            roundedRect: playheadBar.bounds, cornerRadius: 6).cgPath
        playheadBarBacking.isHidden = false
        playheadBarBacking.frame = CGRect(x: playheadX - 8, y: barTop, width: 16, height: barHeight)

        layoutWheelIndicator(progress: progress, calloutCenter: readoutContainer.center, calloutHalfWidth: halfReadout, width: width)
    }

    /// "CHAPTER n · NAME" for the chapter containing `time` (n = 1-based
    /// ordinal, NAME uppercased), or `nil` when there's no chapter at that
    /// time or the chapter has no name — the readout's eyebrow hides in
    /// that case, matching the old chip's suffix-less fallback.
    private func chapterEyebrowText(at time: TimeInterval) -> String? {
        for (index, chapter) in lastChapters.enumerated() {
            guard let startMs = chapter.startTimeOffset else { continue }
            let start = TimeInterval(startMs) / 1000.0
            let end = chapter.endTimeOffset.map { TimeInterval($0) / 1000.0 } ?? duration
            guard time >= start && time < end else { continue }
            guard let tag = chapter.tag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty else {
                return nil
            }
            return "CHAPTER \(index + 1) · \(tag.uppercased())"
        }
        return nil
    }

    /// Positions the 44pt ring + orbiting 6pt dot beside the readout while
    /// a circular clickpad rotation is driving the scrub. The ring sits to
    /// the right of the readout (or the left, clamped inside the track
    /// bounds, if the readout is pinned to the right edge). The dot orbits
    /// the ring center at `angle = progress * 4 * .pi` — two full laps
    /// across the track — so it visibly advances with scrub progress
    /// rather than just sitting at a fixed rest position.
    private func layoutWheelIndicator(progress: Double, calloutCenter: CGPoint, calloutHalfWidth: CGFloat, width: CGFloat) {
        guard isWheelScrubbing else { return }

        let ringRadius = Metrics.wheelRingDiameter / 2
        let preferredCenterX = calloutCenter.x + calloutHalfWidth + Metrics.wheelRingGap + ringRadius
        let ringCenterX: CGFloat
        if preferredCenterX + ringRadius > width {
            // Callout is pinned near the right edge; place the ring on
            // its left side instead so it stays on-screen.
            ringCenterX = calloutCenter.x - calloutHalfWidth - Metrics.wheelRingGap - ringRadius
        } else {
            ringCenterX = preferredCenterX
        }
        let ringCenter = CGPoint(x: ringCenterX, y: calloutCenter.y)

        wheelRing.frame = CGRect(
            x: ringCenter.x - ringRadius,
            y: ringCenter.y - ringRadius,
            width: Metrics.wheelRingDiameter,
            height: Metrics.wheelRingDiameter
        )

        let angle = CGFloat(progress) * 4 * .pi
        let dotRadius = Metrics.wheelDotDiameter / 2
        let dotCenter = CGPoint(
            x: ringCenter.x + sin(angle) * ringRadius,
            y: ringCenter.y - cos(angle) * ringRadius
        )
        wheelDot.frame = CGRect(
            x: dotCenter.x - dotRadius,
            y: dotCenter.y - dotRadius,
            width: Metrics.wheelDotDiameter,
            height: Metrics.wheelDotDiameter
        )
    }

    /// Rebuilds the chapter boundary ticks only when the chapter list or
    /// track width has changed, so this is cheap to call on every strip
    /// layout pass while scrubbing. With segments, the gap between
    /// adjacent segment containers already visually separates chapters;
    /// the tick is a 2pt `white@0.22` hairline centered in that gap (i.e.
    /// at the midpoint between one segment's trailing edge and the next
    /// segment's leading edge). Skipped entirely when there's only one
    /// segment — no chapters, no gaps, no ticks.
    private func rebuildChapterSeamsIfNeeded(width: CGFloat) {
        guard lastChapters.map(\.id) != lastSeamsChapterIds || width != lastSeamWidth else { return }
        lastSeamsChapterIds = lastChapters.map(\.id)
        lastSeamWidth = width

        chapterSeams.forEach { $0.removeFromSuperview() }
        chapterSeams.removeAll()

        guard let layout = segmentLayout, layout.segments.count > 1 else { return }

        let seamWidth: CGFloat = 2
        for i in 0..<(layout.segments.count - 1) {
            let trailingEdge = layout.segments[i].rect.maxX
            let leadingEdge = layout.segments[i + 1].rect.minX
            let x = (trailingEdge + leadingEdge) / 2
            let seam = UIView()
            seam.backgroundColor = UIColor.white.withAlphaComponent(0.22)
            seam.frame = CGRect(x: x - seamWidth / 2, y: 0, width: seamWidth, height: Metrics.stripHeight)
            stripContainer.insertSubview(seam, at: 0)
            chapterSeams.append(seam)
        }
        // Seams sit above the segment containers/tiles but below the dim
        // overlay, the live line, and the bottom progress line.
        chapterSeams.forEach { stripContainer.bringSubviewToFront($0) }
        stripContainer.bringSubviewToFront(dimOverlay)
        stripContainer.bringSubviewToFront(livePositionLine)
        stripContainer.bringSubviewToFront(progressLineTrack)
    }

    private func renderMarkers(_ markers: [PlexMarker], duration: TimeInterval, trackWidth: CGFloat, trackHeight: CGFloat, bottomAligned: Bool) {
        markersContainer.subviews.forEach { $0.removeFromSuperview() }
        guard duration > 0 else { return }

        // Use the constraint's target height (already updated by the
        // caller before this runs), not `trackBackground.bounds`, which
        // still reflects the pre-morph size until `layoutIfNeeded()`
        // executes inside the animate block.
        let containerHeight = trackHeightConstraint.constant
        for marker in markers {
            let startProgress = max(0, marker.startTimeSeconds / duration)
            let endProgress = min(1, marker.endTimeSeconds / duration)
            guard endProgress > startProgress else { continue }

            let markerView = UIView()
            markerView.backgroundColor = Self.color(for: marker).withAlphaComponent(0.85)
            let x = trackWidth * CGFloat(startProgress)
            let markerWidth = max(4, trackWidth * CGFloat(endProgress - startProgress))
            let y = bottomAligned ? max(0, containerHeight - trackHeight) : 0
            markerView.frame = CGRect(x: x, y: y, width: markerWidth, height: trackHeight)
            markersContainer.addSubview(markerView)
        }
    }

    private static func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}
