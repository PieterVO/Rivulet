# Plan: Improve tvOS Input Handling for Third-Party Controllers

## Summary

Add support for game controllers (Xbox, PlayStation, MFi), keyboards, and improve the robustness of existing input handling. The app already has excellent Siri Remote and IR remote support - this extends that foundation.

## Current State

**Already Working:**
- Siri Remote via `GCMicroGamepad` in `RemoteInputHandler` class
- IR remotes (Harmony, One For All) via `UIPress` gestures
- System commands via `MPRemoteCommandCenter`
- SwiftUI `.onPlayPauseCommand`, `.onMoveCommand`

**Gaps:**
- No `GCExtendedGamepad` support (Xbox/PlayStation/MFi controllers)
- No `GCKeyboard` support
- Hardcoded 0.4s hold threshold in multiple places
- No input rate limiting for rapid presses
- `blockNextDismiss` flag has no timeout (potential stuck state)

---

## Implementation Plan

### Phase 1: Create InputConfig.swift

**New file:** `/Rivulet/Config/InputConfig.swift`

Centralize all input-related constants:
```swift
enum InputConfig {
    static let holdThreshold: TimeInterval = 0.4
    static let inputDebounceInterval: TimeInterval = 0.05
    static let blockDismissTimeout: TimeInterval = 0.3
    static let tapSeekAmount: TimeInterval = 10
    static let jumpSeekAmount: TimeInterval = 30
    static let joystickDeadzone: Float = 0.2
    static let rotationThreshold: Float = 0.3
    static let radiusThreshold: Float = 0.7
}
```

**Update references in:**
- `UniversalPlayerView.swift` line 25: replace `0.4` with `InputConfig.holdThreshold`
- `PlayerContainerViewController.swift` lines 306, 312: replace `0.4` literals

---

### Phase 2: Add Extended Gamepad Support

**Modify:** `/Rivulet/Views/Player/UniversalPlayerView.swift`

Rename `RemoteInputHandler` → `InputController` and add:

```swift
private func setupController(_ controller: GCController) {
    if let extended = controller.extendedGamepad {
        setupExtendedGamepad(extended)
    } else if let micro = controller.microGamepad {
        setupMicroGamepad(micro)  // existing code unchanged
    }
}
```

**Button mapping for game controllers:**
| Button | Action |
|--------|--------|
| A / X (Cross) | Play/Pause, Confirm scrub |
| B / O (Circle) | Back/Cancel |
| X / Square | Show info panel |
| D-pad L/R | Tap: skip 10s, Hold: scrub |
| LB / L1 | Jump back 30s |
| RB / R1 | Jump forward 30s |
| LT / L2 | Proportional scrub backward |
| RT / R2 | Proportional scrub forward |
| Left stick | Horizontal scrubbing |

**New callbacks:**
- `onJumpSeek: ((Bool) -> Void)?` - 30s jumps via bumpers
- `onTriggerScrub: ((Float) -> Void)?` - proportional via triggers
- `onBack: (() -> Void)?` - B button handling
- `onShowInfo: (() -> Void)?` - X button handling

---

### Phase 3: Add Keyboard Support

**Modify:** `/Rivulet/Views/Player/UniversalPlayerView.swift`

Monitor `GCKeyboard.coalesced` and handle key events:
- **Space** → Play/Pause
- **Left/Right arrows** → Skip 10s
- **Escape** → Back/Cancel
- **Down arrow** → Show info

---

### Phase 4: Input Rate Limiting

**Modify:** `RemoteInputHandler` / `InputController`

Add debounce timer to coalesce rapid taps:
```swift
private var pendingSeekAmount: TimeInterval = 0
private var seekCoalesceTimer: Timer?

private func handleTapWithCoalescing(forward: Bool) {
    pendingSeekAmount += forward ? InputConfig.tapSeekAmount : -InputConfig.tapSeekAmount
    seekCoalesceTimer?.invalidate()
    seekCoalesceTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: false) { ... }
}
```

---

### Phase 5: Fix blockNextDismiss Timeout

**Modify:** `/Rivulet/Views/Player/PlayerContainerViewController.swift`

Add timeout to prevent stuck state:
```swift
blockNextDismiss = true
DispatchQueue.main.asyncAfter(deadline: .now() + InputConfig.blockDismissTimeout) { [weak self] in
    self?.blockNextDismiss = false
}
```

---

### Phase 6: Wire Up New Callbacks

**Modify:** `/Rivulet/Views/Player/UniversalPlayerView.swift` (in `onAppear`)

Connect new `InputController` callbacks to `UniversalPlayerViewModel`:
- `onJumpSeek` → `vm.seekRelative(by: ±30)`
- `onBack` → cancel scrub / close panel / dismiss
- `onShowInfo` → `vm.showInfoPanel = true`
- `onTriggerScrub` → new `vm.handleTriggerScrub(value:)` method

**Modify:** `/Rivulet/Views/Player/UniversalPlayerViewModel.swift`

Add new method for trigger-based proportional scrubbing.

---

## Files to Modify

| File | Changes |
|------|---------|
| `Config/InputConfig.swift` | **NEW** - centralized constants |
| `Views/Player/UniversalPlayerView.swift` | Extend `RemoteInputHandler` with `GCExtendedGamepad`, `GCKeyboard`, rate limiting |
| `Views/Player/PlayerContainerViewController.swift` | Use `InputConfig`, add dismiss timeout |
| `Views/Player/UniversalPlayerViewModel.swift` | Add `handleTriggerScrub()` method |

---

## Verification

### Hardware Testing
- [ ] Siri Remote (regression - must still work)
- [ ] IR learned remote (regression)
- [ ] Xbox Wireless Controller
- [ ] PlayStation DualSense/DualShock
- [ ] Bluetooth keyboard

### Functional Testing
- [ ] D-pad tap skips 10s, hold starts scrubbing
- [ ] Bumpers jump 30s
- [ ] Triggers provide proportional scrub
- [ ] B button cancels/goes back
- [ ] Keyboard space/arrows/escape work
- [ ] Rapid button presses are debounced

### Build Command
```bash
xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' build
```

---

## References

- [WWDC19: Supporting New Game Controllers](https://developer.apple.com/videos/play/wwdc2019/616/)
- [Big Nerd Ranch: tvOS Games - Using the Game Controller Framework](https://bignerdranch.com/blog/tvos-games-part-1-using-the-game-controller-framework/)
- [Apple: Detecting Gestures and Button Presses](https://developer.apple.com/library/archive/documentation/General/Conceptual/AppleTV_PG/DetectingButtonPressesandGestures.html)
- [Apple: Support directional remotes in your tvOS app](https://developer.apple.com/news/?id=33cpm46r)

---

## Notes

- No third-party libraries needed - native `GameController` framework is complete
- Apple requires Siri Remote support - all features must work without external controllers
- Existing `setupMicroGamepad` code stays unchanged to avoid regressions
