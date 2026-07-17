import UIKit

// MARK: - StreamingModeInfo

/// Per-category delivery mode (Direct Play / Direct Stream / Transcode)
/// shown at the top of each section, so users can confirm playback status
/// without opening the Plex server dashboard.
struct StreamingModeInfo {
    enum Mode: String {
        case directPlay = "Direct Play"
        case directStream = "Direct Stream"
        case transcode = "Transcode"
    }
    let video: Mode
    let audio: Mode
    let subtitles: Mode
}

// MARK: - CardInfoView (Info tab)

/// Static media/tech sheet — the Info tab of the player's Now Playing popup.
/// Pure metadata (Media Info, VIDEO, AUDIO, SUBTITLES, FILE); no live rows and
/// no timer. Live playback telemetry now lives on the sibling Advanced tab
/// (`CardStatsView`). Rows are built through `PlayerInfoSheetStyle` so the two
/// sheets stay visually identical.
final class CardInfoView: UIView {

    private let metadata: PlexMetadata
    private let modes: StreamingModeInfo
    private let scrollView = InfoScrollView()
    private let stack = UIStackView()

    /// Fires when the scroll surface gains/loses focus, so the hosting panel
    /// can show a focus treatment the sheet itself can't draw.
    var onFocusChange: ((Bool) -> Void)? {
        didSet { scrollView.onFocusChange = onFocusChange }
    }

    /// Fires on an Up press while the sheet is scrolled to the top — the tab
    /// container wires this to move focus up to the tab bar.
    var onEscapeUp: (() -> Void)? {
        didSet { scrollView.onEscapeUp = onEscapeUp }
    }

    init(metadata: PlexMetadata, modes: StreamingModeInfo) {
        self.metadata = metadata
        self.modes = modes
        super.init(frame: .zero)
        setupViews()
        populate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .leading
        scrollView.addSubview(stack)
        addSubview(scrollView)

        [scrollView, stack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        // The scroll view grows with content up to the panel's own height
        // cap, so a short info sheet hugs its rows instead of collapsing
        // to zero height — same idiom as CardTrackListView.
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
        stack.addArrangedSubview(PlayerInfoSheetStyle.headerLabel("Media Info"))
        if let title = metadata.title {
            stack.addArrangedSubview(PlayerInfoSheetStyle.bodyLabel(title, secondary: true))
        }

        stack.addArrangedSubview(PlayerInfoSheetStyle.sectionLabel("VIDEO"))
        stack.addArrangedSubview(PlayerInfoSheetStyle.infoRow("Mode", modes.video.rawValue))
        if let videoStream = primaryVideoStream {
            if let displayTitle = videoStream.displayTitle ?? videoStream.extendedDisplayTitle {
                stack.addArrangedSubview(PlayerInfoSheetStyle.infoRow("Format", displayTitle))
            }
            if videoStream.isDolbyVision {
                var dvInfo = "Profile \(videoStream.DOVIProfile ?? 0)"
                if let compatID = videoStream.DOVIBLCompatID {
                    dvInfo += " (CompatID \(compatID))"
                }
                stack.addArrangedSubview(PlayerInfoSheetStyle.infoRow("Dolby Vision", dvInfo))
            } else if videoStream.isHDR {
                stack.addArrangedSubview(PlayerInfoSheetStyle.infoRow("HDR", "HDR10"))
            }
            if let bitDepth = videoStream.bitDepth {
                stack.addArrangedSubview(PlayerInfoSheetStyle.infoRow("Bit Depth", "\(bitDepth)-bit"))
            }
            if let colorSpace = videoStream.colorSpace {
                stack.addArrangedSubview(PlayerInfoSheetStyle.infoRow("Color Space", colorSpace))
            }
        } else if let media = metadata.Media?.first {
            if let codec = media.videoCodec {
                stack.addArrangedSubview(PlayerInfoSheetStyle.infoRow("Codec", codec.uppercased()))
            }
            if let res = media.videoResolution {
                stack.addArrangedSubview(PlayerInfoSheetStyle.infoRow("Resolution", res))
            }
        }
        if let media = metadata.Media?.first {
            if let width = media.width, let height = media.height {
                stack.addArrangedSubview(PlayerInfoSheetStyle.infoRow("Dimensions", "\(width) × \(height)"))
            }
            if let frameRate = media.videoFrameRate {
                stack.addArrangedSubview(PlayerInfoSheetStyle.infoRow("Frame Rate", frameRate))
            }
            if let bitrate = media.bitrate {
                stack.addArrangedSubview(PlayerInfoSheetStyle.infoRow("Bitrate", PlayerInfoSheetStyle.bitrate(bitrate)))
            }
        }

        if !audioStreams.isEmpty {
            stack.addArrangedSubview(PlayerInfoSheetStyle.sectionLabel("AUDIO"))
            stack.addArrangedSubview(PlayerInfoSheetStyle.infoRow("Mode", modes.audio.rawValue))
            for (index, stream) in audioStreams.enumerated() {
                let title = stream.displayTitle ?? stream.extendedDisplayTitle ?? "Track \(index + 1)"
                var detail = title
                if let bitrate = stream.bitrate {
                    detail += " · \(PlayerInfoSheetStyle.bitrate(bitrate))"
                }
                if let sampleRate = stream.samplingRate {
                    detail += " · \(sampleRate / 1000) kHz"
                }
                stack.addArrangedSubview(PlayerInfoSheetStyle.bodyLabel(detail, secondary: false))
            }
        }

        if !subtitleStreams.isEmpty {
            stack.addArrangedSubview(PlayerInfoSheetStyle.sectionLabel("SUBTITLES"))
            stack.addArrangedSubview(PlayerInfoSheetStyle.infoRow("Mode", modes.subtitles.rawValue))
            for stream in subtitleStreams {
                var title = stream.extendedDisplayTitle ?? stream.displayTitle ?? "Unknown"
                var badges: [String] = []
                if stream.forced == true { badges.append("Forced") }
                if stream.hearingImpaired == true { badges.append("SDH") }
                if stream.default == true { badges.append("Default") }
                if !badges.isEmpty {
                    title += " (\(badges.joined(separator: ", ")))"
                }
                stack.addArrangedSubview(PlayerInfoSheetStyle.bodyLabel(title, secondary: false))
            }
        }

        if let part = metadata.Media?.first?.Part?.first {
            stack.addArrangedSubview(PlayerInfoSheetStyle.sectionLabel("FILE"))
            if let file = part.file {
                let filename = (file as NSString).lastPathComponent
                stack.addArrangedSubview(PlayerInfoSheetStyle.infoRow("Name", filename))
            }
            if let container = part.container ?? metadata.Media?.first?.container {
                stack.addArrangedSubview(PlayerInfoSheetStyle.infoRow("Container", container.uppercased()))
            }
            if let size = part.size {
                stack.addArrangedSubview(PlayerInfoSheetStyle.infoRow("Size", PlayerInfoSheetStyle.fileSize(Int64(size))))
            }
            if let duration = metadata.duration ?? part.duration {
                stack.addArrangedSubview(PlayerInfoSheetStyle.infoRow("Duration", PlayerInfoSheetStyle.duration(duration)))
            }
        }
    }
}
