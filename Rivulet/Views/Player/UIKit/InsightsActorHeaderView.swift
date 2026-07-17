// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  InsightsActorHeaderView.swift
//  Rivulet
//
//  Compact actor header for the in-panel `.actor` state (Docs/superpowers/
//  plans/2026-07-07-insights-in-panel-actor.md). Deliberately NOT
//  `PersonHeaderCell`: that cell pins a FIXED 1151pt-wide centered
//  `headerContent` (215pt portrait + 36pt gap + 900pt text column) sized for
//  the full-screen Person page — inside the ~440pt panel content width it
//  spills ~350pt past each edge over the video. `PersonHeaderCell` is left
//  untouched for its real full-screen callers (PersonDetailViewController);
//  this is a small, purpose-built sidebar header that never renders wider
//  than the panel gives it.
//
//  FOCUSABLE, unlike `PersonHeaderCell` — on tvOS a non-focusable block in
//  a focus-driven scroll view is unreachable, and with the filmography rows
//  hidden until data loads there would otherwise be NOTHING focusable in the
//  actor state at all (focus would fall out to the hosting panel view). The
//  focus treatment is a quiet wash (no scale — read-only, like the trivia
//  rows). No MORE affordance / full-bio popup: the spec for this flow is
//  "no VC presentation," so the bio is just an unbounded multi-line label;
//  while the header is focused, Up/Down clicks step the panel's scroll
//  (see InsightsActorView.pressesBegan) to reveal a bio longer than fits.
//

import UIKit

final class InsightsActorHeaderView: UIView {

    private enum Metrics {
        /// Circular portrait — a sidebar avatar, not the 215pt full-page one.
        static let portraitSide: CGFloat = 112
        // Sized up for TV viewing distance (10-foot UI).
        static let nameFont = UIFont.systemFont(ofSize: 32, weight: .semibold)
        static let bioFont = UIFont.systemFont(ofSize: 25, weight: .regular)
    }

    private let portraitContainer = UIView()
    private let portraitImageView = UIImageView()
    private let fallbackIcon = UIImageView()
    private let nameLabel = UILabel()
    private let bioLabel = UILabel()
    private let loadingSpinner = UIActivityIndicatorView(style: .medium)

    private var imageToken: UInt64 = 0
    private var currentPortraitURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setUp() {
        clipsToBounds = false
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous

        portraitContainer.translatesAutoresizingMaskIntoConstraints = false
        portraitContainer.clipsToBounds = true
        portraitContainer.backgroundColor = UIColor(white: 0.15, alpha: 1)
        portraitContainer.layer.cornerRadius = Metrics.portraitSide / 2
        portraitContainer.layer.borderWidth = 1
        portraitContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor
        addSubview(portraitContainer)

        portraitImageView.translatesAutoresizingMaskIntoConstraints = false
        portraitImageView.contentMode = .scaleAspectFill
        portraitImageView.clipsToBounds = true
        portraitContainer.addSubview(portraitImageView)

        fallbackIcon.translatesAutoresizingMaskIntoConstraints = false
        fallbackIcon.image = UIImage(systemName: "person.fill")
        fallbackIcon.tintColor = UIColor.white.withAlphaComponent(0.3)
        fallbackIcon.contentMode = .center
        fallbackIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 30, weight: .light)
        portraitContainer.addSubview(fallbackIcon)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = Metrics.nameFont
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 2
        addSubview(nameLabel)

        bioLabel.translatesAutoresizingMaskIntoConstraints = false
        bioLabel.font = Metrics.bioFont
        bioLabel.textColor = UIColor.white.withAlphaComponent(0.75)
        // Unbounded — the panel scrolls (InsightsActorView's self-driven
        // vertical scroll) to reveal a bio longer than what fits on first
        // paint, rather than truncating it. Previously capped at a fixed 8
        // lines with no way to read the rest.
        bioLabel.numberOfLines = 0
        addSubview(bioLabel)

        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingSpinner.color = UIColor.white.withAlphaComponent(0.85)
        loadingSpinner.hidesWhenStopped = true
        addSubview(loadingSpinner)

        NSLayoutConstraint.activate([
            portraitContainer.topAnchor.constraint(equalTo: topAnchor),
            portraitContainer.centerXAnchor.constraint(equalTo: centerXAnchor),
            portraitContainer.widthAnchor.constraint(equalToConstant: Metrics.portraitSide),
            portraitContainer.heightAnchor.constraint(equalToConstant: Metrics.portraitSide),

            portraitImageView.topAnchor.constraint(equalTo: portraitContainer.topAnchor),
            portraitImageView.leadingAnchor.constraint(equalTo: portraitContainer.leadingAnchor),
            portraitImageView.trailingAnchor.constraint(equalTo: portraitContainer.trailingAnchor),
            portraitImageView.bottomAnchor.constraint(equalTo: portraitContainer.bottomAnchor),

            fallbackIcon.centerXAnchor.constraint(equalTo: portraitContainer.centerXAnchor),
            fallbackIcon.centerYAnchor.constraint(equalTo: portraitContainer.centerYAnchor),

            // Name + bio centered under the portrait, wrapping within the
            // FULL width this view is given (the panel content width) —
            // never a fixed wide column like PersonHeaderCell's.
            nameLabel.topAnchor.constraint(equalTo: portraitContainer.bottomAnchor, constant: 14),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor),

            bioLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 8),
            bioLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            bioLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            // A MINIMUM (not fixed) height: loading/empty/short-bio states
            // still get a stable, non-collapsed block (no first-paint jump),
            // but a longer bio is free to grow past it — the panel's own
            // vertical scroll (InsightsActorView) reveals the rest rather
            // than truncating it. Previously a fixed height hard-capped the
            // bio at 8 lines with no way to read further.
            bioLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.bioMinBlockHeight),
            bioLabel.bottomAnchor.constraint(equalTo: bottomAnchor),

            loadingSpinner.centerXAnchor.constraint(equalTo: bioLabel.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: bioLabel.centerYAnchor),
        ])
        nameLabel.textAlignment = .center
        bioLabel.textAlignment = .center
    }

    /// Minimum height of the bio block — enough for a short bio (or the
    /// loading spinner) to not look collapsed, without capping how far a
    /// long bio can grow.
    private static let bioMinBlockHeight: CGFloat = ceil(Metrics.bioFont.lineHeight * 3)

    // MARK: - Configure

    func configure(name: String, biography: String?, portraitURL: URL?, isLoading: Bool) {
        nameLabel.text = name

        let bio = (biography ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if isLoading {
            bioLabel.text = nil
            loadingSpinner.startAnimating()
        } else {
            loadingSpinner.stopAnimating()
            bioLabel.text = bio.isEmpty ? nil : bio
        }

        loadPortrait(url: portraitURL)
    }

    private func loadPortrait(url: URL?) {
        // Same URL already shown/loading → leave it; avoids a blank+refetch
        // flicker when the header re-renders after the bio loads.
        if url == currentPortraitURL, portraitImageView.image != nil { return }
        currentPortraitURL = url
        imageToken &+= 1
        let token = imageToken
        portraitImageView.image = nil
        fallbackIcon.isHidden = false
        guard let url else { return }
        Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url)
            await MainActor.run {
                guard let self, self.imageToken == token, let image else { return }
                self.portraitImageView.image = image
                self.fallbackIcon.isHidden = true
            }
        }
    }

    // MARK: - Focus

    // Focusable so the actor state always has a focus target (filmography
    // rows are hidden until data loads) and so Up/Down clicks can step the
    // bio scroll while it holds focus — see the header comment.
    override var canBecomeFocused: Bool { true }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let isFocused = context.nextFocusedView === self
        coordinator.addCoordinatedAnimations({
            self.backgroundColor = isFocused ? UIColor.white.withAlphaComponent(0.08) : .clear
        }, completion: nil)
    }
}
