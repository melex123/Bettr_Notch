# Changelog

All notable changes to NotchNook are documented here.

## [1.5.0] — 2026-03-17

### Changed

- **Widget card corner radius** — Reduced from 16pt to 12pt to achieve perceptually concentric radii with the 24pt panel border and 12pt padding. This follows the concentric radius formula: inner radius = outer radius - padding distance.
- **Hit areas** — Increased small button tap targets from 24pt to 28pt in the clipboard history and file shelf widgets, improving reliability for small interactive controls.
- **HoverLiftModifier press scale** — The existing hover-lift modifier now also applies a 0.94 scale-down effect on press via `.onLongPressGesture(minimumDuration: .infinity, pressing:)`, giving tactile press feedback without requiring a custom `ButtonStyle` (which breaks non-key window clicks).

### Added

- **Icon cross-fades** — `.contentTransition(.symbolEffect(.replace))` applied to 7 state-driven SF Symbol icons: play/pause toggle, focus phase indicator, clipboard pin, file shelf checkbox, and focus timer +/- buttons. Icons now cross-fade instead of hard-cutting on state change.
- **Smooth NowPlaying progress bar** — The media progress bar is now driven by `TimelineView(.periodic(from: .now, by: 0.5))` with a linear animation, producing fluid sub-second interpolation instead of stepping every full second.
- **Action feedback animation** — Widget action buttons display a checkmark icon with a scale-in/fade-out transition when an action completes, replacing the previous text-only feedback.
- **Card hover glow** — All 6 widget cards now brighten their border stroke from `white.opacity(0.10)` to `white.opacity(0.18)` on hover, providing clear interactive affordance without motion or blur.
- **Staggered widget entrance** — Widgets animate in with a 40ms cascade delay per widget when the panel expands, using a `.staggerIn()` view modifier extension.

### Security Audit

Session security review result: CLEAN. No CRITICAL or WARNING issues introduced.

Two pre-existing INFO notes (not introduced this session):
- Quick Notes text is stored in UserDefaults (plaintext). Acceptable for current use case.
- Artwork URL sourced from AppleScript is not scheme-validated before use.

---

## [1.4.0] — 2026-02-28

### Added
- **Quick Notes widget** — Persistent multi-line text area backed by UserDefaults. Toggle via Settings > Panels.
- **NotchPanel window subclass** — `NSWindow` subclass with `canBecomeKey = true`, required for TextEditor keyboard input in a borderless `.statusBar` level window.

### Fixed
- **Sparkle version mismatch** — `sparkle:version` in appcast now uses the build number from `git rev-list --count HEAD` instead of the marketing version string. Sparkle compares this field against `CFBundleVersion` (a build number integer); using a semver string caused false "up to date" results.

---

## [1.3.0]

### Added
- **Dedicated Spotify widget** removed; Now Playing unified into a single `NowPlayingStrip` supporting Spotify, Apple Music, and browser YouTube tabs.
- **Menu bar icon** managed by `AppDelegate` via `NSStatusItem`. Removed `MenuBarExtra` to fix app freeze caused by `@ObservedObject` on the App struct.

### Fixed
- **App freeze from AppleScript** — Replaced all `NSAppleScript` usage with `Process("/usr/bin/osascript")` with 2–3s timeouts. Moved now-playing refresh to `Task.detached`.
- **App freeze from MenuBarExtra** — Removed `MenuBarExtra(isInserted:)` entirely.
- **Custom ButtonStyle breaking non-key window clicks** — Switched to `.buttonStyle(.plain)` + `.hoverLift()` modifier for hover feedback.

---

## [1.2.0]

### Fixed
- **Panel transparency at notch** — Added opaque `CALayer` behind `NSHostingView`. Core Animation layers are immune to the macOS compositor transparency effect that affects SwiftUI backgrounds overlapping the menu bar/notch area.
