//
//  HeroLoadingCell.swift
//  Rivulet
//
//  Hero-sized placeholder vended while the trending hero resolves. Holds
//  the hero slot at full height so rows below never shift when content
//  lands, and quietly accepts focus so launch focus parks on the hero area
//  instead of dropping to the first shelf (which would scroll the viewport
//  down, then yank back up when the hero arrives).
//

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
