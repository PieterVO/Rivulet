//
//  PersonHeaderCell.swift
//  Rivulet
//
//  The biography header for the person detail page (Docs/atv_ref/
//  actor_details_ref.JPG): a true-circle portrait on the LEFT, the person's
//  name (large semibold white) + a muted, truncated biography on the RIGHT,
//  with an uppercase MORE affordance under the bio when it overflows.
//
//  The cell itself is non-focusable; only the MORE button (a reused
//  FocusableActionButton, so Select handling matches the rest of the detail
//  chrome) is a focus target — matching the reference, where MORE is the
//  header's only affordance. The portrait loads via ImageCacheManager the same
//  way CastCell does. Background is clear so the controller's blue→black
//  gradient shows through.
//

import UIKit

final class PersonHeaderCell: UICollectionViewCell {

    static let reuseID = "PersonHeaderCell"

    /// Portrait diameter — sized like a header avatar (ref: ~175–215 px), not a
    /// cast-row thumbnail.
    private static let portraitSize: CGFloat = 200
    /// Bio is truncated to this many lines; MORE appears only when it overflows.
    private static let bioLineLimit = 4

    private let portraitContainer = UIView()
    private let portraitImageView = UIImageView()
    private let fallbackIcon = UIImageView()
    private let nameLabel = UILabel()
    private let bioLabel = UILabel()
    private let moreButton = FocusableActionButton()
    private let moreLabel = UILabel()

    private var imageToken: UInt64 = 0
    private var onMore: (() -> Void)?
    /// Full (untruncated) biography, used to decide whether MORE is needed.
    private var fullBiography: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("PersonHeaderCell is not Storyboard-backed") }

    private func setUp() {
        contentView.clipsToBounds = false
        clipsToBounds = false
        backgroundColor = .clear   // VC paints the gradient behind the cell

        // True circle: cornerRadius = side/2, clip the image to it.
        portraitContainer.translatesAutoresizingMaskIntoConstraints = false
        portraitContainer.clipsToBounds = true
        portraitContainer.backgroundColor = UIColor(white: 0.15, alpha: 1)
        portraitContainer.layer.cornerRadius = Self.portraitSize / 2
        portraitContainer.layer.borderWidth = 1
        portraitContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor
        contentView.addSubview(portraitContainer)

        portraitImageView.translatesAutoresizingMaskIntoConstraints = false
        portraitImageView.contentMode = .scaleAspectFill
        portraitImageView.clipsToBounds = true
        portraitContainer.addSubview(portraitImageView)

        fallbackIcon.translatesAutoresizingMaskIntoConstraints = false
        fallbackIcon.image = UIImage(systemName: "person.fill")
        fallbackIcon.tintColor = UIColor.white.withAlphaComponent(0.3)
        fallbackIcon.contentMode = .center
        fallbackIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 64, weight: .light)
        portraitContainer.addSubview(fallbackIcon)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 48, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 1
        contentView.addSubview(nameLabel)

        bioLabel.translatesAutoresizingMaskIntoConstraints = false
        bioLabel.font = .systemFont(ofSize: 24, weight: .regular)
        bioLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        bioLabel.numberOfLines = Self.bioLineLimit
        bioLabel.lineBreakMode = .byTruncatingTail
        contentView.addSubview(bioLabel)

        // MORE: a reused FocusableActionButton (proven, debounced Select +
        // focus appearance) wrapping a small uppercase label that inverts on focus.
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.layer.cornerRadius = 8
        moreButton.isHidden = true
        moreButton.onPrimaryAction = { [weak self] in self?.onMore?() }
        moreLabel.translatesAutoresizingMaskIntoConstraints = false
        moreLabel.text = "MORE"
        moreLabel.font = .systemFont(ofSize: 19, weight: .semibold)
        moreLabel.textColor = .white
        moreButton.addSubview(moreLabel)
        moreButton.invertOnFocus = [moreLabel]
        contentView.addSubview(moreButton)

        NSLayoutConstraint.activate([
            portraitContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            portraitContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            portraitContainer.widthAnchor.constraint(equalToConstant: Self.portraitSize),
            portraitContainer.heightAnchor.constraint(equalToConstant: Self.portraitSize),
            portraitContainer.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),

            portraitImageView.topAnchor.constraint(equalTo: portraitContainer.topAnchor),
            portraitImageView.leadingAnchor.constraint(equalTo: portraitContainer.leadingAnchor),
            portraitImageView.trailingAnchor.constraint(equalTo: portraitContainer.trailingAnchor),
            portraitImageView.bottomAnchor.constraint(equalTo: portraitContainer.bottomAnchor),

            fallbackIcon.centerXAnchor.constraint(equalTo: portraitContainer.centerXAnchor),
            fallbackIcon.centerYAnchor.constraint(equalTo: portraitContainer.centerYAnchor),

            // Name + bio block to the RIGHT of the portrait.
            nameLabel.topAnchor.constraint(equalTo: portraitContainer.topAnchor, constant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: portraitContainer.trailingAnchor, constant: 36),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            bioLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 16),
            bioLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            bioLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            bioLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),

            // MORE just under the truncated bio, leading-aligned with it.
            moreButton.topAnchor.constraint(equalTo: bioLabel.bottomAnchor, constant: 12),
            moreButton.leadingAnchor.constraint(equalTo: bioLabel.leadingAnchor),
            moreButton.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),

            moreLabel.topAnchor.constraint(equalTo: moreButton.topAnchor, constant: 8),
            moreLabel.bottomAnchor.constraint(equalTo: moreButton.bottomAnchor, constant: -8),
            moreLabel.leadingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: 16),
            moreLabel.trailingAnchor.constraint(equalTo: moreButton.trailingAnchor, constant: -16),
        ])
    }

    // MARK: - Configure

    func configure(name: String, biography: String?, portraitURL: URL?, onMore: @escaping () -> Void) {
        self.onMore = onMore
        self.fullBiography = biography

        nameLabel.text = name

        let bio = biography ?? ""
        bioLabel.text = bio
        bioLabel.isHidden = bio.isEmpty
        // Truncation (and thus MORE visibility) can only be measured after the
        // bio label has a real width — defer to layoutSubviews.
        moreButton.isHidden = true
        setNeedsLayout()

        loadPortrait(url: portraitURL)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateMoreVisibility()
    }

    /// Show MORE only when the full biography doesn't fit in the line-limited
    /// label. Measured by comparing the unbounded text height against the
    /// height the capped label actually occupies.
    private func updateMoreVisibility() {
        guard let bio = fullBiography, !bio.isEmpty, bioLabel.bounds.width > 1 else {
            if !moreButton.isHidden { moreButton.isHidden = true }
            return
        }
        let width = bioLabel.bounds.width
        let attrs: [NSAttributedString.Key: Any] = [.font: bioLabel.font as Any]
        let fullHeight = (bio as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs,
            context: nil
        ).height
        let lineHeight = bioLabel.font.lineHeight
        let cappedHeight = lineHeight * CGFloat(Self.bioLineLimit)
        let truncated = fullHeight > cappedHeight + 1
        if moreButton.isHidden == truncated {
            moreButton.isHidden = !truncated
        }
    }

    private func loadPortrait(url: URL?) {
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

    override func prepareForReuse() {
        super.prepareForReuse()
        imageToken &+= 1
        portraitImageView.image = nil
        fallbackIcon.isHidden = false
        nameLabel.text = nil
        bioLabel.text = nil
        fullBiography = nil
        moreButton.isHidden = true
        onMore = nil
    }
}
