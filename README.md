# NotchNook

A macOS utility that transforms your MacBook's notch into a powerful, glanceable command center.

## What is NotchNook?

NotchNook is a floating panel that lives behind your MacBook's notch. Hover over the notch area and it expands into a compact hub packed with useful tools — no need to open full apps for quick tasks.

## Features

**Media Controls** — See what's playing on Spotify, Apple Music, or browser tabs (YouTube). Skip, pause, and control playback without switching apps.

**Focus Timer** — Built-in Pomodoro-style timer with configurable focus and break durations. A live compact indicator stays visible in the collapsed notch while the timer runs.

**Clipboard History** — Automatically captures copied text with pinning, search, and one-click copy-back. Multi-line text is preserved. History persists across sessions.

**File Shelf** — Drag and drop files onto the panel for quick access. Supports multi-file selection and drag-out to other apps using a native AppKit drag system.

**Mini Calendar** — Shows upcoming Reminders for the next 3 days, integrated via EventKit.

**System Metrics** — Glanceable CPU, RAM, GPU, battery, network speed, and weather tiles — only refreshed when visible to stay lightweight.

**Profiles** — Switch between Work, Gaming, and Meeting presets to show only the modules you need. Optional auto-switching based on active app.

## Requirements

- macOS 14+ (Sonoma)
- MacBook with notch display (also works on notchless screens as a top-bar panel)
- Swift 6.2

## Build & Run

```bash
swift build
swift run
```

No third-party dependencies — only Apple frameworks (AppKit, SwiftUI, Combine, EventKit, IOKit).

## How It Works

- The panel stays hidden behind the physical notch in its collapsed state
- Hovering over the notch activation zone expands the panel
- The panel automatically pins to the built-in MacBook display, even with external monitors connected
- Moving the mouse away collapses it back behind the notch

## Permissions

NotchNook may request the following permissions:

- **Accessibility** — for media key simulation
- **Automation** — for controlling Spotify, Music, and reading browser tabs
- **Reminders** — for the mini calendar feature

## Project Structure

```
Package.swift                          # Swift Package Manager config
Sources/notchnook/notchnook.swift      # Main application source
index.html + styles.css                # Landing page (not part of the app)
```

## License

All rights reserved.
