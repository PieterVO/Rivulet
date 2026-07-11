//
//  SentryBridge.swift
//  Rivulet
//
//  Thin wrapper around SentrySDK that silently no-ops in DEBUG builds.
//  The SDK is never started in debug, so calling it directly generates
//  console noise for every breadcrumb and capture call.
//

import Sentry

// `nonisolated` on purpose. The project compiles with MainActor default
// isolation, so without this the whole enum is inferred @MainActor — which made
// every capture from a non-isolated async context (the Live TV providers, any
// URLSession continuation) an actor hop, and a hard error under full Swift 6.
// SentrySDK is internally thread-safe and explicitly documented as callable
// from any thread, so binding it to the main actor buys nothing and costs a hop
// on the error path, which is exactly where we least want to perturb timing.
nonisolated enum SentryBridge {
    static func addBreadcrumb(_ crumb: Breadcrumb) {
        #if !DEBUG
        SentrySDK.addBreadcrumb(crumb)
        #endif
    }

    static func capture(error: Error, configure: ((Scope) -> Void)? = nil) {
        #if !DEBUG
        if let configure {
            SentrySDK.capture(error: error) { configure($0) }
        } else {
            SentrySDK.capture(error: error)
        }
        #endif
    }

    static func capture(event: Event) {
        #if !DEBUG
        SentrySDK.capture(event: event)
        #endif
    }

    static func configureScope(_ configure: @escaping (Scope) -> Void) {
        #if !DEBUG
        SentrySDK.configureScope(configure)
        #endif
    }
}
