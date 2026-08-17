// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

extension UIFocusAnimationCoordinator {
    /// Applies a focus appearance change without leaving a ghost behind.
    ///
    /// Gaining focus rides the coordinator so the new fill grows with the focus
    /// move. Losing it must be instant: an unfocus run through the coordinator
    /// leaves the old row's white capsule fading behind the move, which reads as
    /// ghosting. `ShellSidebarViewController` and `SettingsCell` carry the same
    /// rule inline; every popup/menu row goes through here.
    func animateFocusChange(gained: Bool, _ apply: @escaping () -> Void) {
        if gained {
            addCoordinatedAnimations(apply, completion: nil)
        } else {
            apply()
        }
    }
}
