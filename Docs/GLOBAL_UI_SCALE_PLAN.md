# Feature: Global UI Scale Setting

## Overview
Expand the existing "Sidebar Font Size" setting to become a global "Display Size" setting that scales all UI elements throughout the app - sidebar, settings, movie rows, posters, library grids, etc.

## Current State
- `SidebarFontSize` enum in SettingsView.swift with 3 levels: Normal (1.0x), Large (1.25x), Extra Large (1.5x)
- Only applied to sidebar components via `fontScale` parameter
- All other UI components (settings, posters, library views) have hardcoded sizes

## Implementation Plan

### 1. Rename and Relocate the Enum
**File:** Create new file or add to existing design system

Move `SidebarFontSize` → `DisplaySize` (or `UIScale`) and relocate from SettingsView.swift to a more central location.

```swift
enum DisplaySize: String, CaseIterable, CustomStringConvertible {
    case normal = "normal"
    case large = "large"
    case extraLarge = "extraLarge"

    var description: String { ... }
    var scale: CGFloat { /* 1.0, 1.25, 1.5 */ }
}
```

### 2. Create Environment Key for Global Access
Create an environment key so any view can access the scale without passing it through every component:

```swift
private struct UIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1.0
}

extension EnvironmentValues {
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}
```

### 3. Inject Scale at App Root
In TVSidebarView (and ContentView for iOS), read AppStorage and inject into environment:

```swift
@AppStorage("displaySize") private var displaySizeRaw = DisplaySize.normal.rawValue

var body: some View {
    content
        .environment(\.uiScale, displayScale)
}

private var displayScale: CGFloat {
    (DisplaySize(rawValue: displaySizeRaw) ?? .normal).scale
}
```

### 4. Update Settings UI
**File:** `Rivulet/Views/Settings/SettingsView.swift`

- Update AppStorage key from `"sidebarFontSize"` → `"displaySize"`
- Update picker title from "Sidebar Font Size" → "Display Size"
- Update subtitle from "Menu text size" → "Scale all interface elements"

### 5. Apply Scaling to Components

#### Settings Components (`SettingsComponents.swift`)
Add `@Environment(\.uiScale) private var scale` and multiply all font sizes and dimensions:
- Section title: `21 * scale`
- Row icon: `28 * scale`
- Row title: `29 * scale`
- Row subtitle: `23 * scale`
- Toggle, picker, action row sizes

#### Media Poster Card (`MediaPosterCard.swift`)
Scale poster dimensions and fonts:
- Poster width/height: `220 * scale`, `330 * scale`
- Title font: `19 * scale`
- Subtitle font: `16 * scale`
- Grid spacing and padding

#### Cast Member Card (`CastMemberCard.swift`)
- Card dimensions: `160 * scale`, `240 * scale`
- Name/subtitle fonts

#### Plex Home View (`PlexHomeView.swift`)
- Hero title: `56 * scale`
- Metadata fonts
- Row titles and spacing

#### Plex Library View (`PlexLibraryView.swift`)
- Grid column minimum/maximum sizes
- Header fonts
- Padding values

#### Live TV Views
- Channel card sizes
- Guide row heights
- Font sizes

#### Glass Row Style (`GlassRowStyle.swift`)
- Padding values
- Chevron size

### 6. Update TVSidebarView
**File:** `Rivulet/Views/TVNavigation/TVSidebarView.swift`

Change from local `fontScale` computed property to using `@Environment(\.uiScale)`.

## Files to Modify

| File | Changes |
|------|---------|
| `Views/Settings/SettingsView.swift` | Move enum out, update picker UI, update AppStorage key |
| `Views/TVNavigation/TVSidebarView.swift` | Use environment instead of local fontScale |
| `Views/Settings/SettingsComponents.swift` | Add scale to all components |
| `Views/Plex/MediaPosterCard.swift` | Scale poster dimensions and fonts |
| `Views/Plex/CastMemberCard.swift` | Scale card dimensions and fonts |
| `Views/Plex/PlexHomeView.swift` | Scale hero and row elements |
| `Views/Plex/PlexLibraryView.swift` | Scale grid and header elements |
| `Views/Player/PostVideo/NextEpisodeCard.swift` | Scale card dimensions |
| `Views/LiveTV/ChannelListView.swift` | Scale grid and fonts |
| `Views/LiveTV/GuideLayoutView.swift` | Scale guide dimensions |
| `Views/Components/GlassRowStyle.swift` | Scale padding and icons |

## Migration
- Old AppStorage key `"sidebarFontSize"` will be orphaned
- New key `"displaySize"` starts fresh at default
- Could add migration code to copy old value, but low priority

## Verification
1. Change Display Size setting to each level (Normal, Large, Extra Large)
2. Verify sidebar scales correctly (existing behavior)
3. Verify Settings view scales (icons, text, toggles, pickers)
4. Verify Plex Home view scales (hero, rows, posters)
5. Verify Library view scales (grid, headers)
6. Verify Live TV views scale
7. Verify player overlays scale
8. Test on Apple TV to ensure nothing clips or overflows at Extra Large
