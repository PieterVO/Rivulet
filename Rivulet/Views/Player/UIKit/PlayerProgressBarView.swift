//
//  PlayerProgressBarView.swift
//  Rivulet
//
//  Transport scrubber styled after AVPlayerViewController (tvOS 15+):
//  a thin rounded white bar with no knob — the fill edge is the playhead.
//  While scrubbing, the bar morphs into a 100pt filmstrip of BIF
//  trickplay frames with a hairline playhead and a fainter line marking
//  the actual playback position; a callout follows the playhead above
//  the strip. If no filmstrip data is available (still loading, or the
//  title has no BIF), scrubbing looks exactly like before: thin bar +
//  floating single thumbnail. Time remaining sits below the right end,
//  with an "Ends at" clock-time label beside it at rest. Plex markers
//  (intro/credits) tint their range on both the thin bar and the strip.
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

final class PlayerProgressBarView: UIView {

    // MARK: - Metrics (AVPlayerViewController-matched)

    private enum Metrics {
        static let trackHeight: CGFloat = 10
        static let stripHeight: CGFloat = 120
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
    private let playheadLine = UIView()
    private let livePositionLine = UIView()
    private let calloutLabel = UILabel()

    // Jog wheel indicator: shown beside the callout label only while a
    // circular clickpad rotation is actively driving the scrub
    // (`isWheelScrubbing`). Frame-driven like calloutLabel, positioned in
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
    /// PlayerTransportBarView to `UniversalPlayerViewModel.filmstripImages`.
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

        playheadLine.backgroundColor = .white
        livePositionLine.backgroundColor = UIColor.white.withAlphaComponent(0.5)
        stripContainer.addSubview(playheadLine)
        stripContainer.addSubview(livePositionLine)

        calloutLabel.font = .monospacedDigitSystemFont(ofSize: 23, weight: .semibold)
        calloutLabel.textColor = .white
        calloutLabel.textAlignment = .center
        calloutLabel.isHidden = true

        wheelRing.backgroundColor = .clear
        wheelRing.layer.borderWidth = Metrics.wheelRingBorderWidth
        wheelRing.layer.borderColor = UIColor.white.withAlphaComponent(0.3).cgColor
        wheelRing.layer.cornerRadius = Metrics.wheelRingDiameter / 2
        wheelRing.isHidden = true

        wheelDot.backgroundColor = .white
        wheelDot.layer.cornerRadius = Metrics.wheelDotDiameter / 2
        wheelDot.isHidden = true

        [trackBackground, thumbnailContainer, currentTimeLabel, remainingTimeLabel,
         endsAtLabel, scrubStepLabel, calloutLabel, wheelRing, wheelDot].forEach {
            addSubview($0)
        }
        [currentPositionGhost, progressFill, markersContainer, stripContainer].forEach {
            trackBackground.addSubview($0)
        }
        // Handle views are frame-driven siblings of trackBackground (not
        // children of it — the track clips its contents, which would
        // clip the handle's shadow and its overhang past the track edges).
        addSubview(handleRing)
        addSubview(handleView)

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
        stripContainer.layer.cornerRadius = trackBackground.layer.cornerRadius
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
            self.progressFill.alpha = stripOpen ? 0 : 1
            self.stripContainer.alpha = stripOpen ? 1 : 0
            self.progressFill.frame = CGRect(x: 0, y: 0, width: width * progress, height: trackHeight)
            if isScrubbing && !stripOpen {
                self.currentPositionGhost.frame = CGRect(
                    x: 0, y: 0,
                    width: width * currentProgress,
                    height: trackHeight
                )
            }

            // Handle: circle at rest, morphs to a tall rounded bar while
            // scrubbing. Frame-driven, positioned at the fill edge and
            // vertically centered on the track — a sibling of
            // trackBackground so it isn't clipped by the track's own
            // clipsToBounds.
            let handleSize: CGSize = isScrubbing ? CGSize(width: 14, height: 46) : CGSize(width: 24, height: 24)
            let ringInset: CGFloat = isScrubbing ? 5 : 6
            let handleX = width * CGFloat(progress)
            let trackMidY = self.trackBackground.frame.minY + trackHeight / 2
            self.handleView.frame = CGRect(x: handleX - handleSize.width / 2, y: trackMidY - handleSize.height / 2,
                                           width: handleSize.width, height: handleSize.height)
            self.handleView.layer.cornerRadius = isScrubbing ? 8 : handleSize.width / 2
            self.handleRing.frame = self.handleView.frame.insetBy(dx: -ringInset, dy: -ringInset)
            self.handleRing.layer.cornerRadius = isScrubbing ? 8 + ringInset : self.handleRing.frame.width / 2
            self.handleRing.backgroundColor = UIColor.white.withAlphaComponent(isScrubbing ? 0.16 : 0.14)

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
        // or clamping needed; the callout above the strip covers the
        // scrub-position readout while the strip is open).
        currentTimeLabel.text = Self.formatTime(displayTime)

        remainingTimeLabel.text = "-\(Self.formatTime(max(0, duration - displayTime)))"

        let endsAt = Date().addingTimeInterval(max(0, duration - displayTime))
        endsAtLabel.text = "Ends at \(Self.endsAtFormatter.string(from: endsAt))"
        endsAtLabel.isHidden = duration <= 0

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

        calloutLabel.isHidden = !stripOpen

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
        } else {
            currentTimeLabel.textColor = UIColor.white.withAlphaComponent(0.82)
            remainingTimeLabel.textColor = UIColor.white.withAlphaComponent(0.55)
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
            self.layoutIfNeeded()
        }
        currentPositionGhost.isHidden = true
        calloutLabel.isHidden = false
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
            self.layoutIfNeeded()
        }
        currentPositionGhost.isHidden = !isScrubbing
        calloutLabel.isHidden = true
        wheelRing.isHidden = true
        wheelDot.isHidden = true
        livePositionLine.isHidden = true
        renderMarkers(lastMarkers, duration: duration, trackWidth: trackBackground.bounds.width,
                      trackHeight: Metrics.trackHeight, bottomAligned: false)
    }

    private func populateStrip(images: [UIImage?], tileWidth: CGFloat) {
        stripTiles.forEach { $0.removeFromSuperview() }
        stripTiles.removeAll()

        for (index, image) in images.enumerated() {
            let tile = UIImageView(image: image)
            tile.contentMode = .scaleAspectFill
            tile.clipsToBounds = true
            tile.backgroundColor = UIColor.white.withAlphaComponent(0.08)
            tile.frame = CGRect(x: CGFloat(index) * tileWidth, y: 0, width: tileWidth, height: Metrics.stripHeight)
            stripContainer.insertSubview(tile, at: 0)
            stripTiles.append(tile)
        }
        // Keep the playhead/live-position lines above the tiles.
        stripContainer.bringSubviewToFront(playheadLine)
        stripContainer.bringSubviewToFront(livePositionLine)
    }

    private func layoutStripOverlay(progress: Double, currentProgress: Double, width: CGFloat) {
        let lineWidth: CGFloat = 2
        let playheadX = width * CGFloat(progress)
        playheadLine.frame = CGRect(x: playheadX - lineWidth / 2, y: 0, width: lineWidth, height: Metrics.stripHeight)

        let liveX = width * CGFloat(currentProgress)
        livePositionLine.isHidden = false
        livePositionLine.frame = CGRect(x: liveX - lineWidth / 2, y: 0, width: lineWidth, height: Metrics.stripHeight)

        rebuildChapterSeamsIfNeeded(width: width)

        let displayTime = duration > 0 ? Double(progress) * duration : 0
        let chapterName = chapterName(at: displayTime)
        if let chapterName {
            calloutLabel.text = "\(Self.formatTime(displayTime)) · \(chapterName)"
        } else {
            calloutLabel.text = Self.formatTime(displayTime)
        }
        calloutLabel.sizeToFit()
        let halfLabel = calloutLabel.bounds.width / 2
        let clampedCenter = min(max(playheadX, halfLabel), max(halfLabel, width - halfLabel))
        calloutLabel.center = CGPoint(x: clampedCenter, y: trackBackground.frame.minY - Metrics.thumbnailGap - calloutLabel.bounds.height / 2)

        layoutWheelIndicator(progress: progress, calloutCenter: calloutLabel.center, calloutHalfWidth: halfLabel, width: width)
    }

    /// Positions the 44pt ring + orbiting 6pt dot beside `calloutLabel`
    /// while a circular clickpad rotation is driving the scrub. The ring
    /// sits to the right of the callout (or the left, clamped inside the
    /// track bounds, if the callout is pinned to the right edge). The dot
    /// orbits the ring center at `angle = progress * 4 * .pi` — two full
    /// laps across the track — so it visibly advances with scrub
    /// progress rather than just sitting at a fixed rest position.
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

    /// The chapter tag whose range contains `time`, if it has a non-empty name.
    private func chapterName(at time: TimeInterval) -> String? {
        for chapter in lastChapters {
            guard let startMs = chapter.startTimeOffset else { continue }
            let start = TimeInterval(startMs) / 1000.0
            let end = chapter.endTimeOffset.map { TimeInterval($0) / 1000.0 } ?? duration
            guard time >= start && time < end else { continue }
            guard let tag = chapter.tag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty else {
                return nil
            }
            return tag
        }
        return nil
    }

    /// Rebuilds the chapter seam hairlines only when the chapter list or
    /// track width has changed, so this is cheap to call on every strip
    /// layout pass while scrubbing.
    private func rebuildChapterSeamsIfNeeded(width: CGFloat) {
        guard lastChapters.map(\.id) != lastSeamsChapterIds || width != lastSeamWidth else { return }
        lastSeamsChapterIds = lastChapters.map(\.id)
        lastSeamWidth = width

        chapterSeams.forEach { $0.removeFromSuperview() }
        chapterSeams.removeAll()

        guard duration > 0 else { return }
        let seamWidth: CGFloat = 1
        for chapter in lastChapters {
            guard let startMs = chapter.startTimeOffset else { continue }
            let start = TimeInterval(startMs) / 1000.0
            guard start > 0 else { continue }  // no seam at the very start of the strip
            let x = width * CGFloat(min(1, max(0, start / duration)))
            let seam = UIView()
            seam.backgroundColor = UIColor.white.withAlphaComponent(0.35)
            seam.frame = CGRect(x: x - seamWidth / 2, y: 0, width: seamWidth, height: Metrics.stripHeight)
            stripContainer.insertSubview(seam, at: 0)
            chapterSeams.append(seam)
        }
        // Seams sit above the tiles but below the playhead/live lines.
        chapterSeams.forEach { stripContainer.bringSubviewToFront($0) }
        stripContainer.bringSubviewToFront(playheadLine)
        stripContainer.bringSubviewToFront(livePositionLine)
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
