// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

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

    /// One persistent focusable shell per `SectionSpec`, in declaration
    /// order. Rebuilds swap each shell's CONTENT and toggle its visibility,
    /// never the shells themselves — a shell is the focus target, and tearing
    /// it down mid-tick would yank focus out of the sheet.
    private var sectionViews: [InfoSectionView] = []
    private lazy var gatheringLabel = PlayerInfoSheetStyle.bodyLabel("Gathering stats…", secondary: true)

    private var liveTickTimer: Timer?
    private var isActiveTab = false

    /// Value labels keyed by row title, so a same-shape tick updates text in
    /// place instead of rebuilding (keeps focus/scroll undisturbed).
    private var valueLabels: [String: UILabel] = [:]
    /// The set of row titles currently rendered. When the next tick's present
    /// set differs (a field appeared/disappeared, or the empty→populated
    /// transition), the section contents are rebuilt; otherwise values update
    /// in place.
    private var renderedSignature: Set<String> = []
    /// Distinct from an empty signature so the "Gathering stats…" placeholder
    /// and a genuinely-empty row set don't collide.
    private var renderedGathering = false

    var onFocusChange: ((Bool) -> Void)? {
        didSet { scrollView.onFocusChange = onFocusChange }
    }

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
        // .fill so the two-column section grids stretch to the full sheet
        // width and their columns split it evenly (matches CardInfoView).
        stack.alignment = .fill
        scrollView.addSubview(stack)
        addSubview(scrollView)

        [scrollView, stack].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }

        gatheringLabel.isHidden = true
        stack.addArrangedSubview(gatheringLabel)
        for _ in Self.sections {
            let shell = InfoSectionView()
            shell.isHidden = true
            stack.addArrangedSubview(shell)
            sectionViews.append(shell)
        }

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
        // Scheduled in `.common` modes rather than through
        // `Timer.scheduledTimer`, which installs the timer in `.default` only.
        // This sheet scrolls, and while a scroll is tracking the main runloop
        // leaves `.default`, so a default-mode timer stops firing for the
        // duration. The rows stay on screen holding whatever values they last
        // received, which reads exactly like the engine has stopped reporting
        // telemetry when in fact nothing is asking it for a new snapshot.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        liveTickTimer = timer
    }

    private func stopLiveTick() {
        liveTickTimer?.invalidate()
        liveTickTimer = nil
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
        valueLabels.removeAll()

        if stats.isEmpty {
            gatheringLabel.isHidden = false
            sectionViews.forEach {
                $0.isHidden = true
                $0.setContent([])
            }
            renderedGathering = true
            renderedSignature = []
            return
        }

        gatheringLabel.isHidden = true
        for (index, section) in Self.sections.enumerated() {
            let shell = sectionViews[index]
            let visibleRows = section.rows.compactMap { row -> (String, String)? in
                guard let value = row.value(stats) else { return nil }
                return (row.title, value)
            }
            guard !visibleRows.isEmpty else {
                shell.isHidden = true
                shell.setContent([])
                continue
            }
            var rowViews: [UIView] = []
            for (title, value) in visibleRows {
                let row = PlayerInfoSheetStyle.infoRow(title, value)
                rowViews.append(row)
                valueLabels[title] = row
            }
            shell.setContent([
                PlayerInfoSheetStyle.sectionLabel(section.name),
                PlayerInfoSheetStyle.twoColumnGrid(rowViews),
            ])
            shell.isHidden = false
        }

        renderedGathering = false
        renderedSignature = Set(valueLabels.keys)
    }
}
