//
//  SentryBridge.swift
//  Rivulet
//
//  Thin wrapper around SentrySDK that silently no-ops in DEBUG builds.
//  The SDK is never started in debug, so calling it directly generates
//  console noise for every breadcrumb and capture call.
//

import Sentry

enum SentryBridge {
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
