// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexRelay.swift
//  Rivulet
//
//  Plex relay-connection detection. The relay is a ~1-2 Mbps tunnel that answers
//  raw /library/parts fetches with 500, so ContentRouter sends relay servers to
//  HLS and buildHLSDirectPlayURL caps them at 1.5 Mbps 480p, as stock Plex does.
//

import Foundation

nonisolated enum PlexRelay {
    /// Plex relay endpoints are always `<ip-dashes>.<hash>.plex.direct:8443`;
    /// direct plex.direct connections embed the server's real port instead.
    static func isRelayURL(_ url: URL) -> Bool {
        guard let host = url.host else { return false }
        return host.hasSuffix(".plex.direct") && url.port == 8443
    }

    static func isRelayURL(_ serverURL: String) -> Bool {
        guard let url = URL(string: serverURL) else { return false }
        return isRelayURL(url)
    }
}
