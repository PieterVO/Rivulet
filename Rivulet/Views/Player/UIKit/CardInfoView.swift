import UIKit

// MARK: - CardInfoView (Task 6 — ported from PlayerInfoPopupView)

/// In-card info/tech sheet panel. Ported from PlayerInfoPopupView: same
/// scroll+stack layout, populate() section builders, formatters, and the
/// 1Hz live-tick lifecycle tied to window attach/detach — minus the glass
/// background and AnchoredPopupPresenting conformance/Menu handling (the
/// card owns Menu and framing now).
final class CardInfoView: UIView {

    private let metadata: PlexMetadata
    /// Supplies a fresh engine snapshot on demand. nil on the `hls` route
    /// (no AetherPlayer) — in that case the PLAYBACK section is omitted
    /// entirely rather than showing stale or synthesized numbers.
    private let liveStatsProvider: (() -> AetherLiveStats?)?
    private let scrollView = InfoScrollView()
    private let stack = UIStackView()

    /// Fires when the scroll surface gains/loses focus, so the hosting
    /// panel can show a focus treatment the sheet itself can't draw
    /// (the panel ring is the natural boundary to brighten).
    var onFocusChange: ((Bool) -> Void)?

    /// Live PLAYBACK rows, updated in place every tick. nil when the
    /// PLAYBACK section was omitted at populate() time.
    private var bufferRow: UILabel?
    private var backendRow: UILabel?
    private var audioBridgeRow: UILabel?
    private var liveTickTimer: Timer?

    init(metadata: PlexMetadata, liveStatsProvider: (() -> AetherLiveStats?)? = nil) {
        self.metadata = metadata
        self.liveStatsProvider = liveStatsProvider
        super.init(frame: .zero)
        setupViews()
        populate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Live tick lifecycle
    //
    // The panel is hosted by PlayerRailPanelView, whose dismissPanel()
    // always ends in removeFromSuperview() for the outgoing panel — so
    // didMoveToWindow with window == nil is a reliable "panel is gone"
    // signal for tearing the timer down. Starting in didMoveToWindow
    // (rather than init) avoids ticking a timer for a view that's
    // constructed but never actually shown.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            startLiveTick()
        } else {
            stopLiveTick()
        }
    }

    private func startLiveTick() {
        guard liveStatsProvider != nil, liveTickTimer == nil else { return }
        liveTickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshLiveRows()
            }
        }
    }

    private func stopLiveTick() {
        liveTickTimer?.invalidate()
        liveTickTimer = nil
    }

    private func refreshLiveRows() {
        guard let stats = liveStatsProvider?() else { return }
        if let bufferRow, let seconds = stats.bufferedSeconds {
            bufferRow.text = "Buffer: \(Self.formatBufferSeconds(seconds))"
        }
        if let backendRow, let backend = stats.backend {
            backendRow.text = "Backend: \(backend)"
        }
        if let audioBridgeRow, let audioBridge = stats.audioBridge {
            audioBridgeRow.text = "Audio Bridge: \(audioBridge)"
        }
    }

    private func setupViews() {
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .leading
        scrollView.addSubview(stack)
        addSubview(scrollView)
        scrollView.onFocusChange = { [weak self] focused in
            self?.onFocusChange?(focused)
        }

        [scrollView, stack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        // The scroll view grows with content up to the panel's own height
        // cap, so a short info sheet hugs its rows instead of collapsing
        // to zero height — same idiom as CardTrackListView. Without this,
        // nothing propagates the stack's content size to the scroll view
        // (contentLayoutGuide-based content constraints alone don't size
        // the scroll view itself), and the panel — which sizes itself from
        // its content rather than a fixed frame like the old 2a card —
        // renders as an empty glass box.
        let scrollHeight = scrollView.heightAnchor.constraint(equalTo: stack.heightAnchor)
        scrollHeight.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollHeight,

            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
        ])
    }

    // MARK: - Content

    private var primaryVideoStream: PlexStream? {
        metadata.Media?.first?.Part?.first?.Stream?.first { $0.isVideo }
    }

    private var audioStreams: [PlexStream] {
        metadata.Media?.first?.Part?.first?.Stream?.filter { $0.isAudio } ?? []
    }

    private var subtitleStreams: [PlexStream] {
        metadata.Media?.first?.Part?.first?.Stream?.filter { $0.isSubtitle } ?? []
    }

    private func populate() {
        stack.addArrangedSubview(headerLabel("Media Info"))
        if let title = metadata.title {
            stack.addArrangedSubview(bodyLabel(title, secondary: true))
        }

        stack.addArrangedSubview(sectionLabel("VIDEO"))
        if let videoStream = primaryVideoStream {
            if let displayTitle = videoStream.displayTitle ?? videoStream.extendedDisplayTitle {
                stack.addArrangedSubview(infoRow("Format", displayTitle))
            }
            if videoStream.isDolbyVision {
                var dvInfo = "Profile \(videoStream.DOVIProfile ?? 0)"
                if let compatID = videoStream.DOVIBLCompatID {
                    dvInfo += " (CompatID \(compatID))"
                }
                stack.addArrangedSubview(infoRow("Dolby Vision", dvInfo))
            } else if videoStream.isHDR {
                stack.addArrangedSubview(infoRow("HDR", "HDR10"))
            }
            if let bitDepth = videoStream.bitDepth {
                stack.addArrangedSubview(infoRow("Bit Depth", "\(bitDepth)-bit"))
            }
            if let colorSpace = videoStream.colorSpace {
                stack.addArrangedSubview(infoRow("Color Space", colorSpace))
            }
        } else if let media = metadata.Media?.first {
            if let codec = media.videoCodec {
                stack.addArrangedSubview(infoRow("Codec", codec.uppercased()))
            }
            if let res = media.videoResolution {
                stack.addArrangedSubview(infoRow("Resolution", res))
            }
        }
        if let media = metadata.Media?.first {
            if let width = media.width, let height = media.height {
                stack.addArrangedSubview(infoRow("Dimensions", "\(width) × \(height)"))
            }
            if let frameRate = media.videoFrameRate {
                stack.addArrangedSubview(infoRow("Frame Rate", frameRate))
            }
            if let bitrate = media.bitrate {
                stack.addArrangedSubview(infoRow("Bitrate", Self.formatBitrate(bitrate)))
            }
        }

        if !audioStreams.isEmpty {
            stack.addArrangedSubview(sectionLabel("AUDIO"))
            for (index, stream) in audioStreams.enumerated() {
                let title = stream.displayTitle ?? stream.extendedDisplayTitle ?? "Track \(index + 1)"
                var detail = title
                if let bitrate = stream.bitrate {
                    detail += " · \(Self.formatBitrate(bitrate))"
                }
                if let sampleRate = stream.samplingRate {
                    detail += " · \(sampleRate / 1000) kHz"
                }
                stack.addArrangedSubview(bodyLabel(detail, secondary: false))
            }
        }

        populatePlaybackSection()

        if !subtitleStreams.isEmpty {
            stack.addArrangedSubview(sectionLabel("SUBTITLES"))
            for stream in subtitleStreams {
                var title = stream.extendedDisplayTitle ?? stream.displayTitle ?? "Unknown"
                var badges: [String] = []
                if stream.forced == true { badges.append("Forced") }
                if stream.hearingImpaired == true { badges.append("SDH") }
                if stream.default == true { badges.append("Default") }
                if !badges.isEmpty {
                    title += " (\(badges.joined(separator: ", ")))"
                }
                stack.addArrangedSubview(bodyLabel(title, secondary: false))
            }
        }

        if let part = metadata.Media?.first?.Part?.first {
            stack.addArrangedSubview(sectionLabel("FILE"))
            if let file = part.file {
                let filename = (file as NSString).lastPathComponent
                stack.addArrangedSubview(infoRow("Name", filename))
            }
            if let container = part.container ?? metadata.Media?.first?.container {
                stack.addArrangedSubview(infoRow("Container", container.uppercased()))
            }
            if let size = part.size {
                stack.addArrangedSubview(infoRow("Size", Self.formatFileSize(Int64(size))))
            }
            if let duration = metadata.duration ?? part.duration {
                stack.addArrangedSubview(infoRow("Duration", Self.formatDuration(duration)))
            }
        }
    }

    /// Live engine stats section, after the static VIDEO/AUDIO sections.
    /// Omitted entirely when there's no provider (the `hls` route has no
    /// AetherPlayer) or the first snapshot is all-nil — never rendered as
    /// an empty/placeholder header.
    private func populatePlaybackSection() {
        guard let stats = liveStatsProvider?(), !stats.isEmpty else { return }

        stack.addArrangedSubview(sectionLabel("PLAYBACK"))

        if let seconds = stats.bufferedSeconds {
            let row = bodyLabel("Buffer: \(Self.formatBufferSeconds(seconds))", secondary: false)
            stack.addArrangedSubview(row)
            bufferRow = row
        }
        if let backend = stats.backend {
            let row = bodyLabel("Backend: \(backend)", secondary: false)
            stack.addArrangedSubview(row)
            backendRow = row
        }
        if let audioBridge = stats.audioBridge {
            let row = bodyLabel("Audio Bridge: \(audioBridge)", secondary: false)
            stack.addArrangedSubview(row)
            audioBridgeRow = row
        }
    }

    // MARK: - Row builders

    private func headerLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 26, weight: .bold)
        label.textColor = .white
        return label
    }

    private func sectionLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 14, weight: .bold)
        label.textColor = UIColor.white.withAlphaComponent(0.5)
        return label
    }

    private func bodyLabel(_ text: String, secondary: Bool) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 18, weight: .regular)
        label.textColor = secondary ? UIColor.white.withAlphaComponent(0.6) : .white
        label.numberOfLines = 0
        return label
    }

    private func infoRow(_ label: String, _ value: String) -> UILabel {
        let row = UILabel()
        row.numberOfLines = 0
        let text = NSMutableAttributedString(
            string: "\(label): ",
            attributes: [.font: UIFont.systemFont(ofSize: 16, weight: .medium), .foregroundColor: UIColor.white.withAlphaComponent(0.6)]
        )
        text.append(NSAttributedString(
            string: value,
            attributes: [.font: UIFont.systemFont(ofSize: 18, weight: .regular), .foregroundColor: UIColor.white]
        ))
        row.attributedText = text
        return row
    }

    // MARK: - Formatting

    /// Whole seconds, clamped to never print negative (AetherPlayer.liveStats
    /// already clamps at the source, but the display layer stays defensive).
    private static func formatBufferSeconds(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        return "\(whole)s"
    }

    private static func formatBitrate(_ bitrate: Int) -> String {
        if bitrate >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bitrate) / 1_000_000.0)
        } else if bitrate >= 1000 {
            return String(format: "%.0f kbps", Double(bitrate) / 1000.0)
        } else {
            return "\(bitrate) bps"
        }
    }

    private static func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private static func formatDuration(_ milliseconds: Int) -> String {
        let totalSeconds = milliseconds / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

}

// MARK: - InfoScrollView

/// Focusable scroll surface for the info sheet. A plain UIScrollView is
/// inert on tvOS — with no focusable rows inside, the focus engine never
/// scrolls it and remote input goes nowhere. This takes focus itself,
/// lets the remote's indirect swipes drive the pan gesture directly, and
/// steps the offset on discrete up/down edge clicks.
private final class InfoScrollView: UIScrollView {

    var onFocusChange: ((Bool) -> Void)?

    private static let clickStep: CGFloat = 240

    override init(frame: CGRect) {
        super.init(frame: frame)
        panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        if focused {
            flashScrollIndicators()
        }
        onFocusChange?(focused)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .upArrow || press.type == .downArrow {
            // Swallowed even at the ends — the hosting panel's focus
            // fence traps focus here, so letting the press bubble would
            // only ask the focus engine for a move it must refuse.
            step(up: press.type == .upArrow)
            return
        }
        super.pressesBegan(presses, with: event)
    }

    private func step(up: Bool) {
        let topOffset = -adjustedContentInset.top
        let maxOffset = max(topOffset, contentSize.height + adjustedContentInset.bottom - bounds.height)
        let target = contentOffset.y + (up ? -Self.clickStep : Self.clickStep)
        let clamped = min(max(target, topOffset), maxOffset)
        guard clamped != contentOffset.y else { return }
        setContentOffset(CGPoint(x: contentOffset.x, y: clamped), animated: true)
    }
}
