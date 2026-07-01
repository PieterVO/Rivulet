//
//  AetherPlayerViewController.swift
//  Rivulet
//
//  AVPlayerViewController host for the Aether route. Binds
//  `self.player` to `viewModel.aetherPlayer?.$currentAVPlayer`. Uses
//  `.sink` (NOT `.first()`) because AetherEngine swaps its underlying
//  AVPlayer instance on every internal reload (audio-track switch,
//  background reopen). The publisher re-emits with the new AVPlayer
//  each time; the host must rebind on every emission.
//
//  Documented at AetherEngine.swift:1225 -- the `currentAVPlayer`
//  publisher exists specifically so AVPlayerViewController hosts can
//  rebind their .player on every Aether reload.
//
//  Subtitle overlay
//  ----------------
//  AetherSubtitleOverlayView is hosted via a retained UIHostingController
//  child VC whose view is added to `contentOverlayView` (above video,
//  below AVKit's transport bar). This is the correct mount point for
//  overlays that must coexist with AVKit's native controls; Sodalite mounts
//  in self.view because it suppresses AVKit chrome -- we do not.
//
//  Live restyle: CaptionAppearance.changedNotification triggers a rootView
//  rebuild with a fresh CaptionAppearance.current() style. rootView is
//  replaced wholesale (all three params at once) so SwiftUI diffing sees a
//  clean value update.
//

import AVKit
import Combine
import CoreMedia
import SwiftUI

class AetherPlayerViewController: AVPlayerViewController, AVPlayerViewControllerDelegate {

    // MARK: - Inherited (inlined from BaseAVPlayerViewController)

    let viewModel: UniversalPlayerViewModel
    var cancellables = Set<AnyCancellable>()
    private var progressTimer: Timer?
    private var lastReportedTime: TimeInterval = -1
    var onDismiss: (() -> Void)?

    init(viewModel: UniversalPlayerViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Subtitle state

    /// Drives the subtitle overlay. Fed from AetherPlayer publishers.
    private let subtitleModel = AetherSubtitleModel()

    /// Retained hosting controller. Must be retained as a child VC;
    /// releasing it while its view is attached causes layout to die.
    private var subtitleHostingController: UIHostingController<AetherSubtitleOverlayView>?

    /// Current caption style. Replaced on CaptionAppearance.changedNotification.
    private var captionStyle: CaptionStyle = CaptionAppearance.current()

    /// Whether AVKit's transport bar is currently visible.
    /// AVPlayerViewController does not expose a public publisher for this,
    /// so we track it via the `showsPlaybackControls` observed property and
    /// assume visible initially (conservative: more bottom padding at start).
    private var controlsVisible: Bool = true

    // MARK: - Native Up Next (AVContentProposal)

    /// The next-episode value the current proposal was built for. Identity
    /// guard so we build/set the proposal once per next-episode resolution
    /// and do not re-present on checkMarkers re-entry or duplicate emissions.
    private var proposedNextEpisodeRatingKey: String?

    /// True while re-attaching the existing proposal to a freshly-swapped
    /// currentItem (Aether internal AVPlayer reload). Suppresses the
    /// one-per-episode timing log so it is not re-emitted on every swap.
    private var isReapplyingProposalOnSwap = false

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        allowsPictureInPicturePlayback = false
        bindContextualActions()
        delegate = self
        mountSubtitleOverlay()
        observeControlsVisibility()
        observeCaptionAppearance()
        bindPlayerSpecific()
    }

    // MARK: - Contextual actions (inlined from BaseAVPlayerViewController)

    private func bindContextualActions() {
        viewModel.$activeMarker
            .receive(on: DispatchQueue.main)
            .sink { [weak self] marker in
                guard let self else { return }
                if marker != nil {
                    let label = self.viewModel.skipButtonLabel
                    self.contextualActions = [
                        UIAction(title: label, image: UIImage(systemName: "forward.fill")) { [weak self] _ in
                            guard let self else { return }
                            Task { await self.viewModel.skipActiveMarker() }
                        }
                    ]
                } else {
                    self.contextualActions = []
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle (inlined from BaseAVPlayerViewController)

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        NotificationCenter.default.post(name: .plexPlaybackStarted, object: nil)
        Task { @MainActor in
            await viewModel.startPlayback()
        }
        startProgressReporting()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || isMovingFromParent {
            stopProgressReporting()
            reportFinalProgress()
            NotificationCenter.default.post(name: .plexPlaybackStopped, object: nil)
            viewModel.stopPlayback()
            onDismiss?()
        }
    }

    // MARK: - Plex Progress Reporting (inlined from BaseAVPlayerViewController)

    private func startProgressReporting() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.reportCurrentProgress()
        }
    }

    private func stopProgressReporting() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func reportCurrentProgress() {
        let time = viewModel.currentTime
        guard abs(time - lastReportedTime) >= 5 else { return }
        lastReportedTime = time

        let ratingKey = viewModel.metadata.ratingKey ?? ""
        let duration = viewModel.duration
        let state = viewModel.isPlaying ? "playing" : "paused"

        Task {
            await PlexProgressReporter.shared.reportProgress(
                ratingKey: ratingKey,
                time: time,
                duration: duration,
                state: state
            )
        }
    }

    private func reportFinalProgress() {
        let ratingKey = viewModel.metadata.ratingKey ?? ""
        let time = viewModel.currentTime
        let duration = viewModel.duration

        Task {
            await PlexProgressReporter.shared.reportProgress(
                ratingKey: ratingKey,
                time: time,
                duration: duration,
                state: "stopped",
                forceReport: true
            )

            if duration > 0 && time / duration > 0.9 {
                await PlexProgressReporter.shared.markAsWatched(ratingKey: ratingKey)
            }

            try? await Task.sleep(nanoseconds: 2_000_000_000)

            await MainActor.run {
                NotificationCenter.default.post(name: .plexDataNeedsRefresh, object: nil)
            }
        }
    }

    // MARK: - Overlay mounting

    /// Adds AetherSubtitleOverlayView as a child VC in contentOverlayView.
    ///
    /// Per the tvOS UIKit rules (research/viewcontrollers-presentation.md):
    ///   addChild -> addSubview + constraints/autoresizingMask -> didMove(toParent:)
    ///
    /// contentOverlayView is always non-nil after viewDidLoad has run on
    /// AVPlayerViewController (it is created as part of the player view hierarchy).
    /// We fall back to view if it were somehow nil, but that should never occur.
    private func mountSubtitleOverlay() {
        let overlayView = AetherSubtitleOverlayView(
            model: subtitleModel,
            style: captionStyle,
            controlsVisible: controlsVisible
        )
        let hosting = UIHostingController(rootView: overlayView)
        hosting.view.backgroundColor = .clear
        hosting.view.isUserInteractionEnabled = false

        // Proper containment order per UIKit containment contract.
        addChild(hosting)
        let container = contentOverlayView ?? view!
        container.addSubview(hosting.view)
        hosting.view.frame = container.bounds
        hosting.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hosting.didMove(toParent: self)

        subtitleHostingController = hosting
    }

    // MARK: - Caption appearance

    private func observeCaptionAppearance() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(captionAppearanceDidChange),
            name: CaptionAppearance.changedNotification,
            object: nil
        )
    }

    @objc private func captionAppearanceDidChange() {
        captionStyle = CaptionAppearance.current()
        rebuildOverlayRootView()
    }

    // MARK: - Controls visibility

    /// AVPlayerViewController exposes no delegate or publisher for transport bar
    /// visibility. We observe `showsPlaybackControls` via KVO so we can lift the
    /// subtitle text above the bar when it appears.
    private var controlsObservation: NSKeyValueObservation?

    private func observeControlsVisibility() {
        controlsObservation = observe(\.showsPlaybackControls, options: [.initial, .new]) { [weak self] _, change in
            guard let self else { return }
            let visible = change.newValue ?? self.showsPlaybackControls
            // Dispatch to main in case KVO fires on a non-main queue (rare but possible).
            DispatchQueue.main.async {
                self.controlsVisible = visible
                self.rebuildOverlayRootView()
            }
        }
    }

    // MARK: - rootView rebuild

    private func rebuildOverlayRootView() {
        subtitleHostingController?.rootView = AetherSubtitleOverlayView(
            model: subtitleModel,
            style: captionStyle,
            controlsVisible: controlsVisible
        )
    }

    // MARK: - Native Up Next (AVContentProposal)

    /// Called when viewModel.nextEpisode changes. Builds and attaches a
    /// proposal on a non-nil transition (native route + real currentItem),
    /// or clears it on nil.
    private func handleNextEpisodeChange(_ next: PlexMetadata?) {
        // Note: auto-skip-credits no longer suppresses the card. On the native
        // route the card wins over the credits skip — the view model suppresses
        // the auto-skip jump (nativeUpNextCardWillPresent) so the card can
        // present at the credits marker and auto-accept.
        guard let next, let ratingKey = next.ratingKey else {
            clearNextContentProposal()
            return
        }

        // Native route only: a real AVPlayer/currentItem must exist to carry a
        // proposal. On the software/DV route currentAVPlayer is nil (no card).
        // Target THIS view controller's own player item (self.player) — that is
        // the item AVKit actually presents the card from. It is normally the
        // same object as the engine's currentAVPlayer item, but binding to
        // self.player avoids any window where they differ across a swap.
        guard viewModel.isAetherNativeRouteActive,
              let item = player?.currentItem else {
            return
        }

        // Build once per next-episode resolution. The per-ratingKey identity
        // guard ignores duplicate emissions and checkMarkers re-entry (seek-back)
        // for the same episode while this VC instance lives. (The view model
        // owns the separate "episode-end handled" flag that guards
        // mark-watched / next-episode resolution exactly once; see
        // handlePlaybackEnded().)
        guard proposedNextEpisodeRatingKey != ratingKey else { return }
        proposedNextEpisodeRatingKey = ratingKey

        // Compute the transition time: the point in the CURRENT item's timeline
        // where AVKit begins presenting the card. tvOS's AVContentProposal takes
        // this directly (contentTimeForTransition), so we can request the Plex
        // credits marker rather than relying on AVKit's default near-end window.
        // kCMTimeIndefinite => AVKit's default (present at the very end).
        let transition = transitionTime(for: viewModel.metadata)
        // Log once per episode when first attached, not on item-swap re-applies.
        if !isReapplyingProposalOnSwap {
            logUpNextTiming(transition: transition)
        }

        // Set proposal immediately with a title-only card, then refine with the
        // preview image once it loads (previewImage is optional).
        setProposal(for: next, on: item, transition: transition, previewImage: nil)
        loadPreviewImageAndRefresh(for: next, item: item, transition: transition)
    }

    /// Transition time for the card on the current item. The first Plex credits
    /// marker start if present (where end credits begin, the natural Up Next
    /// moment); otherwise kCMTimeIndefinite, which tells AVKit to present at the
    /// very end of the item (its default near-end window).
    private func transitionTime(for currentMetadata: PlexMetadata) -> CMTime {
        if let credits = currentMetadata.firstCreditsMarker {
            return CMTime(seconds: credits.startTimeSeconds, preferredTimescale: 600)
        }
        return CMTime.indefinite
    }

    /// Build the AVContentProposal and attach it to the item.
    private func setProposal(for next: PlexMetadata, on item: AVPlayerItem, transition: CMTime, previewImage: UIImage?) {
        let title = nextEpisodeProposalTitle(for: next)
        let proposal = AVContentProposal(
            contentTimeForTransition: transition,
            title: title,
            previewImage: previewImage
        )

        // Auto-acceptance interval mirrors the custom overlay's autoplay
        // countdown. autoplayCountdown default is 5s; 0 means "disabled", which
        // maps to NAN so AVKit performs no automatic accept (AVKit's default).
        let countdown: Int
        if UserDefaults.standard.object(forKey: "autoplayCountdown") == nil {
            countdown = 5
        } else {
            countdown = UserDefaults.standard.integer(forKey: "autoplayCountdown")
        }
        proposal.automaticAcceptanceInterval = countdown > 0 ? TimeInterval(countdown) : .nan

        item.nextContentProposal = proposal
    }

    /// Asynchronously load the next episode thumbnail and rebuild the proposal
    /// with it. Reuses the same thumb URL shape as the post-video cards. No-op
    /// if the next episode resolution changed before the image arrived.
    private func loadPreviewImageAndRefresh(for next: PlexMetadata, item: AVPlayerItem, transition: CMTime) {
        guard let thumb = next.thumb,
              let url = URL(string: "\(viewModel.serverURL)\(thumb)?X-Plex-Token=\(viewModel.authToken)") else {
            return
        }
        let ratingKey = next.ratingKey
        Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: url, quality: .thumb)
            await MainActor.run {
                guard let self,
                      let image,
                      self.proposedNextEpisodeRatingKey == ratingKey,
                      self.player?.currentItem === item else {
                    return
                }
                self.setProposal(for: next, on: item, transition: transition, previewImage: image)
            }
        }
    }

    /// "Up Next" card title. Prefer "S{season}E{ep} - Title"; fall back to
    /// the episode title, then a generic label.
    private func nextEpisodeProposalTitle(for next: PlexMetadata) -> String {
        let epTitle = next.title ?? "Next Episode"
        if let season = next.parentIndex, let number = next.index {
            return "S\(season)E\(number) - \(epTitle)"
        }
        return epTitle
    }

    /// Clear any attached proposal (episode change / no next episode).
    private func clearNextContentProposal() {
        proposedNextEpisodeRatingKey = nil
        player?.currentItem?.nextContentProposal = nil
    }

    /// Emit the mandatory timing log line (spec requirement). credits-marker
    /// when we set an explicit transition time at the Plex credits marker;
    /// avkit-default when there is no marker (kCMTimeIndefinite -> AVKit's own
    /// near-end window).
    private func logUpNextTiming(transition: CMTime) {
        let path = transition.isIndefinite ? "avkit-default" : "credits-marker"
        print("[UpNext] native card presented via \(path) timing")
    }

    // MARK: - Player binding

    private func bindPlayerSpecific() {
        // Bind AVPlayer instance.
        viewModel.$aetherPlayer
            .compactMap { $0 }
            .flatMap { $0.$currentAVPlayer }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] avPlayer in
                guard let self else { return }
                self.player = avPlayer
                // Aether swapped its internal AVPlayer/currentItem; the new item
                // carries no proposal. Re-apply the cached next episode so the
                // native Up Next card survives the swap. Clear the per-ratingKey
                // guard so handleNextEpisodeChange rebuilds onto the new item;
                // flag the re-apply so it does not re-emit the timing log.
                if avPlayer != nil, self.viewModel.nextEpisode != nil {
                    self.isReapplyingProposalOnSwap = true
                    self.proposedNextEpisodeRatingKey = nil
                    self.handleNextEpisodeChange(self.viewModel.nextEpisode)
                    self.isReapplyingProposalOnSwap = false
                }
            }
            .store(in: &cancellables)

        // Feed cue list into the subtitle model.
        viewModel.$aetherPlayer
            .compactMap { $0 }
            .flatMap { $0.$subtitleCues }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                self?.subtitleModel.update(cues: cues)
            }
            .store(in: &cancellables)

        // Feed source time into the subtitle model (drives activeCues lookup).
        viewModel.$aetherPlayer
            .compactMap { $0 }
            .flatMap { $0.$sourceTime }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                self?.subtitleModel.sourceTime = time
            }
            .store(in: &cancellables)

        // Native Up Next card: when the host resolves a next episode on the
        // Aether native route, build an AVContentProposal and attach it to the
        // current item so AVKit renders its native card. UI + signal only: we
        // do NOT queue a real next item; accept routes through the host's
        // playNextEpisode() (see delegate callbacks).
        viewModel.$nextEpisode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] next in
                self?.handleNextEpisodeChange(next)
            }
            .store(in: &cancellables)
    }

    // MARK: - AVPlayerViewControllerDelegate (Up Next)

    func playerViewController(_ playerViewController: AVPlayerViewController,
                             shouldPresent proposal: AVContentProposal) -> Bool {
        // Returning true is necessary but NOT sufficient on tvOS: AVKit ships no
        // built-in proposal UI, so without a concrete contentProposalViewController
        // the card never renders even though this delegate fires. Assign the host
        // VC here, built from the resolved next episode.
        guard let next = viewModel.nextEpisode else { return false }
        playerViewController.contentProposalViewController = UpNextContentProposalViewController(
            next: next,
            serverURL: viewModel.serverURL,
            authToken: viewModel.authToken
        )
        return true
    }

    func playerViewController(_ playerViewController: AVPlayerViewController,
                             didAccept proposal: AVContentProposal) {
        // UI + signal only: do NOT let AVKit advance its own queue. Route
        // through the host so Continue-Watching / scrobble / mark-watched stay
        // intact and Aether owns the item lifecycle.
        print("[UpNext] native card accepted -> playNextEpisode()")
        Task { @MainActor [weak self] in
            await self?.viewModel.playNextEpisode()
        }
    }

    func playerViewController(_ playerViewController: AVPlayerViewController,
                             didReject proposal: AVContentProposal) {
        // User declined. Clear the proposal and let the episode end normally;
        // handlePlaybackEnded() runs (guarded on the native route so it does
        // not pop the custom overlay or double-advance).
        print("[UpNext] native card rejected")
        // Re-enable the manual Skip Credits button for the rest of the credits.
        viewModel.handleNativeUpNextRejected()
        Task { @MainActor [weak self] in
            self?.clearNextContentProposal()
        }
    }

    // No deinit needed: pickerPollTimer uses [weak self] so it won't
    // retain this VC. stopPickerPollTimer() is called by rebindPickerObservation
    // on every AVPlayer swap, and on VC teardown AVKit's own cleanup nilifies
    // self.player which stops the item -- the timer fires and returns early.
    // If explicit pre-teardown cleanup is ever needed, call stopPickerPollTimer()
    // from viewDidDisappear before calling super.
}
