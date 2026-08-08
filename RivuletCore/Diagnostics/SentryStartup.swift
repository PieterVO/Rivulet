// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SentryStartup.swift
//  RivuletCore
//
//  The one copy of Rivulet's Sentry configuration, shared by the tvOS and iOS
//  apps. Lives here rather than in either app because every setting in it is a
//  decision that has to hold on both: the tracesSampler exists because a flat
//  rate saturated the performance quota and made Sentry drop spans server-side,
//  and beforeSend is the actual guarantee that no Plex token or IPTV
//  username/password reaches an event. A second copy that drifted would leak
//  credentials or bias the measurements on whichever platform fell behind.
//
//  Callers own their own deferral and DEBUG gating; this only configures and
//  starts the SDK.
//

import Sentry

public enum SentryStartup {
    /// MUST be main-actor isolated: `SentrySDK.start` builds the SDK's
    /// dependency container, which reads `UIApplication.applicationState` and
    /// installs swizzling plus session / app-hang tracking. Called off the main
    /// actor it trips the Main Thread Checker on every launch.
    @MainActor
    public static func start() {
        SentrySDK.start { options in
            options.dsn = Secrets.sentryDSN
            options.debug = false
            // Transactions we deliberately measure stay at full fidelity;
            // everything else is sampled hard.
            //
            // This was a flat 1.0, which meant `enableSwizzling` was sending
            // a transaction for EVERY UIViewController appearance and HTTP
            // request at 100%. On a small performance quota that ambient
            // auto-instrumentation is what consumes it, and once the quota
            // is hit Sentry drops spans server-side — which would bias the
            // named measurements we actually reason from rather than just
            // thinning them.
            options.tracesSampler = { context in
                context.transactionContext.name == "live.join"
                    ? NSNumber(value: 1.0)
                    : NSNumber(value: 0.05)
            }
            // Only consulted if the sampler ever returns nil.
            options.tracesSampleRate = 0.05
            options.attachStacktrace = true
            options.enableAutoSessionTracking = true
            options.enableCaptureFailedRequests = true
            options.enableSwizzling = true
            // App Hang tracking. On tvOS the SDK uses ANR Tracker V2
            // unconditionally (no `enableAppHangTrackingV2` toggle exists
            // in 9.x — it was made GA and removed), which snapshots ALL
            // threads with stack traces at the moment the watchdog fires.
            // This is what backs RIVULET-41. The reason that issue's
            // in-app frames show as <unknown> is missing/mismatched dSYMs
            // for the release, NOT a tracker-version problem — ensure
            // dSYMs upload for each App Store build so the frames resolve.
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = 2
            // Also report non-fully-blocking hangs (partial main-thread
            // stalls), not just fully-blocked ones. Defaults true in 9.x;
            // set explicitly so a future SDK default flip can't silence them.
            options.enableReportNonFullyBlockingAppHangs = true

            options.beforeSend = { event in
                // Drop cancelled URL request errors — these are normal when
                // navigating away. "CancellationError" is listed explicitly:
                // Swift's structured-concurrency error stringifies as
                // "CancellationError()", which matches neither "Code=-999"
                // nor the lowercase double-l "cancelled" (RIVULET-19). This
                // is a backstop; the real fix is not raising the event.
                func isCancellationText(_ text: String) -> Bool {
                    text.contains("Code=-999")
                        || text.contains("cancelled")
                        || text.contains("CancellationError")
                }
                if let exceptions = event.exceptions,
                   exceptions.contains(where: { isCancellationText($0.value ?? "") }) {
                    return nil
                }
                if let message = event.message?.formatted,
                   message.contains("Code=-999")
                    || message.contains("CancellationError")
                    || (message.contains("NSURLErrorDomain") && message.contains("cancelled")) {
                    return nil
                }
                // Plex passes `X-Plex-Token` as a URL query parameter, and
                // IPTV providers pass username/password the same way, so any
                // URL that reaches an event carries a live credential. Call
                // sites use SensitiveDataRedactor directly, but this hook is
                // the actual guarantee: it also covers events the SDK builds
                // itself (enableCaptureFailedRequests attaches the failing
                // request URL) and NSError descriptions with an embedded URL,
                // neither of which any call site can reach.
                return SentryEventRedaction.redact(event)
            }
        }
        SentryBridge.isActive = true
    }
}
