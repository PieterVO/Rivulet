// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SentryEventRedaction.swift
//  Rivulet
//
//  The `beforeSend` scrub: strips credentials from every field of an outgoing
//  event, including the SDK-filled ones app code can't reach (`request.url`,
//  and exception values, where NSError embeds the failing URL).
//  SensitiveDataRedactor defines what counts as a secret.
//

import Foundation
import Sentry

nonisolated enum SentryEventRedaction {

    /// Scrubs an event in place and returns it. Never returns nil — dropping is
    /// the caller's decision; this only sanitizes.
    static func redact(_ event: Event) -> Event {
        // The NSError description that becomes the exception value.
        if let exceptions = event.exceptions {
            for exception in exceptions {
                exception.value = SensitiveDataRedactor.redactOptional(exception.value)
                // capture(error:) puts error.description and userInfo (with the
                // failing URL) on the mechanism.
                if let mechanism = exception.mechanism {
                    mechanism.desc = SensitiveDataRedactor.redactOptional(mechanism.desc)
                    mechanism.data = mechanism.data?.mapValues(redactAny)
                }
            }
        }

        // NSError userInfo lands in context["user info"], failing URL included.
        if let context = event.context {
            event.context = context.mapValues { $0.mapValues(redactAny) }
        }

        // SDK-populated failed-request context. No call site can reach this, so
        // it has to be handled here.
        if let request = event.request {
            request.url = SensitiveDataRedactor.redactOptional(request.url)
            request.queryString = SensitiveDataRedactor.redactOptional(request.queryString)
            if let headers = request.headers {
                request.headers = Dictionary(uniqueKeysWithValues: headers.map { name, value in
                    (name, SensitiveDataRedactor.isSecretName(name) ? SensitiveDataRedactor.redactedValue
                                                                     : SensitiveDataRedactor.redact(value))
                })
            }
            // Cookies are credentials wholesale; never worth shipping.
            if request.cookies != nil {
                request.cookies = SensitiveDataRedactor.redactedValue
            }
        }

        // Anything we attached via scope.setExtra, including response bodies —
        // a Plex error page can echo the request URL back at us.
        if let extra = event.extra {
            event.extra = extra.mapValues(redactAny)
        }

        if let tags = event.tags {
            event.tags = tags.mapValues { SensitiveDataRedactor.redact($0) }
        }

        if let breadcrumbs = event.breadcrumbs {
            for crumb in breadcrumbs {
                crumb.message = SensitiveDataRedactor.redactOptional(crumb.message)
                if let data = crumb.data {
                    crumb.data = data.mapValues(redactAny)
                }
            }
        }

        // `SentryMessage.formatted` is readonly and derived, so rebuild the
        // message from its redacted parts rather than mutating in place.
        if let message = event.message {
            let redactedMessage = SensitiveDataRedactor.redact(message.message ?? message.formatted)
            let rebuilt = SentryMessage(formatted: SensitiveDataRedactor.redact(message.formatted))
            rebuilt.message = redactedMessage
            rebuilt.params = message.params?.map { SensitiveDataRedactor.redact($0) }
            event.message = rebuilt
        }

        return event
    }

    /// Auto HTTP spans keep the raw query (`http.query`) and path; `beforeSend`
    /// never walks a transaction's spans.
    static func redact(_ span: Span) -> Span {
        span.spanDescription = SensitiveDataRedactor.redactOptional(span.spanDescription)
        for (key, value) in span.data {
            span.setData(value: redactAny(value), key: key)
        }
        return span
    }

    /// The same scrub for structured logs, which `beforeSend` never sees.
    static func redact(_ log: SentryLog) -> SentryLog {
        log.body = SensitiveDataRedactor.redact(log.body)
        log.attributes = log.attributes.mapValues { attribute in
            guard let string = attribute.value as? String else { return attribute }
            return SentryLog.Attribute(string: SensitiveDataRedactor.redact(string))
        }
        return log
    }

    /// Extras and breadcrumb data are `[String: Any]`, so recurse through the
    /// container types the SDK will actually serialize and redact any string or
    /// URL found at the leaves.
    static func redactAny(_ value: Any) -> Any {
        switch value {
        case let string as String:
            return SensitiveDataRedactor.redact(string)
        case let url as URL:
            return SensitiveDataRedactor.safeURLString(url)
        case let array as [Any]:
            return array.map(redactAny)
        case let error as NSError:
            // userInfo's underlying error describes itself with the failing URL.
            return SensitiveDataRedactor.redact(error.description)
        case let dictionary as [String: Any]:
            return dictionary.mapValues(redactAny)
        default:
            // Numbers, dates, bools — nothing to leak.
            return value
        }
    }
}
