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

import UIKit

final class CardDescriptionView: UIView {

    private let scrollView = InfoScrollView()
    private let stack = UIStackView()

    /// Fires when focus enters/leaves this sheet, so the hosting panel can
    /// brighten its ring (the sheet draws no focus treatment of its own).
    var onFocusChange: ((Bool) -> Void)? {
        didSet { scrollView.onFocusChange = onFocusChange }
    }

    init(metadata: PlexMetadata) {
        super.init(frame: .zero)
        setupViews()
        populate(metadata: metadata)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupViews() {
        stack.axis = .vertical
        stack.spacing = 12
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        addSubview(scrollView)

        // Beat the panel's own height cap so a short sheet hugs its content
        // instead of collapsing to zero height — same idiom as CardInfoView.
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

    private func populate(metadata: PlexMetadata) {
        let header = UIStackView()
        header.axis = .vertical
        header.spacing = 4
        header.alignment = .fill
        if let context = Self.contextLine(for: metadata) {
            header.addArrangedSubview(PlayerInfoSheetStyle.bodyLabel(context, secondary: true))
        }
        header.addArrangedSubview(PlayerInfoSheetStyle.titleLabel(metadata.title ?? "Now Playing"))
        addRow(header)

        for paragraph in Self.paragraphs(of: metadata.summary) {
            addRow(PlayerInfoSheetStyle.bodyLabel(paragraph, secondary: false))
        }
    }

    private func addRow(_ content: UIView) {
        let row = InfoFocusRowView()
        row.setFullWidth(content)
        stack.addArrangedSubview(row)
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
