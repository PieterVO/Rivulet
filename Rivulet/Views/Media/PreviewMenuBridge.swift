//
//  PreviewMenuBridge.swift
//  Rivulet
//
//  Bridge object that lets a hosting UIViewController forward Menu-button
//  presses into a SwiftUI detail view (e.g. `MediaDetailView`) so the view
//  can intercept them for internal navigation before the host dismisses.
//  Injected via the `previewMenuBridge` environment value.
//

import SwiftUI
import Combine

@MainActor
class PreviewMenuBridge: ObservableObject {
    @Published var menuPressCount: Int = 0

    /// Optional intercept handler set by the expanded detail view.
    /// Returns true if the press was consumed (e.g., popping internal navigation).
    var interceptHandler: (() -> Bool)?

    func triggerMenu() {
        if let handler = interceptHandler, handler() {
            return  // Consumed by detail view's internal nav
        }
        menuPressCount += 1
    }
}

private struct PreviewMenuBridgeKey: EnvironmentKey {
    static let defaultValue: PreviewMenuBridge? = nil
}

extension EnvironmentValues {
    var previewMenuBridge: PreviewMenuBridge? {
        get { self[PreviewMenuBridgeKey.self] }
        set { self[PreviewMenuBridgeKey.self] = newValue }
    }
}
