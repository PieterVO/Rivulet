//
//  CardStatsView.swift
//  Rivulet
//
//  The Advanced tab of the player's Now Playing popup — AetherEngine's live
//  "stats for nerds" telemetry. Built lazily by `PlayerInfoTabsView` on the
//  first tab-over and ticked 1 Hz only while it is the visible tab. Reads an
//  app-side `AetherAdvancedStats` snapshot on each tick (a pure engine read;
//  the telemetry is already sampled by the engine). Rows self-prune when
//  their source field is nil — the engine's nils are path-asymmetric — so a
//  software-decode session and a native session show different subsets.
//
//  Shares `InfoScrollView` and `PlayerInfoSheetStyle` with the Info tab so the
//  two sheets are visually identical by construction.
//

import UIKit

final class CardStatsView: UIView {

    private let provider: () -> AetherAdvancedStats?
    private let scrollView = InfoScrollView()
    private let stack = UIStackView()

    private var liveTickTimer: Timer?
    private var isActiveTab = false

    /// Value labels keyed by row title, so a same-shape tick updates text in
    /// place instead of rebuilding (keeps focus/scroll undisturbed).
    private var valueLabels: [String: UILabel] = [:]
    /// The set of row titles currently rendered. When the next tick's present
    /// set differs (a field appeared/disappeared, or the empty→populated
    /// transition), the stack is rebuilt; otherwise values update in place.
    private var renderedSignature: Set<String> = []
    /// Distinct from an empty signature so the "Gathering stats…" placeholder
    /// and a genuinely-empty row set don't collide.
    private var renderedGathering = false

    var onFocusChange: ((Bool) -> Void)? {
        didSet { scrollView.onFocusChange = onFocusChange }
    }

    var onEscapeUp: (() -> Void)? {
        didSet { scrollView.onEscapeUp = onEscapeUp }
    }

    /// Fires `true` when the sheet starts ticking (Advanced is the visible tab
    /// AND attached to a window) and `false` when it stops — the exact window
    /// during which the engine's telemetry gate should be open. The host wires
    /// this to `AetherPlayer.setAdvancedStatsObserving(_:)`.
    var onActiveChange: ((Bool) -> Void)?

    init(provider: @escaping () -> AetherAdvancedStats?) {
        self.provider = provider
        super.init(frame: .zero)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        liveTickTimer?.invalidate()
    }

    // MARK: - Row model

    private struct RowSpec {
        let title: String
        let value: (AetherAdvancedStats) -> String?
    }
    private struct SectionSpec {
        let name: String
        let rows: [RowSpec]
    }

    private static let sections: [SectionSpec] = [
        SectionSpec(name: "DECODE", rows: [
            RowSpec(title: "Backend", value: { $0.backend }),
            RowSpec(title: "Audio Bridge", value: { $0.audioBridge }),
        ]),
        SectionSpec(name: "STREAM", rows: [
            RowSpec(title: "Bitrate", value: { $0.instantBitrateMbps.map(PlayerInfoSheetStyle.mbps) }),
            RowSpec(title: "Avg Bitrate", value: { $0.averageBitrateMbps.map(PlayerInfoSheetStyle.mbps) }),
            RowSpec(title: "Frame Rate", value: { $0.observedFps.map(PlayerInfoSheetStyle.fps) }),
            RowSpec(title: "Dropped Frames", value: { $0.droppedFrameCount.map { "\($0)" } }),
            RowSpec(title: "Audio Bitrate", value: { $0.audioBridgeBitrateMbps.map(PlayerInfoSheetStyle.mbps) }),
        ]),
        SectionSpec(name: "BUFFER / NETWORK", rows: [
            RowSpec(title: "Buffer", value: { $0.forwardBufferSeconds.map(PlayerInfoSheetStyle.bufferSeconds) }),
            RowSpec(title: "Cached", value: { $0.cachedBytes.map(PlayerInfoSheetStyle.fileSize) }),
            RowSpec(title: "Throughput", value: { $0.networkThroughputMbps.map(PlayerInfoSheetStyle.mbps) }),
            RowSpec(title: "Transferred", value: { $0.networkTransferredBytes.map(PlayerInfoSheetStyle.fileSize) }),
            RowSpec(title: "A/V Sync", value: { $0.avSyncGapMs.map(PlayerInfoSheetStyle.milliseconds) }),
        ]),
        SectionSpec(name: "ENGINE", rows: [
            RowSpec(title: "Producer Restarts", value: { $0.producerRestartCount.map { "\($0)" } }),
            RowSpec(title: "Muxed", value: { $0.muxedBytesLifetime.map(PlayerInfoSheetStyle.fileSize) }),
            RowSpec(title: "Server Sent", value: { $0.serverBytesSentLifetime.map(PlayerInfoSheetStyle.fileSize) }),
            RowSpec(title: "Server Requests", value: { $0.serverRequestCount.map { "\($0)" } }),
            RowSpec(title: "Demuxer Fetched", value: { $0.demuxerBytesFetched.map(PlayerInfoSheetStyle.fileSize) }),
            RowSpec(title: "Audio Bridge Bytes", value: { $0.audioBridgeLiveBytes.map { PlayerInfoSheetStyle.fileSize(Int64($0)) } }),
            RowSpec(title: "Memory", value: { $0.rssMb.map { "\($0) MB" } }),
        ]),
    ]

    // MARK: - Layout

    private func setupViews() {
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .leading
        scrollView.addSubview(stack)
        addSubview(scrollView)

        [scrollView, stack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

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

    // MARK: - Active-tab lifecycle
    //
    // The container calls setActive(true) when Advanced becomes the visible
    // tab and setActive(false) when it leaves. The 1 Hz tick runs only while
    // active AND attached to a window, so a hidden or torn-down sheet never
    // ticks.

    func setActive(_ active: Bool) {
        isActiveTab = active
        if active {
            rebuild()
            startLiveTick()
        } else {
            stopLiveTick()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stopLiveTick()
        } else if isActiveTab {
            rebuild()
            startLiveTick()
        }
    }

    private func startLiveTick() {
        guard isActiveTab, window != nil, liveTickTimer == nil else { return }
        // The timer fires on the main runloop, so hop straight to the main
        // actor rather than spawning a Task (avoids capturing self across a
        // Sendable boundary).
        liveTickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        // Transitioned into ticking → open the telemetry gate.
        onActiveChange?(true)
    }

    private func stopLiveTick() {
        // Only a real timer→no-timer transition closes the gate, so repeated
        // stops (deactivate + window-detach) don't fire spurious closes.
        guard liveTickTimer != nil else { return }
        liveTickTimer?.invalidate()
        liveTickTimer = nil
        onActiveChange?(false)
    }

    // MARK: - Rendering

    private func snapshot() -> AetherAdvancedStats {
        provider() ?? AetherAdvancedStats()
    }

    /// Present row titles for a snapshot, in section/row declaration order.
    private func presentTitles(for stats: AetherAdvancedStats) -> [String] {
        Self.sections.flatMap { section in
            section.rows.compactMap { row in row.value(stats) == nil ? nil : row.title }
        }
    }

    private func refresh() {
        let stats = snapshot()
        let titles = presentTitles(for: stats)
        let gathering = stats.isEmpty
        if gathering != renderedGathering || Set(titles) != renderedSignature {
            rebuild(with: stats)
        } else {
            for (title, label) in valueLabels {
                if let value = Self.value(for: title, stats: stats) {
                    label.attributedText = PlayerInfoSheetStyle.infoRowText(title, value)
                }
            }
        }
    }

    private static func value(for title: String, stats: AetherAdvancedStats) -> String? {
        for section in sections {
            for row in section.rows where row.title == title {
                return row.value(stats)
            }
        }
        return nil
    }

    private func rebuild() {
        rebuild(with: snapshot())
    }

    private func rebuild(with stats: AetherAdvancedStats) {
        stack.arrangedSubviews.forEach {
            stack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        valueLabels.removeAll()

        if stats.isEmpty {
            stack.addArrangedSubview(PlayerInfoSheetStyle.bodyLabel("Gathering stats…", secondary: true))
            renderedGathering = true
            renderedSignature = []
            return
        }

        for section in Self.sections {
            let visibleRows = section.rows.compactMap { row -> (String, String)? in
                guard let value = row.value(stats) else { return nil }
                return (row.title, value)
            }
            guard !visibleRows.isEmpty else { continue }
            stack.addArrangedSubview(PlayerInfoSheetStyle.sectionLabel(section.name))
            for (title, value) in visibleRows {
                let row = PlayerInfoSheetStyle.infoRow(title, value)
                stack.addArrangedSubview(row)
                valueLabels[title] = row
            }
        }

        renderedGathering = false
        renderedSignature = Set(valueLabels.keys)
    }
}
