// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerInfoSheetStyle.swift
//  Rivulet
//
//  Shared row/section builders and value formatters for the player's info
//  sheets. Both the Info tab (`CardInfoView`, static metadata) and the
//  Advanced tab (`CardStatsView`, live telemetry) build their rows through
//  this one namespace so the two sheets are visually identical by
//  construction rather than by coincidence (cohesive-styling requirement).
//
//  Builders touch UIKit and are `@MainActor`; formatters are pure and
//  `nonisolated` so they are unit-testable off the main actor.
//

import UIKit

enum PlayerInfoSheetStyle {

    /// No info-sheet label may be squeezed vertically. Every sheet hugs its
    /// content at `.defaultHigh` so the panel sizes to it, and a label's own
    /// vertical compression resistance defaults to the SAME priority — a tie
    /// Auto Layout is free to settle by shortening the text instead of growing
    /// the scroll content. Measured: a 12-paragraph summary in a 448pt sheet
    /// reported `contentSize.height == 448`, so it was clipped with nothing to
    /// scroll rather than overflowing. Required resistance breaks the tie the
    /// only way that can be right.
    @MainActor
    private static func resistVerticalSqueeze(_ label: UILabel) {
        label.setContentCompressionResistancePriority(.required, for: .vertical)
    }

    // MARK: - Row builders

    /// Section heading: the title, then a hairline rule running out to the
    /// sheet's trailing edge so the sections read apart at a glance.
    @MainActor
    static func sectionLabel(_ text: String) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 15, weight: .bold)
        label.textColor = UIColor.white.withAlphaComponent(0.5)
        // Explicit, so the stack stretches the rule and not the title. Both
        // default to 250 horizontally, and `.fill` then stretches whichever
        // comes first — which would be the label.
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let rule = UIView()
        rule.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        rule.heightAnchor.constraint(equalToConstant: 2).isActive = true

        let heading = UIStackView(arrangedSubviews: [label, rule])
        heading.axis = .horizontal
        heading.alignment = .center
        heading.spacing = 12
        return heading
    }

    /// Item title, used by the Description tab. Bigger than a body row because
    /// it is that sheet's heading, not one of its values.
    @MainActor
    static func titleLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 28, weight: .semibold)
        label.textColor = .white
        label.numberOfLines = 0
        resistVerticalSqueeze(label)
        return label
    }

    @MainActor
    static func bodyLabel(_ text: String, secondary: Bool) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 20, weight: .regular)
        label.textColor = secondary ? UIColor.white.withAlphaComponent(0.6) : .white
        label.numberOfLines = 0
        resistVerticalSqueeze(label)
        return label
    }

    @MainActor
    static func infoRow(_ label: String, _ value: String) -> UILabel {
        let row = UILabel()
        row.numberOfLines = 0
        row.attributedText = infoRowText(label, value)
        resistVerticalSqueeze(row)
        return row
    }

    /// The "Label: value" attributed string used by every info row. Exposed so
    /// live sheets (Advanced tab) can refresh a row's value in place each tick
    /// with identical styling instead of rebuilding the label.
    ///
    /// The value is set in MONOSPACED DIGITS. On the Advanced tab these values
    /// are rewritten every second, and in the proportional system font each
    /// digit has its own width, so a counter ticking 1 → 8 → 11 visibly
    /// reflows the text after it. Same face, same weight, fixed digit advance.
    @MainActor
    static func infoRowText(_ label: String, _ value: String) -> NSAttributedString {
        let text = NSMutableAttributedString(
            string: "\(label): ",
            attributes: [.font: UIFont.systemFont(ofSize: 17, weight: .medium), .foregroundColor: UIColor.white.withAlphaComponent(0.6)]
        )
        text.append(NSAttributedString(
            string: value,
            attributes: [.font: UIFont.monospacedDigitSystemFont(ofSize: 20, weight: .regular), .foregroundColor: UIColor.white]
        ))
        return text
    }

    // MARK: - Layout

    /// An empty vertical grid container, ready for `InfoFocusRowView`s. Shared
    /// so both sheets space their rows identically.
    @MainActor
    static func gridContainer() -> UIStackView {
        let grid = UIStackView()
        grid.axis = .vertical
        grid.spacing = 8
        grid.alignment = .fill
        return grid
    }

    /// Lays a flat row list into a two-column grid: a vertical stack of
    /// `InfoFocusRowView`s, each holding two half-width columns. An odd final
    /// row pairs with an empty spacer so it stays a half-width left column.
    ///
    /// Each pair row is a FOCUS TARGET (see `InfoFocusRowView`) — that
    /// granularity is what lets swipes walk the sheet. Static sheets use this;
    /// the live Advanced sheet builds its own persistent pool of the same rows
    /// so focus survives a tick (see `CardStatsView`).
    @MainActor
    static func twoColumnGrid(_ rows: [UIView]) -> UIView {
        let grid = gridContainer()
        var index = 0
        while index < rows.count {
            let row = InfoFocusRowView()
            // Plain two-up line. The SECTION carries focus (see addSection);
            // a focusable line inside a focusable section would nest two
            // targets and the inner one would be unreachable.
            row.isFocusEnabled = false
            row.setPair(rows[index], index + 1 < rows.count ? rows[index + 1] : nil)
            grid.addArrangedSubview(row)
            index += 2
        }
        return grid
    }

    // MARK: - Formatting

    /// Whole seconds, clamped to never print negative.
    nonisolated static func bufferSeconds(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        return "\(whole)s"
    }

    nonisolated static func bitrate(_ bitrate: Int) -> String {
        if bitrate >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bitrate) / 1_000_000.0)
        } else if bitrate >= 1000 {
            return String(format: "%.0f kbps", Double(bitrate) / 1000.0)
        } else {
            return "\(bitrate) bps"
        }
    }

    nonisolated static func fileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    nonisolated static func duration(_ milliseconds: Int) -> String {
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

    // MARK: - Advanced-tab formatters

    /// Megabits per second, one decimal, e.g. "12.3 Mbps".
    nonisolated static func mbps(_ value: Double) -> String {
        String(format: "%.1f Mbps", value)
    }

    /// Frames per second, whole number, e.g. "60 fps".
    nonisolated static func fps(_ value: Double) -> String {
        String(format: "%.0f fps", value)
    }

    /// Signed milliseconds, whole number, e.g. "+4 ms" / "-8 ms". A/V sync
    /// gap is a signed offset, so the sign carries meaning (lead vs. lag).
    nonisolated static func milliseconds(_ value: Double) -> String {
        String(format: "%+.0f ms", value)
    }
}
