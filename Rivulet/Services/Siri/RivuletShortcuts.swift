// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  RivuletShortcuts.swift
//  Rivulet
//
//  Registers Siri voice phrases so intents work without prior user setup.
//

import AppIntents

struct RivuletShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayMediaIntent(),
            phrases: [
                "Play something on \(.applicationName)",
                "Watch something on \(.applicationName)"
            ],
            shortTitle: "Play Media",
            systemImageName: "play.fill"
        )
    }
}
