# NotchNook

A macOS utility that transforms your MacBook's notch into a powerful, glanceable command center.

## What is NotchNook?

NotchNook is a floating panel that lives behind your MacBook's notch. Hover over the notch area and it expands into a compact hub packed with useful tools — no need to open full apps for quick tasks.

## Features

**Media Controls** — See what's playing on Spotify, Apple Music, or browser tabs (YouTube). Skip, pause, and control playback without switching apps. Album artwork, track info, and progress bar at a glance.

**Focus Timer** — Built-in Pomodoro-style timer with configurable focus and break durations. A live compact indicator stays visible in the collapsed notch while the timer runs.

**Clipboard History** — Automatically captures copied text with pinning, search, and one-click copy-back. Multi-line text is preserved. History persists across sessions. Section header for quick identification.

**File Shelf** — Drag and drop files onto the panel for quick access. Supports multi-file selection and drag-out to other apps using a native AppKit drag system.

**Mini Calendar** — Shows upcoming Reminders for the next 3 days, integrated via EventKit.

**System Metrics** — Glanceable CPU, RAM, GPU, battery, and weather indicators. Displayed in a dedicated metrics row below the notch to avoid being hidden by the physical notch cutout. Can be toggled on/off entirely from Settings.

**Profiles** — Switch between Work, Gaming, and Meeting presets to show only the modules you need. Optional auto-switching based on active app.

## Design

The UI follows Apple Human Interface Guidelines with:

- **Material vibrancy** — `.ultraThinMaterial` panel background for system-integrated blur
- **Continuous squircle corners** — 24pt panel, 16pt widget cards, 8pt buttons (`.continuous` style)
- **8-point grid spacing** — all padding and margins on Apple's standard grid
- **Notch-aware header layout** — action buttons on left, settings on right, nothing in the center where the notch blocks visibility. Metrics appear in a second row below the notch
- **Box-style widget cards** — each widget is a distinct card with subtle border and background separation
- **Compact form factor** — 380px wide panel optimized for glanceability
- **HIG typography** — minimum 10pt text, semantic sizing, SF system font
- **Proper touch targets** — minimum 24-28pt for all interactive elements

## Requirements

- macOS 14+ (Sonoma)
- MacBook with notch display (also works on notchless screens as a top-bar panel)
- Swift 6.2

## Build & Run

```bash
swift build
swift run
```

One dependency: [Sparkle 2.x](https://sparkle-project.org/) for auto-updates. Otherwise only Apple frameworks (AppKit, SwiftUI, Combine, EventKit, IOKit).

## How It Works

- The panel stays hidden behind the physical notch in its collapsed state
- Hovering over the notch activation zone expands the panel
- The panel automatically pins to the built-in MacBook display, even with external monitors connected
- Moving the mouse away collapses it back behind the notch

## Settings

Accessible via the gear icon in the panel header:

- **Profiles** — Work, Gaming, Meeting presets with one-click switching
- **Quick Actions** — Toggle Now Playing, Mute Button, File Paste
- **System Status** — Master toggle for system metrics, plus individual toggles for Battery, CPU, RAM, GPU, and Weather
- **Panels** — Toggle File Shelf, Clipboard History, Mini Calendar, Focus Timer with configurable durations

## Permissions

NotchNook may request the following permissions:

- **Accessibility** — for media key simulation
- **Automation** — for controlling Spotify, Music, and reading browser tabs
- **Reminders** — for the mini calendar feature

## Auto-Updates

NotchNook includes built-in auto-updates powered by [Sparkle](https://sparkle-project.org/). Users are notified of new versions directly in the app and can update with one click.

- **Check manually** — Menu bar icon > "Check for Updates..."
- **Automatic checks** — Sparkle checks the appcast feed on launch

See `UPDATE_GUIDE.md` for how to publish a new release.

## Distribution

```bash
make dmg                              # Build ad-hoc signed DMG
make dmg SIGNING_IDENTITY="Dev ID..." # Distribution signed DMG
make release SPARKLE_ED_KEY="..."     # Full release: DMG + GitHub Release + appcast update
make generate-keys                    # One-time: generate Sparkle EdDSA signing keys
make clean                            # Remove build artifacts
```

## Project Structure

```
Package.swift                          # Swift Package Manager config (+ Sparkle dep)
Sources/notchnook/notchnook.swift      # Main application source (monolithic)
appcast.xml                            # Sparkle update feed (auto-updated by release script)
Makefile                               # Build pipeline (dmg, release, generate-keys)
VERSION                                # Semver version (single source of truth)
UPDATE_GUIDE.md                        # Step-by-step release instructions
dist/
  Info.plist                           # App bundle metadata (SUFeedURL, SUPublicEDKey)
  NotchNook.entitlements               # Entitlements (apple-events, network client)
  PkgInfo                              # Bundle marker
scripts/
  create-icns.sh                       # App icon generator
  create-dmg.sh                        # DMG creator
  release.sh                           # Full release automation (GitHub Release + appcast)
index.html + styles.css                # Landing page (not part of the app)
design/                                # Design reference images
.claude/agents/                        # Claude Code agent configurations
.agents/skills/apple-hig-designer/     # Apple HIG design skill reference
```

## Development Tools

- **ui-smoothness-tuner agent** — Automated UI performance reviewer with Apple HIG knowledge. Reviews animations, transitions, spacing, and visual polish against Apple guidelines.
- **Apple HIG Designer skill** — Reference for Apple Human Interface Guidelines (typography, colors, spacing, components, accessibility).

## License

All rights reserved.
