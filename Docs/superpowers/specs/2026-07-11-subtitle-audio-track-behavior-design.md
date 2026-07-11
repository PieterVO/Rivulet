# Subtitle & Audio Track Behavior

**Date:** 2026-07-11
**Baseline:** `main` @ `67834d7`
**Engine:** upstream `superuser404notfound/AetherEngine`, pinned `exactVersion` **5.0.1**. **There is no fork.** Engine-side fixes cannot ship by editing a fork; every fix below is host-side, in Rivulet.

---

## Problems

Three defects, reported together, fixed together.

1. **Duplicate stacked subtitles.** Rewinding while enabling subtitles renders the same line 5x, stacked.
2. **Subtitle memory loses "forced".** Selecting *English (Forced)* on one title auto-selects *English (regular, full)* on the next.
3. **Settings duplicates the player.** `Settings → Playback` has Audio Language and Subtitles pickers that the in-player picker now supersedes.

---

## Part 1 — Duplicate stacked subtitles

### Root cause (verified against the 5.0.1 tag)

The bug is in AetherEngine's overlay-cue drain, and it survives in the shipping 5.0.1.

On a **rewind**, `SubtitleOverlayDrainer.drainPlan` sees the playhead jump and returns:

```swift
if abs(playhead - cursor.lastPlayhead) > jumpThreshold {
    return .resetAndDecode(from: playhead - backscan, through: playhead + lead)
}
```

In `AetherEngine+Subtitles.subtitleDrainTick`, the `.resetAndDecode` branch resets the **decoder** and arms the PGS gate — but it **never clears `subtitleCues`**. Every clear site in 5.0.1 lives in `selectSubtitleTrack`, `clearSubtitle`, the sidecar path, the CC path, and load/stop. **The seek path is not among them.**

So the drain re-decodes a backscan window it has already decoded, and `insertSorted` **appends** the results. `insertCueSorted` replaces an *image* cue sharing a start time — upstream already hit and fixed duplicate-PGS — but its own comment states the text rule explicitly:

> Text cues at the same start are distinct simultaneous speakers and are both kept.

`pruneOldSubtitleCues` cannot clean up either: it drops cues with `endTime < sourceTime - retention`, but a rewind moves `sourceTime` **backward**, leaving every stale copy's `endTime` in the future.

Net: **every rewind across a line re-inserts that line.** "Rewind + enable subs" compounds it, because `selectSubtitleTrack` re-arms the drain on top of the seek.

Reproduced mechanically by executing 5.0.1's own `drainPlan` / `insertCueSorted` / `pruneOldSubtitleCues` logic: one line stacks to 2, then 3 copies from rewinds alone.

**Why upstream's rule fails:** it cannot distinguish *two speakers at once* (same start, **different text** → keep both) from *the same line re-decoded* (same start, **identical text** → keep one). It only ever checks start time, and only for images.

### Fix

Dedupe on **full content identity** — `(startTime, endTime, body)` — in `SubtitleModel.activeCues`
(`Rivulet/Views/Player/Subtitles/SubtitleModel.swift`), which already walks exactly the overlapping-cue window.

- Genuine simultaneous speakers survive (same start, different text).
- Re-decode duplicates collapse (identical triple).
- Bitmap cues compare by identity of the decoded image reference plus position, not pixel content.

This also fixes a latent SwiftUI defect: `EmbeddedSubtitleDecoder.nextCueID` is a **per-instance monotonic counter starting at 0**, so a re-created decoder emits ids that *collide with unrelated older cues*. `ForEach(id: \.id)` in `AetherSubtitleOverlayView` therefore sees duplicate SwiftUI identities. The overlay must key by content identity, not the engine's `id`.

**Accepted limitation.** This is a render-layer fix. The engine's `subtitleCues` array still grows across rewinds (a slow leak, worst for bitmap subs). Not filing upstream (user decision). The visible bug is fully resolved.

### Scope

- `Views/Player/Subtitles/SubtitleModel.swift` — dedupe in `activeCues`.
- `Views/Player/Aether/AetherSubtitleOverlayView.swift` — key `ForEach` by content identity.

---

## Part 2 — Track memory

### Root cause

`SubtitlePreference` (in `UniversalPlayerViewModel.swift`) has **no `isForced` field**:

```swift
init(from track: MediaTrack) {
    self.enabled = true
    self.languageCode = track.languageCode
    self.codec = track.codec
    self.preferHearingImpaired = track.isHearingImpaired
    // track.isForced is SILENTLY DROPPED
}
```

"English (Forced)" persists as merely "English". Next title, `findBestMatch` filters to English tracks and returns the **first** one — the full subtitle track.

### Model

New file `Services/Plex/Playback/TrackIntent.swift`:

```swift
enum SubtitleIntent: Codable, Equatable {
    case off
    case track(language: String, forced: Bool, hearingImpaired: Bool, codec: String?)
}

struct AudioIntent: Codable, Equatable {
    let language: String
    let codec: String?
    let channels: Int?
}
```

Persisted in `UserDefaults` (global, last-write-wins, shared across profiles — matches today's behavior; **not** namespaced per profile).

### Subtitle resolution

Forced is a **distinct intent**, never silently promoted to full subtitles. Forced means "translate the foreign dialogue"; regular means "caption every line". Substituting one for the other is a different product, not a graceful degradation.

| Stored intent | Next title has | Applied |
|---|---|---|
| ENG forced | ENG forced | ENG forced |
| ENG forced | ENG only, no forced | **Off** |
| ENG regular | ENG regular | ENG regular |
| ENG regular | ENG forced only | **Off** |
| Off | anything | Off |

Match order for `.track(language:forced:hearingImpaired:codec:)`:
1. language + forced + hearingImpaired + codec (exact)
2. language + forced + hearingImpaired
3. language + forced
4. **Off** — never cross the forced boundary in either direction.

**Critical rule: applying `Off` as a fallback MUST NOT overwrite the stored intent.** The intent stays "ENG forced" and re-engages on the next title that has a forced English track. Only an explicit user pick writes the intent. This is the user's "won't update to Off" requirement.

### Audio resolution

More lenient, per the user: *exact match (or best audio match) → same language → fallback to English.*

1. **Exact:** language + codec + channels.
2. **Same language, best quality:** rank by channel count desc, then codec tier.
3. **English, best quality:** same ranking.
4. **File default** (`isDefault`), else first track.

Codec tier (high → low): TrueHD / DTS-HD MA → EAC3 / DTS → AC3 → AAC → everything else.

**Commentary / audio-description tracks are excluded from all auto-selection tiers** (2, 3, 4). They remain user-selectable in the picker; they are simply never chosen automatically. If the user explicitly picks one, that is stored as intent and honored by tier 1.

Rationale: today's `AudioPreferenceManager.findBestMatch` is `candidates.max { $0.channels < $1.channels }`, which will auto-select a 5.1 director's commentary over a 5.1 main mix. This is a real latent bug.

**Detection is heuristic.** Plex exposes **no** commentary flag (verified: `PlexStream` has `default`, `forced`, `selected`, `hearingImpaired` — nothing else). The only signal is the title text. Match case-insensitively against `extendedDisplayTitle` / `displayTitle` / `name` for: `commentary`, `director`, `audio description`, `descriptive`, `described`, `narration`. Imperfect, but strictly better than the current blind max-by-channels.

### Preserved tiers

The existing higher-priority tiers in `applyAudioPreference` / `applySubtitlePreference` are kept **above** the global intent, unchanged:
1. Pre-play picker selection (this session) — `initialAudioTrackId` / `initialSubtitleSelection`.
2. Plex's per-item explicit selection (a `selected: true` stream that isn't the file default).
3. → then the global intent (this spec).

### Write sites (all three must persist intent)

1. `selectAudioTrack(id:)`
2. `selectSubtitleTrack(id:)`
3. `selectAetherSubtitleTrackFromNativePicker(aetherTrackId:)` — **easy to miss; it has its own save path.**

`selectSubtitleTrackWithoutSaving` / `selectAudioTrackWithoutSaving` must continue to **not** write intent (auto-selection and the replay-captions window rely on this).

### Scope

- **New:** `Services/Plex/Playback/TrackIntent.swift` (model + resolution + commentary detection + migration).
- `Views/Player/UniversalPlayerViewModel.swift` — delete `SubtitlePreference`, `SubtitlePreferenceManager`, `AudioPreference`, `AudioPreferenceManager`; rewire `applyAudioPreference`, `applySubtitlePreference`, and the three write sites.

---

## Part 3 — Settings removal

The in-player picker is now the only place to change audio/subtitle track selection.

**Delete:**
- `Settings → Playback` rows: `audioLanguage`, `subtitles` (`SettingsPageModels.swift`).
- Picker pages: `audioLanguagePicker`, `subtitlesPicker` (+ their `SettingsPage` enum cases, `title`, and icon mappings).
- Helpers `currentSubtitleOption()` / `applySubtitleOption(_:)`.
- Enums `LanguageOption` and `SubtitleOption` (`SettingsModels.swift`) — **verified used only by these two pickers**.
- `SettingsDescriptors` entries `"audioLanguage"` and `"subtitles"`, plus the `.audioLanguagePicker` / `.subtitlesPicker` icon cases.

**Migration (one-time, on first read of the new intent):**
- `audioPreferenceLanguage` → `AudioIntent(language:codec:nil, channels:nil)`.
- `subtitlePreferenceEnabled` / `...Language` / `...Codec` / `...HearingImpaired` → `SubtitleIntent`. Old data has no forced bit, so migrate as `forced: false` (the old picker could only express a language, never forced).
- Remove the old keys after migrating.

Nobody who set "Spanish" in Settings loses it.

---

## Testing

- **Part 1:** unit-test `SubtitleModel.activeCues` — identical `(start, end, body)` collapses to one; same start + *different text* (simultaneous speakers) keeps both; delay offset still applied.
- **Part 2:** unit-test the resolution ladders against the tables above. Explicitly cover: ENG-forced → no forced track → **Off, intent unchanged**. Commentary track never auto-selected. Migration from each legacy key shape.
- **Part 3:** Settings builds; Playback page renders without the two rows; no orphaned symbol references.
- Build for tvOS simulator; device-verify the rewind + enable-subs repro.

---

## Out of scope

- Filing the engine bug upstream (explicit user decision).
- Per-show or per-profile track memory (global, last-write-wins).
- Fixing the engine's unbounded `subtitleCues` growth across rewinds (render-layer fix accepted).
