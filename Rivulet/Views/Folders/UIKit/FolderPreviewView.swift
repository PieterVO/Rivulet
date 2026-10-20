// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  FolderPreviewView.swift
//  Rivulet
//
//  The folder page's left column: the focused row's still, title and facts.
//  Holds no focus.
//

import UIKit

@MainActor
final class FolderPreviewView: UIView {
    struct Content: Equatable {
        var still: URL?
        var glyph = "folder"
        var title: String
        var lines: [String] = []
        var progress: Double?
        var path: String?
    }

    static let width: CGFloat = 800
    private static let stillHeight = width * 9 / 16

    private let still = UIImageView()
    private let progressTrack = UIView()
    private let progressFill = UIView()
    private let title = MusicChrome.label(size: 38, weight: .bold, lines: 2)
    private let lines = MusicChrome.label(size: 29, weight: .regular, color: UIColor(white: 1, alpha: 0.6), lines: 3)
    private let path = MusicChrome.label(size: 25, weight: .regular, color: UIColor(white: 1, alpha: 0.4), lines: 3)
    private(set) var content: Content?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        still.contentMode = .scaleAspectFill
        still.clipsToBounds = true
        still.layer.cornerRadius = 30
        still.layer.cornerCurve = .continuous
        progressTrack.backgroundColor = UIColor(white: 1, alpha: 0.25)
        progressTrack.layer.cornerRadius = 3
        progressTrack.clipsToBounds = true
        progressFill.backgroundColor = .white
        progressTrack.addSubview(progressFill)
        path.lineBreakMode = .byCharWrapping
        [still, progressTrack, title, lines, path].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Sets everything at once; `image` nil shows the glyph tile.
    func show(_ content: Content, image: UIImage?) {
        self.content = content
        title.text = content.title
        lines.text = content.lines.joined(separator: "\n")
        path.text = content.path
        still.image = image ?? MusicChrome.placeholder(content.glyph, side: Self.width)
        setNeedsLayout()
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        still.frame = CGRect(x: 0, y: 0, width: width, height: Self.stillHeight)
        var y = still.frame.maxY + 16
        progressTrack.isHidden = content?.progress == nil
        if let progress = content?.progress {
            progressTrack.frame = CGRect(x: 0, y: y, width: width, height: 6)
            progressFill.frame = CGRect(x: 0, y: 0, width: width * progress, height: 6)
            y = progressTrack.frame.maxY
        }
        for label in [title, lines, path] {
            y += label === title ? 24 : 12
            let height = label.text?.isEmpty == false ? label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height : 0
            label.frame = CGRect(x: 0, y: y, width: width, height: height)
            y = label.frame.maxY
        }
    }
}
