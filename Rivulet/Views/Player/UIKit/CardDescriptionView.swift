// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CardDescriptionView.swift
//  Rivulet
//
//  Description tab of the player's Now Playing Info popup (issue #267): the
//  item's title, a context line, and its summary, so the description stays
//  readable during playback. Sibling of `CardInfoView` (tech metadata) and
//  `CardStatsView` (live telemetry); shares their scroll surface and row
//  focus targets.
//
//  Each paragraph is its own `InfoFocusRowView`, full width rather than
//  two-up. A single paragraph taller than the panel has only one focus target,
//  so it scrolls from the clickpad edge clicks `InfoScrollView.pressesBegan`
//  handles, not from swipes — the same ceiling the other sheets have for an
//  over-tall row.
//
//  The title block stays pinned at the top; the summary is centered in
//  whatever height is left under it (see `setupViews`).
//

import UIKit

final class CardDescriptionView: UIView, InfoTabSheet {

    private enum Metrics {
        /// Minimum gap between the title block and the summary. Only binds when
        /// the summary is too tall to center.
        static let headerGap: CGFloat = 20
        /// Gap between summary paragraphs.
        static let paragraphSpacing: CGFloat = 12
    }

    private let scrollView = InfoScrollView()
    /// Sizes the scroll content; holds the pinned header and the summary.
    private let content = UIView()
    private let headerRow = InfoFocusRowView()
    private let summaryStack = UIStackView()
    /// The region the summary is centered in: header bottom → content bottom.
    private let summarySpace = UILayoutGuide()

    /// Fires when focus enters/leaves this sheet, so the hosting panel can
    /// brighten its ring (the sheet draws no focus treatment of its own).
    var onFocusChange: ((Bool) -> Void)? {
        didSet { scrollView.onFocusChange = onFocusChange }
    }

    var canEscapeUpward: Bool { scrollView.canEscapeUpward }

    init(metadata: PlexMetadata) {
        super.init(frame: .zero)
        setupViews()
        populate(metadata: metadata)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Title pinned at the top, summary centered in the height left under it.
    ///
    /// The centering is one breakable constraint, not a pair of spacer views:
    /// spacers inside a `.fill` stack do NOT split the slack evenly, whatever
    /// equal-height constraint they carry. The stack stretches the FIRST view
    /// with the lowest hugging priority and leaves the rest at zero, which put
    /// the summary flush against the bottom of the sheet (measured: 350pt above
    /// it, 12pt below).
    ///
    /// So: `summarySpace` spans header-bottom → content-bottom, the summary
    /// centers in it at `.defaultHigh`, and required inequalities keep it
    /// inside. A summary taller than the space makes those inequalities bind,
    /// the center breaks, and the sheet scrolls from its top as normal.
    private func setupViews() {
        summaryStack.axis = .vertical
        summaryStack.spacing = Metrics.paragraphSpacing
        summaryStack.alignment = .fill

        [scrollView, content, headerRow, summaryStack].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        content.addSubview(headerRow)
        content.addSubview(summaryStack)
        content.addLayoutGuide(summarySpace)
        scrollView.addSubview(content)
        addSubview(scrollView)

        // Beat the panel's own height cap so a short sheet hugs its content
        // instead of collapsing to zero height — same idiom as CardInfoView.
        let scrollHeight = scrollView.heightAnchor.constraint(equalTo: content.heightAnchor)
        scrollHeight.priority = .defaultHigh

        let centerSummary = summaryStack.centerYAnchor.constraint(equalTo: summarySpace.centerYAnchor)
        centerSummary.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollHeight,

            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            content.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            // At least a viewport tall, so short content has slack to center in.
            content.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.frameLayoutGuide.heightAnchor),

            headerRow.topAnchor.constraint(equalTo: content.topAnchor),
            headerRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            headerRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            summarySpace.topAnchor.constraint(equalTo: headerRow.bottomAnchor),
            summarySpace.bottomAnchor.constraint(equalTo: content.bottomAnchor),

            summaryStack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            summaryStack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            // The region starts AT the title, so centering it gives equal gaps
            // above and below. `headerGap` is only the floor, for the tall case
            // where the center breaks and the summary sits under the title.
            summaryStack.topAnchor.constraint(greaterThanOrEqualTo: summarySpace.topAnchor,
                                              constant: Metrics.headerGap),
            summaryStack.bottomAnchor.constraint(lessThanOrEqualTo: summarySpace.bottomAnchor),
            centerSummary,
        ])
    }

    private func populate(metadata: PlexMetadata) {
        let header = UIStackView()
        header.axis = .vertical
        header.spacing = 4
        header.alignment = .fill
        if let context = Self.contextLine(for: metadata) {
            header.addArrangedSubview(PlayerInfoSheetStyle.bodyLabel(context, secondary: true))
        }
        header.addArrangedSubview(PlayerInfoSheetStyle.titleLabel(metadata.title ?? "Now Playing"))
        headerRow.setFullWidth(header)

        for paragraph in Self.paragraphs(of: metadata.summary) {
            let row = InfoFocusRowView()
            row.setFullWidth(PlayerInfoSheetStyle.bodyLabel(paragraph, secondary: false))
            summaryStack.addArrangedSubview(row)
        }
    }

    // MARK: - Content (pure, unit-tested)

    /// Line above the title: the show and episode number for an episode, or
    /// year / rating / runtime for anything else. Nil when nothing is known.
    nonisolated static func contextLine(for metadata: PlexMetadata) -> String? {
        let parts: [String?]
        if metadata.type == "episode" {
            parts = [metadata.grandparentTitle, metadata.episodeString]
        } else {
            parts = [metadata.year.map(String.init), metadata.contentRating, metadata.durationFormatted]
        }
        let line = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }

    /// Summary split into paragraphs, blank lines dropped. One focus target per
    /// paragraph is what lets a swipe walk a long summary.
    nonisolated static func paragraphs(of summary: String?) -> [String] {
        (summary ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
