//
//  PlayerInfoPopupView.swift
//  Rivulet
//
//  Media info popup for the transport bar's Info pill. Ports
//  VideoInfoOverlay's content sections (Video/Audio/Subtitle/File) to
//  UIKit, reusing the same PlexStream/PlexMedia/PlexPart field reads.
//

import UIKit

final class PlayerInfoPopupView: UIView, AnchoredPopupPresenting {

    private let metadata: PlexMetadata
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let backgroundEffectView: UIVisualEffectView

    var onDismiss: (() -> Void)?

    init(metadata: PlexMetadata) {
        self.metadata = metadata

        if #available(tvOS 26.0, *) {
            backgroundEffectView = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        } else {
            backgroundEffectView = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
        }
        super.init(frame: .zero)
        setupViews()
        populate()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        backgroundEffectView.layer.cornerRadius = 20
        backgroundEffectView.layer.cornerCurve = .continuous
        backgroundEffectView.clipsToBounds = true
        addSubview(backgroundEffectView)

        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .leading
        scrollView.addSubview(stack)
        addSubview(scrollView)

        [backgroundEffectView, scrollView, stack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            backgroundEffectView.topAnchor.constraint(equalTo: topAnchor),
            backgroundEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            backgroundEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
            backgroundEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),

            stack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),

            heightAnchor.constraint(lessThanOrEqualToConstant: 500),
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

    // MARK: - Row builders

    private func headerLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 28, weight: .bold)
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

    // MARK: - Presentation

    func present(in container: UIView, anchoredTo anchor: UIView) {
        presentAnchored(in: container, anchoredTo: anchor, width: 480)
    }

    func dismiss() {
        dismissAnchored()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses where press.type == .menu {
            dismiss()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}
