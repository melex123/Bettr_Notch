# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
swift build                           # Debug build
swift build -c release                # Release build
swift run                             # Run debug build

make clean && make dmg                # Build ad-hoc signed DMG (for local testing)
make dmg SIGNING_IDENTITY="Dev ID..." # Distribution signed DMG
make release                          # DMG + GitHub Release + appcast update
make generate-keys                    # One-time Sparkle EdDSA keypair generation
```

Install locally after building:
```bash
rm -rf /Applications/NotchNook.app && COPYFILE_DISABLE=1 ditto build/NotchNook.app /Applications/NotchNook.app
```

No tests exist. Manual QA only.

## Architecture

**Single-file monolith:** All application code lives in `Sources/notchnook/notchnook.swift` (~3500 lines). Swift 6.2, macOS 14+, single dependency (Sparkle 2.6.0 for auto-updates).

**Key classes/structs (top to bottom):**

| Component | Description |
|-----------|-------------|
| `NotchNookApp` | `@main` App entry, MenuBarExtra |
| `AppDelegate` | Owns `SPUStandardUpdaterController`, cleanup on quit |
| `NotchWindowController` | Singleton — borderless NSWindow, positioning, expand/collapse, hover activation |
| `SettingsWindowController` | Separate NSWindow for settings (480x560) |
| `NotchPreferences` | `ObservableObject` — all user toggles, profiles, UserDefaults persistence |
| `NotchModel` | `ObservableObject` — central app state, timers, async data fetching |
| `NotchRootView` | Root SwiftUI view — ZStack toggling `CollapsedNotch` / `ExpandedNotch` |
| `CollapsedNotch` | Pill-shaped collapsed state (190x32 or 240x32) |
| `ExpandedNotch` | Main panel body (380x460 max) containing all widget views |
| `SettingsView` | Settings UI with profile, toggle, and duration controls |

**All `@MainActor final` classes.** Heavy use of `@MainActor` for AppKit interop.

## Window Architecture

The panel is a borderless, transparent NSWindow at `.statusBar` level. An opaque `CALayer` sits behind the SwiftUI content to prevent macOS compositor transparency near the notch area. This is critical — SwiftUI backgrounds become transparent when overlapping the menu bar/notch, but Core Animation layers do not.

```
NSWindow (borderless, no shadow, .statusBar level)
└── NSView (containerView)
    ├── CALayer (backingLayer) — opaque gray(0.08), cornerRadius 24
    └── NSHostingView → NotchRootView → ZStack → ExpandedNotch/CollapsedNotch
```

NSHostingView bypasses all AppKit-level clipping, so corner radius must be applied via SwiftUI `.clipShape()`.

## Design System

- Panel: 380px wide, max 460px tall, 24pt continuous squircle corners
- Background: `Color(white: 0.08)`, fully opaque (backed by CALayer)
- Widget cards: 16pt corner radius, `white.opacity(0.08)` bg, `0.10` border stroke
- Spacing: 8pt grid — 12pt panel padding, 8pt card gaps, 10pt internal padding
- Typography: SF system font, minimum 10pt, semantic sizing
- Color hierarchy: white at 0.85 (primary), 0.55 (secondary), 0.30 (tertiary)
- No blur/vibrancy, no shadow — fully opaque dark panel

## Versioning & Release

- `VERSION` file is the single source of truth for semver
- Build number auto-derived from `git rev-list --count HEAD`
- Both injected into `dist/Info.plist` at build time via sed
- Sparkle EdDSA public key is hardcoded in `dist/Info.plist`
- Sparkle private key lives in macOS Keychain (used by `sign_update` automatically)
- Release script (`scripts/release.sh`) creates GitHub Release and updates `appcast.xml`
- Remote: `origin https://github.com/melex123/Bettr_Notch.git`

## Important Patterns

- `NotchModel.expanded` defaults to `true` — the panel starts expanded
- Metrics only refresh when panel is expanded AND the specific metric is enabled in preferences
- Timers: stats refresh (1.5s), clipboard poll (0.8s), focus tick (1.0s)
- `COPYFILE_DISABLE=1` is required when using `ditto` to avoid resource fork codesign errors
- `scheduleCollapse()` controls auto-hide — add `return` at its start to disable during testing
- Built-in display is Display 2 for screencapture (`screencapture -x -D 2`)
