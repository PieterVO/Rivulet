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
//  Non-focusable, like `PersonHeaderCell` — focus falls straight through to
//  the filmography rows below. No MORE affordance / full-bio popup: the
//  spec for this flow is "no VC presentation," so the bio is just a
//  multi-line label; the panel itself already scrolls vertically.
//

import UIKit

final class InsightsActorHeaderView: UIView {

    private enum Metrics {
        /// Circular portrait — a sidebar avatar, not the 215pt full-page one.
        static let portraitSide: CGFloat = 96
        static let nameFont = UIFont.systemFont(ofSize: 24, weight: .semibold)
        static let bioFont = UIFont.systemFont(ofSize: 17, weight: .regular)
        static let bioLineLimit = 4
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
        bioLabel.numberOfLines = Metrics.bioLineLimit
        bioLabel.lineBreakMode = .byTruncatingTail
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
            // Fixed line-limit height so the header is its FINAL size from
            // first paint (loading or a short bio won't shrink/grow it —
            // same rationale as PersonHeaderCell's bioBlockHeight).
            bioLabel.heightAnchor.constraint(equalToConstant: Self.bioBlockHeight),
            bioLabel.bottomAnchor.constraint(equalTo: bottomAnchor),

            loadingSpinner.centerXAnchor.constraint(equalTo: bioLabel.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: bioLabel.centerYAnchor),
        ])
        nameLabel.textAlignment = .center
        bioLabel.textAlignment = .center
    }

    /// Fixed height of the line-limited bio block — keeps the header a
    /// constant size whether loading, empty, or showing a bio.
    private static let bioBlockHeight: CGFloat =
        ceil(Metrics.bioFont.lineHeight * CGFloat(Metrics.bioLineLimit))

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

    // Plain content view: never a focus target itself, matching
    // PersonHeaderCell — focus falls through to the filmography rows.
    override var canBecomeFocused: Bool { false }
}
