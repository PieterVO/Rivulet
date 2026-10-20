// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  FolderRowCell.swift
//  Rivulet
//
//  One folder-page row: a name and a trailing detail, in the Music album
//  row's metrics (pitch 90, 31pt title, 29pt detail, glass platter on focus).
//

import UIKit

@MainActor
final class FolderRowCell: UICollectionViewCell {
    static let height: CGFloat = 90
    static let platterOutset = MusicTrackRowCell.platterOutset

    private let platter = MusicFocusPlatterView()
    private let title = MusicChrome.label(size: 31, weight: .semibold)
    private let detail = MusicChrome.label(size: 29, weight: .regular)
    private var showsFocus = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = false
        contentView.clipsToBounds = false
        detail.textAlignment = .right
        [platter, title, detail].forEach(contentView.addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title text: String, detail detailText: String) {
        title.text = text
        detail.text = detailText
        applyColors()
        setNeedsLayout()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        showsFocus = false
        platter.alpha = 0
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let bounds = contentView.bounds
        let outset = Self.platterOutset
        platter.frame = CGRect(x: -outset, y: 4, width: bounds.width + outset * 2, height: bounds.height - 8)
        detail.sizeToFit()
        detail.frame = CGRect(x: bounds.width - detail.bounds.width, y: 0,
                              width: detail.bounds.width, height: bounds.height)
        title.frame = CGRect(x: 0, y: 0, width: max(0, detail.frame.minX - 24), height: bounds.height)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        coordinator.animateFocusChange(gained: focused) {
            self.showsFocus = focused
            self.platter.alpha = focused ? 1 : 0
            self.applyColors()
        }
    }

    // The album row's colours: white title, detail at 40% until focused.
    private func applyColors() {
        title.textColor = .white
        detail.textColor = UIColor(white: 1, alpha: showsFocus ? 1 : 0.4)
    }
}
