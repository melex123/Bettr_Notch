# NotchNook - AI Handoff Documentation + PRD

## 1. Purpose Of This Document

This file is a full technical and product handoff for the current state of the `notchnook` project, designed so another AI agent (or engineer) can quickly:

- understand architecture and runtime behavior,
- identify where each feature is implemented,
- continue development safely,
- diagnose known regressions,
- plan product improvements with clear requirements.

This document intentionally includes both:

- **implementation-level technical details** (code architecture, key flows, data model, services, constraints),
- **PRD-level details** (goals, requirements, acceptance criteria, roadmap).

---

## 2. Project Snapshot

- Project name: `notchnook`
- Platform: `macOS 14+`
- Language: Swift 6.2
- App type: menu bar utility + floating borderless notch panel (SwiftUI + AppKit)
- Build system: Swift Package Manager
- Main source file: `/Users/erikbartos/Desktop/Developer/notchnook/Sources/notchnook/notchnook.swift`
- Current architecture style: **single-file monolith** (all core logic in one Swift file)

### Repository Layout

```
/Users/erikbartos/Desktop/Developer/notchnook
  Package.swift
  Makefile                                  # DMG build orchestration
  VERSION                                   # Semver version (single source of truth)
  Sources/notchnook/notchnook.swift
  dist/
    Info.plist                              # App bundle metadata template
    NotchNook.entitlements                  # Production entitlements
    PkgInfo                                 # Bundle marker (APPL????)
  scripts/
    create-icns.sh                          # Generates placeholder .icns icon
    create-dmg.sh                           # Creates compressed DMG with hdiutil
  AI_PROJECT_DOCUMENTATION.md
  README.md
  .claude/launch.json
  .claude/agents/ui-smoothness-tuner.md
  .claude/settings.local.json
  .agents/skills/apple-hig-designer/       # Apple HIG design skill reference
  design/                                   # Design reference images
  index.html
  styles.css
  .build/...                                # SPM build artifacts
  build/...                                 # Makefile output (.app, .dmg)
```

Notes:

- `index.html` and `styles.css` exist but are not part of the macOS app runtime.
- `.claude/launch.json` contains dev server configuration for `swift run`.
- `.claude/agents/ui-smoothness-tuner.md` configures the UI smoothness review agent with Apple HIG knowledge.
- `.agents/skills/apple-hig-designer/` contains the Apple Human Interface Guidelines design skill (typography, colors, spacing, components, accessibility).
- `design/` contains reference screenshots of the NotchNook UI for design direction.
- Core app behavior lives almost entirely in `notchnook.swift` (~33k lines).
- `build/` directory is gitignored — contains Makefile output artifacts (.app bundle, .dmg, staging).

---

## 3. Build / Run / Tooling

## Build

```bash
swift build            # Debug build (development)
swift build -c release # Release build (optimized)
```

## Run

```bash
swift run
```

## Distribution (DMG)

```bash
make dmg                              # Ad-hoc signed DMG (personal use)
make dmg SIGNING_IDENTITY="Dev ID..." # Distribution signed DMG (notarization-ready)
make bundle                           # Just build .app bundle (no DMG)
make clean                            # Remove build/ artifacts
make help                             # Show all targets
```

The `make dmg` pipeline:
1. `swift build -c release` — compile optimized binary
2. `scripts/create-icns.sh` — generate app icon (.icns) using Swift + AppKit
3. Assemble `.app` bundle (binary, Info.plist with version substitution, icon, PkgInfo)
4. Code-sign with hardened runtime + entitlements
5. `scripts/create-dmg.sh` — create compressed UDZO DMG with Applications symlink

Output: `build/NotchNook-{version}.dmg` (~2 MB)

### Versioning

- `VERSION` file at project root is the single source of truth (e.g., `1.0.0`)
- Build number auto-derived from `git rev-list --count HEAD`
- Both injected into `Info.plist` at bundle time via `sed`

### Code Signing

| Mode | Command | Identity | Use Case |
|------|---------|----------|----------|
| Ad-hoc | `make dmg` | `-` (default) | Local/personal use |
| Distribution | `make dmg SIGNING_IDENTITY="..."` | Developer ID cert | Public distribution |

Both modes use `--options runtime` (hardened runtime) and `dist/NotchNook.entitlements`.

### Entitlements (`dist/NotchNook.entitlements`)

- `com.apple.security.automation.apple-events` — for AppleScript media/volume control
- Not sandboxed (app uses private frameworks, CGEvent, IOKit)
- No `get-task-allow` (debug-only, excluded from production)

### Info.plist (`dist/Info.plist`)

- `LSUIElement: true` — agent app (no Dock icon)
- `NSCalendarsUsageDescription` — EventKit calendar access
- `NSRemindersUsageDescription` — EventKit reminders access
- `NSAppleEventsUsageDescription` — AppleScript media controls

## Minimum platform

- Defined in `Package.swift`: `.macOS(.v14)`

## Dependencies

- No third-party package dependencies.
- Uses Apple frameworks:
  - `AppKit`, `SwiftUI`, `Combine`,
  - `IOKit`, `IOKit.ps`,
  - `EventKit`,
  - `CoreGraphics`, `QuartzCore`,
  - low-level `Darwin` APIs.

---

## 4. High-Level Product Behavior

NotchNook is a floating notch companion panel for MacBook displays with notch support:

- hidden/collapsed by default near notch trigger zone,
- expands when mouse enters a specific top-center activation area (`200x15`),
- can show configurable modules:
  - media controls + now playing,
  - focus timer,
  - clipboard history,
  - mini calendar (Reminders),
  - file shelf with drag/drop support.
- pinned to built-in MacBook display when external monitors are connected.

---

## 5. Runtime Architecture

### Main app entry

- `NotchNookApp` (`@main`) creates `MenuBarExtra` with actions:
  - Toggle Notch
  - Move to MacBook Screen
  - Settings
  - Quit

### App lifecycle

- `AppDelegate.applicationDidFinishLaunching`:
  - sets app policy `.accessory`,
  - initializes notch window controller and hover monitoring.
- `AppDelegate.applicationWillTerminate`:
  - calls `NotchWindowController.shared.cleanup()` for resource cleanup.

### Core controllers

1. `NotchWindowController`
   - creates/manages floating borderless `NSWindow`,
   - handles positioning, show/hide, expand/collapse animation,
   - hover activation / delayed collapse,
   - display selection and notch anchoring,
   - has `cleanup()` method for proper resource teardown on app quit.

2. `SettingsWindowController`
   - manages separate settings window (`480x560`).

3. `NotchModel` (ObservableObject)
   - central app state (UI state + data + timers + side effects),
   - refreshes system/media/weather/network/calendar/clipboard data,
   - persists shelf and clipboard state,
   - handles focus timer logic,
   - has `cleanup()` method for timer/observer teardown,
   - **system metrics only refresh when panel is expanded and respective metric is enabled** (optimization).

4. `NotchPreferences` (ObservableObject)
   - all user toggles + profile system,
   - persisted in `UserDefaults`,
   - supports profile defaults for work/gaming/meeting.

---

## 6. Window / Notch Positioning Details

The panel is positioned by `NotchWindowController`:

- target screen: built-in display preferred (especially notched one),
- notch anchor:
  - if notch exists: use physical top `screen.frame.maxY`,
  - otherwise use visible frame + safe area heuristics,
- frame is clamped to target screen bounds to avoid spilling onto external monitor,
- activation zone:
  - width: `200`
  - height: `15`
  - centered over notch area.

### Important behavior constraints

- Hover timer ticks every `0.08s`.
- Collapse delay: `0.2s`.
- While mouse button is pressed (dragging), panel avoids immediate collapse.
- Hover tolerance: `8pt` around window frame (extracted to `hoverTolerance` constant).

---

## 7. Data Model And Persistence

## Primary published state (`NotchModel`)

- UI state:
  - `expanded`
  - `actionFeedback`
- File shelf:
  - `droppedFiles: [URL]`
  - `selectedShelfFiles: Set<URL>`
- Clipboard:
  - `clipboardEntries: [ClipboardEntry]`
  - `pinnedClipboardIDs: Set<UUID>`
- Calendar:
  - `reminderItems`
  - `reminderStatusText`
  - `currentDayText`
- Focus:
  - `focusPhase`
  - `focusRemainingSeconds`
- Telemetry fields:
  - CPU, RAM, GPU, battery, weather, now playing, network, ping, vpn text values

## Persistence keys

From `NotchPreferences.Keys` and model constants:

- `notchnook.fileShelf.paths`
- `notchnook.clipboard.entries`
- `notchnook.clipboard.pinned`
- preference keys:
  - `notchnook.settings.showSystemMetrics`
  - `notchnook.settings.showBattery`
  - `notchnook.settings.showCPU`
  - `notchnook.settings.showRAM`
  - `notchnook.settings.showGPU`
  - `notchnook.settings.showWeather`
  - `notchnook.settings.showMediaNowPlaying`
  - `notchnook.settings.showNetworkTiles`
  - `notchnook.settings.showMuteAction`
  - `notchnook.settings.showFilePasteAction`
  - `notchnook.settings.showFileShelf`
  - `notchnook.settings.showClipboardHistory`
  - `notchnook.settings.showMiniCalendar`
  - `notchnook.settings.showFocusTimer`
  - `notchnook.settings.focusMinutes`
  - `notchnook.settings.breakMinutes`
  - `notchnook.settings.selectedProfile`
  - `notchnook.settings.autoProfileByActiveApp`

---

## 8. Timers And Refresh Cadence

`NotchModel` scheduling:

- general stats timer: every `1.5s`
- clipboard polling: every `0.8s`
- focus timer tick: every `1.0s` while active

Refresh strategy:

- now playing: at most every `2.5s`
- weather: every `600s`
- calendar reminders: every `300s`
- ping: every `8s`

Optimization: System metrics (CPU/RAM/GPU/Battery) only compute when panel is expanded AND the respective metric is enabled in preferences.

---

## 9. UI Composition

Main SwiftUI tree:

- `NotchRootView`
  - `CollapsedNotch`
  - `ExpandedNotch`

Expanded sections (conditional via preferences):

1. Header row (notch-aware split layout):
   - Top: action buttons (mute, file paste) on left, settings gear on right, **nothing in center** (notch area)
   - Bottom: system metrics row (battery, CPU, RAM, GPU, weather) — below the notch, toggleable via `showSystemMetrics`
2. Now playing strip (with 48x48 artwork, progress bar, media controls)
3. Focus timer card
4. Clipboard history card (with section header)
5. Mini calendar card
6. File shelf card
7. Temporary feedback label

### Design System

- **Panel**: 380px wide, max 460px tall, 24pt continuous squircle corners, `.ultraThinMaterial` background with dark tint
- **Widget cards**: 16pt continuous corners, `white.opacity(0.08)` background, `0.10` opacity border, 0.5pt stroke
- **Buttons**: 8pt continuous corners, 24-28pt touch targets
- **Spacing**: 8pt grid throughout (12pt panel padding, 8pt inter-card spacing, 10pt card internal padding)
- **Typography**: SF system font, minimum 10pt, semantic sizing
- **Colors**: white opacity hierarchy for text (0.85 primary, 0.55 secondary, 0.30 tertiary), cyan accent for focus timer

Current compact sizing:

- expanded window: width `380`, max height `460` (dynamic by enabled modules),
- collapsed sizes:
  - default `190x32`,
  - with live focus widget `240x32`.

---

## 10. Feature Inventory (Current State)

## A. Notch activation behavior

- Triggered only near notch zone (`200x15`).
- Keeps alive while interacting in panel.
- Designed for MacBook screen even with external monitors.

## B. Settings window

Contains:

- Profiles
  - work / gaming / meeting
  - optional auto profile by active app
- Quick actions toggles
  - now playing + media controls
  - mute
  - file paste
- System Status toggles
  - master toggle: `showSystemMetrics` (enables/disables all metrics at once)
  - individual toggles: Battery, CPU, RAM, GPU, Weather
  - individual toggles disabled when master is off
- Panel toggles
  - file shelf
  - clipboard history
  - mini calendar
  - focus timer
  - focus/break duration steppers
- Apply profile + reset defaults actions

## C. Focus timer

- focus/break cycle
- pause/resume
- skip/reset
- live compact widget shown in collapsed notch when running

## D. Clipboard history

- text capture from system pasteboard
- normalization (preserves newlines, collapses consecutive spaces) + deduplication
- pin/unpin favorites
- copy entry back to clipboard
- remove entry
- persisted history

## E. Mini calendar (Reminders)

- EventKit reminders permission flow
- fetches incomplete reminders for next 3 days
- shows up to 4 reminders with due times

## F. File shelf

- on-drop import of file URLs
- persistent file list
- select all / clear selection
- open file
- remove file
- **unified AppKit drag system** for both single and multi-file drag-out
  - uses `DragGesture` + `beginDraggingSession` (no `.onDrag`)
  - drag state tracked by `FileShelfDraggingSource.isDragging`
  - automatic reset via `draggingSession(_:endedAt:operation:)` delegate
  - file existence validated before drag

## G. Media

- now playing extraction chain:
  1. Spotify AppleScript (name)
  2. Spotify AppleScript (bundle id)
  3. Music AppleScript (name)
  4. Music AppleScript (bundle id)
  5. YouTube tab title from Brave/Chrome/Safari
  6. MediaRemote private framework fallback (0.3s timeout)
- media control actions:
  - previous/play-pause/next via synthetic media key events
  - mute toggle via AppleScript

## H. System/network/weather metrics

- CPU/RAM/GPU/battery/weather/network values are collected in model.
- **Metrics only refresh when panel is expanded and respective metric is enabled in settings** (optimized).
- Network initial sample shows "0 B/s" instead of "--".

---

## 11. External Integrations And Permissions

## Required / optional permissions

- Accessibility/Input Monitoring may be relevant for synthetic media key behavior.
- Automation permissions for controlling:
  - Spotify
  - Music
  - browser apps for tab/title reading
- Reminders permission for mini calendar.

## Network access

- Weather: `https://wttr.in/?format=j1`
- Ping command uses `/sbin/ping` locally.

## Use of private framework

- `MediaRemote` dynamic loading is used as fallback for now-playing detection (0.3s timeout).
- This can be fragile across macOS versions and may affect distribution policies.

---

## 12. Known Issues / Technical Risks

## 12.1 File shelf drag (RESOLVED)

Previous issue: `.onDrag` (SwiftUI) and custom AppKit `beginDraggingSession` (via `.simultaneousGesture`) conflicted, causing unreliable drag behavior.

Resolution (applied):
- Removed `.onDrag` entirely
- Unified to single AppKit drag system via `DragGesture` + `beginDraggingSession`
- Drag state tracked by `FileShelfDraggingSource.isDragging` with auto-reset via delegate
- File existence validated before drag initiation
- Removed `startedExternalDrag` @State flag (was getting stuck)

## 12.2 Monolithic code structure

- Entire app in one file (~3000 lines) increases coupling and regression risk.

## 12.3 Private APIs

- MediaRemote fallback uses private framework symbols loaded dynamically.

## 12.4 Background work optimization (RESOLVED)

Previous issue: CPU/network/weather refresh still ran despite metrics UI being hidden.

Resolution (applied):
- System metrics (CPU/RAM/GPU/Battery) now only refresh when panel is expanded AND the specific metric is enabled in preferences.
- Weather/calendar/network/media already had their own preference guards.

## 12.5 Resource cleanup (RESOLVED)

Previous issue: No cleanup for timers, observers, and async tasks.

Resolution (applied):
- Added `cleanup()` methods to `NotchWindowController` and `NotchModel`
- `AppDelegate.applicationWillTerminate` calls cleanup
- Timer invalidation, observer removal, task cancellation all handled

## 12.6 Clipboard normalization (RESOLVED)

Previous issue: `normalizeClipboardText` collapsed all whitespace including newlines into single space.

Resolution (applied):
- Regex changed from `\\s+` to `[^\\S\\r\\n]+` to preserve newlines while collapsing spaces.

---

## 13. Suggested Refactor Plan (For Next AI)

## Phase 1 - Current priorities

1. Fix animation smoothness (choppy expand/collapse transitions).
2. Verify and fix file drag-out in real usage.
3. Fix collapsed panel positioning to be precisely behind physical notch.
4. Add live activity-style focus timer display near notch when collapsed.

## Phase 2 - Split modules

Recommended file decomposition:

- `App/NotchNookApp.swift`
- `Window/NotchWindowController.swift`
- `Settings/NotchPreferences.swift`
- `Model/NotchModel.swift`
- `Views/` (one file per major view)
- `Services/`:
  - media
  - clipboard
  - reminders
  - weather
  - system metrics
  - network

## Phase 3 - Add verification harness

- unit tests for pure logic:
  - profile application,
  - focus timer transitions,
  - clipboard normalization/dedup,
  - size computation.
- manual test checklist for interaction-heavy features.

---

## 14. Manual QA Checklist

## Notch behavior

- panel appears only on built-in screen,
- activation only at notch zone,
- no ghost appearance on external display when stacked above,
- collapsed panel hidden precisely behind physical notch.

## Media

- Spotify playback displayed while app in background,
- Brave YouTube title displayed,
- media controls affect active player.

## Focus

- start/pause/resume/reset/skip all valid,
- collapsed live focus widget visible when running.

## Clipboard

- new copied text appears,
- multi-line text preserves line breaks,
- pin/unpin persists after restart,
- copy action writes back to pasteboard.

## File shelf

- drop multiple files in,
- select all/clear works,
- single-file drag-out works,
- multi-selected drag-out should move all selected files,
- drag of deleted files is gracefully handled.

## Settings

- toggles persist after restart,
- profile apply/reset behaves as expected.

---

## 15. PRD (Product Requirements Document)

## 15.1 Product Name

NotchNook (macOS notch utility panel)

## 15.2 Problem Statement

Mac users with notch displays want a fast, glanceable, low-friction utility surface directly at the notch area for media control, quick info, and micro productivity tools, without opening full apps.

## 15.3 Target Users

- power users with multiple workflows (work/gaming/meeting),
- creators/devs managing media + files + reminders simultaneously,
- users with external monitor setups who still want notch-centric interactions on MacBook display.

## 15.4 Product Goals

1. Fast access: panel appears instantly near notch.
2. Low visual noise: compact UI with user-customizable modules.
3. Utility density: media + focus + clipboard + reminders + files in one place.
4. Reliability across multi-monitor setups.

## 15.5 Non-Goals

- replacing full task/reminder/file-manager apps,
- cloud sync / accounts (for now),
- cross-platform support (for now).

## 15.6 Functional Requirements

1. Panel positioning and activation
   - Must remain on built-in screen.
   - Must trigger only in notch activation area.
   - Collapsed state must be hidden behind physical notch.
2. Module customization
   - User can toggle modules/actions from settings.
3. Media
   - Show now-playing text for Spotify/Music/browser media.
   - Provide prev/play-next controls.
4. Focus timer
   - Configurable focus and break durations.
   - Live compact indicator in collapsed state.
5. Clipboard
   - history, pinning, copy-back, removal, persistence.
   - Multi-line text preserved.
6. File shelf
   - drag-in file import,
   - persistent list + multi-select,
   - drag-out single and multi-select (unified AppKit drag system).
7. Calendar/reminders
   - upcoming reminders with permission flow.

## 15.7 Non-Functional Requirements

- Startup should feel immediate (<1s perceived).
- Expand/collapse interaction should be smooth (animated at 60fps).
- Background polling must remain lightweight.
- Fallback paths for media detection must degrade gracefully.

## 15.8 UX Requirements

- Compact dark panel, minimal visual clutter.
- Clear module headings and short action labels.
- Feedback messages for user actions (e.g., copied from history).

## 15.9 Metrics (Suggested)

- daily active users (local telemetry opt-in),
- frequency of panel expansion,
- module usage counts,
- media detection success rate,
- drag-out success/failure rate.

## 15.10 Milestones

### M1 - Stability baseline (DONE)

- Fix drag-out reliability (single + multi) - DONE,
- harden notch positioning and hover behavior - DONE,
- fix animation smoothness - DONE.

### M1.5 - Design overhaul (DONE)

- Apple HIG-compliant redesign - DONE,
- material vibrancy panel background - DONE,
- box-style widget cards with visible borders - DONE,
- notch-aware header layout (no content behind physical notch) - DONE,
- system metrics toggle in settings - DONE,
- 8pt grid spacing system - DONE,
- proper touch targets (24-28pt minimum) - DONE,
- typography audit (minimum 10pt) - DONE.

### M1.7 - DMG Distribution Build (DONE)

- Makefile-based build pipeline (`make dmg`) - DONE,
- App bundle (.app) assembly with Info.plist, entitlements, icon - DONE,
- Code signing (ad-hoc + distribution modes) with hardened runtime - DONE,
- Compressed DMG creation with Applications symlink - DONE,
- Placeholder icon generation via Swift + AppKit - DONE,
- Version management via `VERSION` file + git build numbers - DONE.

### M2 - Architecture cleanup

- split monolith into modules,
- add tests for logic-heavy components.

### M3 - Product polish

- add diagnostics switch in settings,
- improve onboarding for permissions.

---

## 16. Immediate Next Tasks

1. Refactor to multi-file architecture (at least controllers/services separation).
2. Add unit tests for pure logic (profiles, focus timer, clipboard, size computation).
3. Improve onboarding UX for permissions (Accessibility, Automation, Reminders).
4. Consider adding keyboard shortcuts for panel toggle and common actions.

---

## 17. Quick Code Pointers

- App entry + menu bar: `notchnook.swift` top section (`NotchNookApp`)
- App lifecycle cleanup: `AppDelegate.applicationWillTerminate`
- Window behavior: `NotchWindowController` (with `cleanup()`)
- Preferences + profiles: `NotchPreferences`
- Runtime state and timers: `NotchModel` (with `cleanup()`)
- Expanded UI cards: `ExpandedNotch` and subviews
- File shelf drag/drop: `FileShelfView`
  - Drag system: `FileShelfDraggingSource` (tracks `isDragging` state)
  - Drop decoder: `FileDropDecoder`
- Media detection + control:
  - `NowPlayingService`
  - `MediaRemoteNowPlayingFallback` (0.3s timeout)
  - `MediaController`
- System services:
  - `BatteryStats`, `MemoryStats`, `GPUStats`
  - `NetworkSampler`, `PingService`, `WeatherService`

---

## 18. Change Log

### 2025-02-22 - Bug Fix Session

**Critical fixes (file shelf drag):**
- Removed `.onDrag` modifier (conflicted with AppKit drag)
- Unified to single AppKit drag system via `DragGesture` + `beginDraggingSession`
- Added `isDragging` state to `FileShelfDraggingSource` with auto-reset via delegate
- Removed `startedExternalDrag` @State flag (was getting stuck after cross-app drags)
- Removed unused `shelfDragProvider` and `shouldUseMultiDrag` functions
- Added file existence validation before drag (`FileManager.default.fileExists`)

**Resource cleanup:**
- Added `cleanup()` to `NotchWindowController` (timers, observers)
- Added `cleanup()` to `NotchModel` (timers, tasks, notification observer)
- Wired cleanup to `AppDelegate.applicationWillTerminate`

**UX improvements:**
- Clipboard normalization preserves newlines (regex `[^\\S\\r\\n]+` instead of `\\s+`)
- System metrics only refresh when panel expanded AND metric enabled
- MediaRemote timeout reduced from 0.8s to 0.3s
- Network initial sample shows "0 B/s" instead of "--"
- Extracted magic number `-8` to `hoverTolerance` constant

### 2026-02-24 - Apple HIG Design Overhaul

**UI redesign (Apple Human Interface Guidelines):**
- Replaced flat `Color.black` panel background with `.ultraThinMaterial` (system vibrancy) + dark tint
- Panel width narrowed from 520 → 380px for compact feel
- Panel corner radius increased to 24pt continuous squircle
- Widget cards: 16pt continuous corners, `white.opacity(0.08)` bg, `0.10` border stroke
- All spacing standardized to 8pt grid (12pt panel padding, 8pt card gaps, 10pt card internal)
- Typography audit: all text raised to minimum 10pt, most elements +2-3pt
- Album artwork: 36x36 → 48x48 with shadow
- Progress bar: 2.5pt → 4pt
- Play/pause button: 32x32 with circle background
- All touch targets raised to minimum 24-28pt
- Collapsed pill: 190x32 with `Color(white: 0.11)` solid background

**Notch-aware header layout:**
- Split header into two rows: actions + settings on top, metrics below
- Top row: action buttons (mute, file paste) on left, settings gear on right, nothing in center where physical notch blocks visibility
- Metrics row: system status indicators displayed below the notch cutout

**System metrics toggle:**
- Added `showSystemMetrics` master preference toggle
- New "System Status" GroupBox in Settings with master toggle + individual metric toggles
- Individual toggles disabled/dimmed when master is off
- Added persistence key: `notchnook.settings.showSystemMetrics`

**Agent & tooling updates:**
- Installed Apple HIG Designer skill (`.agents/skills/apple-hig-designer/`)
- Updated `ui-smoothness-tuner` agent with Apple HIG reference section (typography, colors, spacing, components, accessibility, macOS-specific guidance)
- Added Core Philosophy to agent prompt (less is more, every pixel earns its place, etc.)

**Documentation:**
- Updated README.md with Design section, Settings details, Project Structure, Development Tools
- Updated AI_PROJECT_DOCUMENTATION.md with all changes

### 2026-02-24 - DMG Distribution Build System

**New build pipeline (`make dmg`):**
- Added `Makefile` with targets: `build`, `icon`, `bundle`, `sign`, `dmg`, `clean`, `help`
- Pipeline: SPM release build -> icon generation -> .app assembly -> code signing -> DMG creation
- Output: `build/NotchNook-{version}.dmg` (~2 MB compressed UDZO)

**App bundle infrastructure:**
- `dist/Info.plist`: bundle metadata template with version placeholders, LSUIElement, privacy usage descriptions
- `dist/NotchNook.entitlements`: production entitlements (apple-events only, no sandbox, no get-task-allow)
- `dist/PkgInfo`: standard APPL???? marker

**Icon generation (`scripts/create-icns.sh`):**
- Compiles and runs a Swift program that uses AppKit to render a purple gradient icon with "NN" text
- Generates all 10 required iconset sizes, converts via `iconutil -c icns`
- No third-party tools required

**DMG creation (`scripts/create-dmg.sh`):**
- Creates staging directory with app + /Applications symlink
- Uses `hdiutil create -format UDZO` for compressed read-only DMG
- Optional DMG signing for distribution builds

**Code signing (two modes):**
- Ad-hoc (default): `make dmg` — local/personal use
- Distribution: `make dmg SIGNING_IDENTITY="Developer ID Application: ..."` — notarization-ready
- Both use hardened runtime (`--options runtime`) + production entitlements

**Versioning:**
- `VERSION` file as single source of truth (semver)
- Build number from `git rev-list --count HEAD`
- Both injected into Info.plist at bundle time

**Other:**
- Added `build/` to `.gitignore` for Makefile output directory

---

## 19. Final Notes

- Current implementation is feature-rich but tightly coupled.
- Design is now Apple HIG-compliant with material vibrancy, proper spacing, and notch-aware layout.
- The highest immediate engineering priority is modularization and testability.
- The ui-smoothness-tuner agent now includes Apple HIG knowledge for future design reviews.
