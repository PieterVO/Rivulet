// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Hero-sized placeholder while the hero resolves. Holds the slot so rows never shift, and takes
// launch focus so the viewport does not scroll to the first shelf and back.

import UIKit

@MainActor
final class HeroLoadingCell: UICollectionViewCell {
    static let reuseID = "HeroLoadingCell"

    private let spinner = UIActivityIndicatorView(style: .large)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        spinner.color = .white.withAlphaComponent(0.35)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // Quiet focus parking spot — no visible focus treatment, no actions.
    override var canBecomeFocused: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { spinner.startAnimating() } else { spinner.stopAnimating() }
    }
}
