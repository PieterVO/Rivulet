//
//  UpNextContentProposalViewController.swift
//  Rivulet
//
//  The view controller AVKit presents for the native Up Next card on the
//  Aether native route. Returning `true` from
//  `playerViewController(_:shouldPresent:)` is NOT enough on tvOS: AVKit ships
//  no built-in proposal UI, so unless `AVPlayerViewController.contentProposalViewController`
//  is assigned a concrete `AVContentProposalViewController`, the card never
//  renders (the delegate fires, nothing appears). This is that VC.
//
//  Layout mirrors Apple's native Up Next treatment: the still-playing video is
//  inset into a thumbnail in the upper area (via `preferredPlayerViewFrame`) and
//  the rest of the screen becomes a solid dark proposal surface. The card sits
//  in that dark area BELOW the inset video (anchored to `playerLayoutGuide`), so
//  it never overlaps live video — which keeps the white card text legible even
//  over bright/white end-credits screens.
//
//  It hosts the existing SwiftUI `NextEpisodeCard` for design parity with the
//  post-video overlay, plus a focusable Play button. Accept/reject are routed
//  back through AVKit via `dismissContentProposal(for:animated:completion:)`,
//  which drives the host's `didAccept` / `didReject` delegate callbacks (where
//  the host calls `playNextEpisode()`); this VC itself performs no playback.
//
//  Auto-acceptance: AVKit owns the countdown. The proposal's
//  `automaticAcceptanceInterval` is measured from when *playback ends* (not
//  from when the card appears), and AVKit renders its own countdown timer for
//  it. This VC therefore does not draw a countdown of its own.
//

import AVKit
import SwiftUI
import UIKit

final class UpNextContentProposalViewController: AVContentProposalViewController {

    private let nextEpisode: PlexMetadata
    private let serverURL: String
    private let authToken: String

    private var hostingController: UIHostingController<NextEpisodeCard>?
    private var playButton: UIButton?
    private var cardTopConstraint: NSLayoutConstraint?
    private let backdropLayer = CAGradientLayer()

    init(next: PlexMetadata, serverURL: String, authToken: String) {
        self.nextEpisode = next
        self.serverURL = serverURL
        self.authToken = authToken
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Player inset (Apple-style)

    /// Inset the still-playing video into a 16:9 thumbnail in the upper area,
    /// horizontally centered, leaving the lower portion of the screen as the
    /// dark proposal surface where the card lives. AVKit reads this to position
    /// the player view during the proposal; default would be the full screen.
    /// Fraction of screen height the inset video's bottom edge sits at. The card
    /// is anchored below this. Kept as a constant so `preferredPlayerViewFrame`
    /// and the card layout agree without depending on AVKit's `playerLayoutGuide`
    /// (which is not in this VC's view hierarchy at layout time — constraining to
    /// it crashes with "no common ancestor").
    private let videoTopInsetFraction: CGFloat = 0.08
    private let videoWidthFraction: CGFloat = 0.58

    override var preferredPlayerViewFrame: CGRect {
        let bounds = view.bounds
        guard bounds.width > 0, bounds.height > 0 else { return bounds }
        // Video occupies the top region; the card sits below it. Width ~58% of
        // screen, centered, 16:9, top-inset by ~8% of height.
        let topInset = bounds.height * videoTopInsetFraction
        let videoWidth = bounds.width * videoWidthFraction
        let videoHeight = videoWidth * 9.0 / 16.0
        let originX = (bounds.width - videoWidth) / 2.0
        return CGRect(x: originX, y: topInset, width: videoWidth, height: videoHeight)
    }

    /// The y-position of the inset video's bottom edge, used to place the card
    /// just beneath it without referencing AVKit's player layout guide.
    private var videoBottomY: CGFloat {
        let bounds = view.bounds
        let topInset = bounds.height * videoTopInsetFraction
        let videoHeight = (bounds.width * videoWidthFraction) * 9.0 / 16.0
        return topInset + videoHeight
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        buildBackdrop()
        buildCard()
        buildControls()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsFocusUpdate()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Place the card just below the inset video. Computed from bounds (not
        // AVKit's playerLayoutGuide, which isn't in our hierarchy) so it's safe.
        cardTopConstraint?.constant = videoBottomY + 48

        // Backdrop fills the view; the gradient stays clear over the inset video
        // (top → video bottom) then ramps to dark just beneath it, so the video
        // shows through up top and the card sits on a dark surface below.
        backdropLayer.frame = view.bounds
        let h = max(view.bounds.height, 1)
        let clearUntil = min(max(videoBottomY / h, 0.0), 1.0)
        let darkStart = min(clearUntil + 0.04, 1.0)
        backdropLayer.locations = [0.0, NSNumber(value: Double(clearUntil)), NSNumber(value: Double(darkStart)), 1.0]
        backdropLayer.colors = [
            UIColor.clear.cgColor,
            UIColor.clear.cgColor,
            UIColor.black.withAlphaComponent(0.92).cgColor,
            UIColor.black.withAlphaComponent(0.96).cgColor,
        ]
    }

    // MARK: - UI

    /// Dark proposal surface, but ONLY across the lower region — clear over the
    /// top where AVKit insets the still-playing video (an opaque full-view
    /// backdrop would cover the inset player and the screen looks all-black; the
    /// video only reappears once the card dismisses). A vertical gradient that is
    /// clear over the video and ramps to near-opaque dark below it: the inset
    /// video stays visible up top (ATV+-style), and the card sits on the dark
    /// surface below, legible over any content including bright/white credits.
    private func buildBackdrop() {
        view.backgroundColor = .clear
        // Colors + stops are set in viewDidLayoutSubviews (they depend on the
        // inset video's bottom edge, which depends on bounds).
        backdropLayer.startPoint = CGPoint(x: 0.5, y: 0.0)
        backdropLayer.endPoint = CGPoint(x: 0.5, y: 1.0)
        view.layer.insertSublayer(backdropLayer, at: 0)
    }

    private func buildCard() {
        let card = NextEpisodeCard(episode: nextEpisode, serverURL: serverURL, authToken: authToken)
        let host = UIHostingController(rootView: card)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        host.didMove(toParent: self)
        hostingController = host

        // Anchor the card BELOW the inset video. We position by a top constraint
        // from the view's top, updated in viewDidLayoutSubviews to sit just under
        // the inset video — NOT via AVKit's playerLayoutGuide, which is not in
        // this VC's view hierarchy and crashes ("no common ancestor") if used.
        let topConstraint = host.view.topAnchor.constraint(equalTo: view.topAnchor, constant: 0)
        cardTopConstraint = topConstraint
        NSLayoutConstraint.activate([
            topConstraint,
            host.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            host.view.widthAnchor.constraint(equalTo: view.widthAnchor, multiplier: videoWidthFraction),
        ])
    }

    private func buildControls() {
        let button = UIButton(type: .system)
        var config = UIButton.Configuration.filled()
        config.title = "Play Next"
        config.image = UIImage(systemName: "play.fill")
        config.imagePadding = 8
        config.cornerStyle = .capsule
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(playTapped), for: .primaryActionTriggered)
        view.addSubview(button)
        playButton = button

        guard let card = hostingController?.view else { return }
        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: card.bottomAnchor, constant: 24),
            button.leadingAnchor.constraint(equalTo: card.leadingAnchor),
        ])
    }

    // MARK: - Focus

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if let playButton { return [playButton] }
        return super.preferredFocusEnvironments
    }

    // MARK: - Accept / reject

    /// Accept: dismiss with the `.accept` action, which triggers the host's
    /// `playerViewController(_:didAccept:)` where `playNextEpisode()` runs.
    @objc private func playTapped() {
        dismissContentProposal(for: .accept, animated: true, completion: nil)
    }

    /// Menu / swipe-down rejects: dismiss with the `.reject` action, which
    /// triggers the host's `playerViewController(_:didReject:)`.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .menu }) {
            dismissContentProposal(for: .reject, animated: true, completion: nil)
            return
        }
        super.pressesBegan(presses, with: event)
    }
}
