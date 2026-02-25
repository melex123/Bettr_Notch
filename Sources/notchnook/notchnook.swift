import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Combine
import CoreGraphics
import IOKit
import IOKit.ps
import EventKit
import Darwin.Mach
import Darwin
import QuartzCore
import Sparkle
import ServiceManagement

@main
struct NotchNookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

enum NotchProfile: String, CaseIterable, Identifiable {
    case work
    case gaming
    case meeting

    var id: String { rawValue }

    var label: String {
        switch self {
        case .work:
            return "Work"
        case .gaming:
            return "Gaming"
        case .meeting:
            return "Meeting"
        }
    }
}

enum FocusPhase {
    case idle
    case focus
    case breakTime
    case pausedFocus
    case pausedBreak

    var isRunning: Bool {
        self == .focus || self == .breakTime
    }

    var isPaused: Bool {
        self == .pausedFocus || self == .pausedBreak
    }
}

struct ReminderItem: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let dueText: String
}

struct ClipboardEntry: Identifiable, Hashable, Codable {
    let id: UUID
    let value: String
    let timestamp: Date
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var sharedUpdater: SPUStandardUpdaterController?

    let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private var statusItem: NSStatusItem?
    private var menuBarIconCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.sharedUpdater = updaterController
        NSApplication.shared.setActivationPolicy(.accessory)
        NotchWindowController.shared.show()

        // Set up menu bar icon based on preference
        let prefs = NotchPreferences.shared
        if prefs.showMenuBarIcon {
            createStatusItem()
        }
        menuBarIconCancellable = prefs.$showMenuBarIcon
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] show in
                if show {
                    self?.createStatusItem()
                } else {
                    self?.removeStatusItem()
                }
            }

        let hasAskedKey = "notchnook.hasAskedAutoStart"
        if !UserDefaults.standard.bool(forKey: hasAskedKey) {
            UserDefaults.standard.set(true, forKey: hasAskedKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let alert = NSAlert()
                alert.messageText = "Launch NotchNook at Login?"
                alert.informativeText = "Would you like NotchNook to start automatically when you log in?"
                alert.addButton(withTitle: "Enable")
                alert.addButton(withTitle: "Not Now")
                alert.alertStyle = .informational
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    NotchPreferences.shared.launchAtLogin = true
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarIconCancellable?.cancel()
        menuBarIconCancellable = nil
        NotchWindowController.shared.cleanup()
    }

    private func createStatusItem() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "macwindow.badge.plus", accessibilityDescription: "NotchNook")
        }

        let menu = NSMenu()
        menu.addItem(withTitle: "Toggle Notch", action: #selector(toggleNotch), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Move to MacBook Screen", action: #selector(moveToBuiltIn), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: "Settings", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        menu.addItem(withTitle: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit NotchNook", action: #selector(quitApp), keyEquivalent: "q")
            .target = self

        item.menu = menu
        statusItem = item
    }

    private func removeStatusItem() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    @objc private func toggleNotch() {
        NotchWindowController.shared.toggleExpanded()
    }

    @objc private func moveToBuiltIn() {
        NotchWindowController.shared.reposition()
    }

    @objc private func openSettings() {
        SettingsPresenter.open()
    }

    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}

enum SettingsPresenter {
    @MainActor
    static func open() {
        SettingsWindowController.shared.show()
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private init() {}

    func show() {
        if window == nil {
            createWindow()
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func createWindow() {
        let rootView = SettingsView()
            .frame(width: 500, height: 640)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 640),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "NotchNook Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: rootView)

        self.window = window
    }
}

@MainActor
final class NotchWindowController {
    static let shared = NotchWindowController()

    private var window: NSWindow?
    private let model = NotchModel()
    private let frameAnimationDuration: TimeInterval = 0.36
    private let visibilityAnimationDuration: TimeInterval = 0.2
    private let collapsedTopOverlap: CGFloat = 20
    private let expandedTopOverlap: CGFloat = 10
    private let activationZoneWidth: CGFloat = 200
    private let activationZoneHeight: CGFloat = 15
    private var hoverTimer: Timer?
    private var pendingCollapse: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?
    private var preferencesCancellable: AnyCancellable?

    private let hoverTolerance: CGFloat = 8

    private var modelCancellable: AnyCancellable?
    private var lastLiveWidgetState = false

    private init() {
        preferencesCancellable = NotchPreferences.shared.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                self?.resizeWindow(animated: true)
            }
        }
        // Observe model changes to show/reposition for live widgets (focus, now playing)
        modelCancellable = model.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let hasWidget = self.hasLiveCollapsedWidget
                if hasWidget != self.lastLiveWidgetState {
                    self.lastLiveWidgetState = hasWidget
                    if hasWidget && !self.model.expanded {
                        // Live widget appeared - show the pill below notch
                        self.showWindow(animated: true)
                        self.resizeWindow(animated: true)
                    } else if !hasWidget && !self.model.expanded {
                        // All live widgets gone while collapsed - hide the window
                        self.resizeWindow(animated: true)
                        DispatchQueue.main.asyncAfter(deadline: .now() + self.frameAnimationDuration + 0.05) { [weak self] in
                            guard let self, !self.model.expanded, !self.hasLiveCollapsedWidget else { return }
                            self.window?.orderOut(nil)
                        }
                    } else {
                        self.resizeWindow(animated: true)
                    }
                }
            }
        }
    }

    func cleanup() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        pendingCollapse?.cancel()
        pendingCollapse = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
    }

    /// The content view for drag session source operations.
    var dragSourceView: NSView? { window?.contentView }

    func show() {
        if window == nil {
            createWindow()
        }
        startHoverMonitoring()
        watchScreenChanges()
        reposition()
        window?.orderOut(nil)
    }

    func toggleExpanded() {
        showWindow(animated: true)
        setExpanded(!model.expanded)
    }

    func setExpanded(_ expanded: Bool) {
        guard model.expanded != expanded else { return }

        if expanded {
            showWindow(animated: true)
        }
        withAnimation(NotchModel.transitionAnimation) {
            model.expanded = expanded
        }
        resizeWindow(animated: true)

        // After collapse: hide window unless a live widget is active (focus or now playing)
        if !expanded, !hasLiveCollapsedWidget {
            DispatchQueue.main.asyncAfter(deadline: .now() + frameAnimationDuration + 0.05) { [weak self] in
                guard let self, !self.model.expanded else { return }
                self.window?.orderOut(nil)
            }
        }
    }

    func reposition() {
        applyFrame(for: model.currentSize, animated: false)
    }

    private func createWindow() {
        let size = model.currentSize
        let content = NotchRootView(model: model)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        // Container with opaque backing layer to resist menu-bar compositor transparency
        let containerView = NSView(frame: NSRect(origin: .zero, size: size))
        containerView.wantsLayer = true
        containerView.autoresizesSubviews = true

        let backingLayer = CALayer()
        backingLayer.backgroundColor = CGColor(gray: 0.08, alpha: 1.0)
        backingLayer.cornerRadius = 24
        backingLayer.cornerCurve = .continuous
        backingLayer.frame = CGRect(origin: .zero, size: size)
        backingLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        containerView.layer?.addSublayer(backingLayer)

        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(origin: .zero, size: size)
        hostingView.autoresizingMask = [.width, .height]
        containerView.addSubview(hostingView)

        window.contentView = containerView

        self.window = window
    }

    private func resizeWindow(animated: Bool) {
        applyFrame(for: model.currentSize, animated: animated)
    }

    private func applyFrame(for size: NSSize, animated: Bool) {
        guard let window else { return }
        guard let screen = preferredNotchScreen() ?? NSScreen.main else { return }

        let frame = frameForNotch(size: size, on: screen)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = frameAnimationDuration
                context.timingFunction = CAMediaTimingFunction(
                    controlPoints: 0.2, 0.9, 0.3, 1.0
                )
                context.allowsImplicitAnimation = true
                window.animator().setFrame(frame, display: true)
            }
        } else {
            window.setFrame(frame, display: true)
        }
    }

    private func frameForNotch(size: NSSize, on screen: NSScreen) -> NSRect {
        let anchorY = notchAnchorY(for: screen)
        let overlap = topOverlap(for: size, on: screen)
        let frame = screen.frame
        let centeredX = frame.midX - size.width / 2
        let centeredY = anchorY - size.height + overlap

        let maxX = frame.maxX - size.width
        let maxY = frame.maxY - size.height

        let x: CGFloat
        if frame.minX <= maxX {
            x = min(max(centeredX, frame.minX), maxX)
        } else {
            x = centeredX
        }

        let y: CGFloat
        if frame.minY <= maxY {
            y = min(max(centeredY, frame.minY), maxY)
        } else {
            y = centeredY
        }

        return NSRect(
            x: x,
            y: y,
            width: size.width,
            height: size.height
        )
    }

    private var hasLiveCollapsedWidget: Bool {
        model.hasLiveFocusWidget
    }

    private func topOverlap(for size: NSSize, on screen: NSScreen) -> CGFloat {
        if hasHardwareNotch(on: screen) {
            let isCollapsed = size.height <= 44
            if isCollapsed {
                if hasLiveCollapsedWidget {
                    // Live widget active: position just below the notch (Dynamic Island style)
                    let notchHeight = screen.safeAreaInsets.top
                    return -(notchHeight + 2)
                }
                // Normal collapsed: at notch level (hidden by orderOut when not needed)
                return 0
            }
            // Expanded: top at screen.frame.maxY, content visible below notch
            return 0
        }
        return size.height <= 44 ? collapsedTopOverlap : expandedTopOverlap
    }

    private func notchAnchorY(for screen: NSScreen) -> CGFloat {
        if hasHardwareNotch(on: screen) {
            return screen.frame.maxY
        }

        var anchors: [CGFloat] = [screen.visibleFrame.maxY]

        if screen.safeAreaInsets.top > 0 {
            anchors.append(screen.frame.maxY - screen.safeAreaInsets.top)
        }

        if
            let leftArea = screen.auxiliaryTopLeftArea,
            let rightArea = screen.auxiliaryTopRightArea,
            !leftArea.isEmpty,
            !rightArea.isEmpty
        {
            anchors.append(min(leftArea.minY, rightArea.minY))
        }

        return anchors.max() ?? screen.visibleFrame.maxY
    }

    private func startHoverMonitoring() {
        guard hoverTimer == nil else { return }

        let timer = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateHoverState()
            }
        }
        hoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func watchScreenChanges() {
        guard screenObserver == nil else { return }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reposition()
            }
        }
    }

    private func updateHoverState() {
        guard let window else { return }
        guard let screen = preferredNotchScreen() ?? NSScreen.main else { return }

        let mouse = NSEvent.mouseLocation
        guard isMouseOnScreen(mouse, target: screen) else {
            if model.expanded {
                scheduleCollapse()
            }
            return
        }

        let isInActivationZone = activationRect(for: screen).contains(mouse)
        let isInsidePanel = window.isVisible && window.frame.insetBy(dx: -hoverTolerance, dy: -hoverTolerance).contains(mouse)

        if isInActivationZone || isInsidePanel {
            pendingCollapse?.cancel()
            pendingCollapse = nil

            showWindow(animated: true)
            if !model.expanded {
                withAnimation(NotchModel.transitionAnimation) {
                    model.expanded = true
                }
                resizeWindow(animated: true)
            }
            // No reposition() when already expanded - prevents animation interruption
            return
        }

        if model.expanded {
            scheduleCollapse()
        }
    }

    private func scheduleCollapse() {
        guard pendingCollapse == nil else { return }

        let collapseWorkItem = DispatchWorkItem { [weak self] in
            guard let self, let window else { return }

            let mouse = NSEvent.mouseLocation
            let isInsidePanel = window.isVisible && window.frame.insetBy(dx: -hoverTolerance, dy: -hoverTolerance).contains(mouse)
            let isInActivationZone: Bool = {
                guard let screen = self.preferredNotchScreen() ?? NSScreen.main else { return false }
                return self.activationRect(for: screen).contains(mouse)
            }()

            if isInsidePanel || isInActivationZone {
                self.pendingCollapse = nil
                return
            }

            // Keep the panel alive while dragging out content from the notch.
            if NSEvent.pressedMouseButtons != 0 {
                self.pendingCollapse = nil
                self.scheduleCollapse()
                return
            }

            self.setExpanded(false)
            self.pendingCollapse = nil
        }

        pendingCollapse = collapseWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: collapseWorkItem)
    }

    private func showWindow(animated: Bool) {
        guard let window else { return }

        if window.isVisible {
            if animated, window.alphaValue < 1 {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = visibilityAnimationDuration
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    window.animator().alphaValue = 1
                }
            } else {
                window.alphaValue = 1
            }
            return
        }

        if animated {
            window.alphaValue = 0
            window.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = visibilityAnimationDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                window.animator().alphaValue = 1
            }
        } else {
            window.alphaValue = 1
            window.orderFrontRegardless()
        }
    }

    private func activationRect(for screen: NSScreen) -> NSRect {
        if let notchRect = hardwareNotchRect(for: screen) {
            let width = min(activationZoneWidth, notchRect.width)
            let height = min(activationZoneHeight, notchRect.height)
            return NSRect(
                x: notchRect.midX - width / 2,
                y: notchRect.maxY - height,
                width: width,
                height: height
            )
        }

        let width = activationZoneWidth
        let height = activationZoneHeight
        let topY = hasHardwareNotch(on: screen)
            ? screen.frame.maxY - height
            : screen.visibleFrame.maxY - height
        return NSRect(
            x: screen.frame.midX - width / 2,
            y: topY,
            width: width,
            height: height
        )
    }

    private func hasHardwareNotch(on screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0 || hardwareNotchRect(for: screen) != nil
    }

    private func hardwareNotchRect(for screen: NSScreen) -> NSRect? {
        guard
            let leftArea = screen.auxiliaryTopLeftArea,
            let rightArea = screen.auxiliaryTopRightArea,
            !leftArea.isEmpty,
            !rightArea.isEmpty
        else {
            return nil
        }

        let notchWidth = rightArea.minX - leftArea.maxX
        guard notchWidth > 4 else { return nil }

        let notchBottom = min(leftArea.minY, rightArea.minY)
        return NSRect(
            x: leftArea.maxX,
            y: notchBottom,
            width: notchWidth,
            height: max(0, screen.frame.maxY - notchBottom)
        )
    }

    private func preferredNotchScreen() -> NSScreen? {
        let builtIn = NSScreen.screens.filter { screen in
            guard let displayID = displayID(for: screen) else { return false }
            return CGDisplayIsBuiltin(displayID) != 0
        }

        if let notchedBuiltIn = builtIn.first(where: { $0.safeAreaInsets.top > 0 }) {
            return notchedBuiltIn
        }
        return builtIn.first
    }

    private func isMouseOnScreen(_ point: NSPoint, target: NSScreen) -> Bool {
        guard let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else {
            return false
        }

        guard
            let mouseID = displayID(for: mouseScreen),
            let targetID = displayID(for: target)
        else {
            return mouseScreen == target
        }

        return mouseID == targetID
    }

    private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        guard let screenNumber = screen.deviceDescription[key] as? NSNumber else { return nil }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }
}

@MainActor
final class NotchPreferences: ObservableObject {
    static let shared = NotchPreferences()

    @Published var showMenuBarIcon = true { didSet { persist(Keys.showMenuBarIcon, showMenuBarIcon) } }

    @Published var launchAtLogin = false {
        didSet {
            persist(Keys.launchAtLogin, launchAtLogin)
            updateLoginItem()
        }
    }

    @Published var showSystemMetrics = true { didSet { persist(Keys.showSystemMetrics, showSystemMetrics) } }
    @Published var showBattery = true { didSet { persist(Keys.showBattery, showBattery) } }
    @Published var showCPU = true { didSet { persist(Keys.showCPU, showCPU) } }
    @Published var showRAM = true { didSet { persist(Keys.showRAM, showRAM) } }
    @Published var showGPU = false { didSet { persist(Keys.showGPU, showGPU) } }
    @Published var showWeather = false { didSet { persist(Keys.showWeather, showWeather) } }
    @Published var showMediaNowPlaying = true { didSet { persist(Keys.showMediaNowPlaying, showMediaNowPlaying) } }
    @Published var showNetworkTiles = false { didSet { persist(Keys.showNetworkTiles, showNetworkTiles) } }

    @Published var showMuteAction = true { didSet { persist(Keys.showMuteAction, showMuteAction) } }
    @Published var showFilePasteAction = false { didSet { persist(Keys.showFilePasteAction, showFilePasteAction) } }

    @Published var showFileShelf = true { didSet { persist(Keys.showFileShelf, showFileShelf) } }
    @Published var showClipboardHistory = false { didSet { persist(Keys.showClipboardHistory, showClipboardHistory) } }
    @Published var showMiniCalendar = false { didSet { persist(Keys.showMiniCalendar, showMiniCalendar) } }
    @Published var showFocusTimer = false { didSet { persist(Keys.showFocusTimer, showFocusTimer) } }
    @Published var focusMinutes = 25 {
        didSet {
            let clamped = min(max(focusMinutes, 5), 120)
            if clamped != focusMinutes {
                focusMinutes = clamped
                return
            }
            persist(Keys.focusMinutes, focusMinutes)
        }
    }
    @Published var breakMinutes = 5 {
        didSet {
            let clamped = min(max(breakMinutes, 1), 60)
            if clamped != breakMinutes {
                breakMinutes = clamped
                return
            }
            persist(Keys.breakMinutes, breakMinutes)
        }
    }

    @Published var selectedProfile: NotchProfile = .work {
        didSet {
            persist(Keys.selectedProfile, selectedProfile.rawValue)
            if !isApplyingProfile {
                applyProfile(selectedProfile)
            }
        }
    }
    @Published var autoProfileByActiveApp = false { didSet { persist(Keys.autoProfileByActiveApp, autoProfileByActiveApp) } }

    private let defaults = UserDefaults.standard
    private var isApplyingProfile = false

    private init() {
        showSystemMetrics = readBool(Keys.showSystemMetrics, defaultValue: true)
        showBattery = readBool(Keys.showBattery, defaultValue: true)
        showCPU = readBool(Keys.showCPU, defaultValue: true)
        showRAM = readBool(Keys.showRAM, defaultValue: true)
        showGPU = readBool(Keys.showGPU, defaultValue: false)
        showWeather = readBool(Keys.showWeather, defaultValue: false)
        showMediaNowPlaying = readBool(Keys.showMediaNowPlaying, defaultValue: true)
        showNetworkTiles = readBool(Keys.showNetworkTiles, defaultValue: false)

        showMuteAction = readBool(Keys.showMuteAction, defaultValue: true)
        showFilePasteAction = readBool(Keys.showFilePasteAction, defaultValue: false)

        showFileShelf = readBool(Keys.showFileShelf, defaultValue: true)
        showClipboardHistory = readBool(Keys.showClipboardHistory, defaultValue: false)
        showMiniCalendar = readBool(Keys.showMiniCalendar, defaultValue: false)
        showFocusTimer = readBool(Keys.showFocusTimer, defaultValue: false)
        focusMinutes = readInt(Keys.focusMinutes, defaultValue: 25)
        breakMinutes = readInt(Keys.breakMinutes, defaultValue: 5)

        let loadedProfile = readString(Keys.selectedProfile, defaultValue: NotchProfile.work.rawValue)
        selectedProfile = NotchProfile(rawValue: loadedProfile) ?? .work
        autoProfileByActiveApp = readBool(Keys.autoProfileByActiveApp, defaultValue: false)
        launchAtLogin = readBool(Keys.launchAtLogin, defaultValue: false)
        showMenuBarIcon = readBool(Keys.showMenuBarIcon, defaultValue: true)
    }

    func resetDefaults() {
        isApplyingProfile = true
        showSystemMetrics = true
        showBattery = true
        showCPU = true
        showRAM = true
        showGPU = false
        showWeather = false
        showMediaNowPlaying = true
        showNetworkTiles = false

        showMuteAction = true
        showFilePasteAction = false

        showFileShelf = true
        showClipboardHistory = false
        showMiniCalendar = false
        showFocusTimer = false
        focusMinutes = 25
        breakMinutes = 5
        autoProfileByActiveApp = false
        launchAtLogin = false
        isApplyingProfile = false

        selectedProfile = .work
    }

    func applySelectedProfile() {
        applyProfile(selectedProfile)
    }

    func applyProfileForActiveApp(bundleIdentifier: String?) {
        guard autoProfileByActiveApp else { return }
        guard let profile = inferredProfile(for: bundleIdentifier) else { return }
        guard selectedProfile != profile else { return }
        selectedProfile = profile
    }

    private func applyProfile(_ profile: NotchProfile) {
        isApplyingProfile = true
        defer { isApplyingProfile = false }

        switch profile {
        case .work:
            showBattery = true
            showCPU = true
            showRAM = true
            showGPU = false
            showWeather = true
            showMediaNowPlaying = true
            showNetworkTiles = true

            showMuteAction = true
            showFilePasteAction = true

            showFileShelf = true
            showClipboardHistory = true
            showMiniCalendar = true
            showFocusTimer = true
            focusMinutes = 25
            breakMinutes = 5
        case .gaming:
            showBattery = true
            showCPU = true
            showRAM = true
            showGPU = true
            showWeather = false
            showMediaNowPlaying = true
            showNetworkTiles = true

            showMuteAction = true
            showFilePasteAction = false

            showFileShelf = true
            showClipboardHistory = true
            showMiniCalendar = false
            showFocusTimer = true
            focusMinutes = 45
            breakMinutes = 10
        case .meeting:
            showBattery = true
            showCPU = false
            showRAM = false
            showGPU = false
            showWeather = true
            showMediaNowPlaying = false
            showNetworkTiles = true

            showMuteAction = true
            showFilePasteAction = true

            showFileShelf = true
            showClipboardHistory = true
            showMiniCalendar = true
            showFocusTimer = true
            focusMinutes = 20
            breakMinutes = 5
        }
    }

    private func inferredProfile(for bundleIdentifier: String?) -> NotchProfile? {
        guard let bundleIdentifier else { return nil }

        let gamingApps = [
            "com.valvesoftware.steam",
            "com.blizzard.battlenet",
            "com.epicgames.launcher",
            "com.riotgames.RiotGames.RiotClient",
        ]
        if gamingApps.contains(bundleIdentifier) || bundleIdentifier.lowercased().contains("game") {
            return .gaming
        }

        let meetingApps = [
            "us.zoom.xos",
            "com.microsoft.teams2",
            "com.microsoft.teams",
            "com.webex.meetingmanager",
            "com.google.Chrome",
        ]
        if meetingApps.contains(bundleIdentifier) {
            return .meeting
        }

        return .work
    }

    private func readBool(_ key: String, defaultValue: Bool) -> Bool {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.bool(forKey: key)
    }

    private func readString(_ key: String, defaultValue: String) -> String {
        defaults.string(forKey: key) ?? defaultValue
    }

    private func readInt(_ key: String, defaultValue: Int) -> Int {
        if defaults.object(forKey: key) == nil {
            return defaultValue
        }
        return defaults.integer(forKey: key)
    }

    private func persist(_ key: String, _ value: Bool) {
        defaults.set(value, forKey: key)
    }

    private func persist(_ key: String, _ value: String) {
        defaults.set(value, forKey: key)
    }

    private func persist(_ key: String, _ value: Int) {
        defaults.set(value, forKey: key)
    }

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("Login item update failed: \(error)")
        }
    }

    private enum Keys {
        static let showSystemMetrics = "notchnook.settings.showSystemMetrics"
        static let showBattery = "notchnook.settings.showBattery"
        static let showCPU = "notchnook.settings.showCPU"
        static let showRAM = "notchnook.settings.showRAM"
        static let showGPU = "notchnook.settings.showGPU"
        static let showWeather = "notchnook.settings.showWeather"
        static let showMediaNowPlaying = "notchnook.settings.showMediaNowPlaying"
        static let showNetworkTiles = "notchnook.settings.showNetworkTiles"

        static let showMuteAction = "notchnook.settings.showMuteAction"
        static let showFilePasteAction = "notchnook.settings.showFilePasteAction"

        static let showFileShelf = "notchnook.settings.showFileShelf"
        static let showClipboardHistory = "notchnook.settings.showClipboardHistory"
        static let showMiniCalendar = "notchnook.settings.showMiniCalendar"
        static let showFocusTimer = "notchnook.settings.showFocusTimer"
        static let focusMinutes = "notchnook.settings.focusMinutes"
        static let breakMinutes = "notchnook.settings.breakMinutes"
        static let selectedProfile = "notchnook.settings.selectedProfile"
        static let autoProfileByActiveApp = "notchnook.settings.autoProfileByActiveApp"
        static let launchAtLogin = "notchnook.settings.launchAtLogin"
        static let showMenuBarIcon = "notchnook.settings.showMenuBarIcon"
    }
}

@MainActor
final class NotchModel: ObservableObject {
    static let transitionAnimation = Animation.spring(response: 0.36, dampingFraction: 0.86, blendDuration: 0.1)

    @Published var expanded = true
    @Published var droppedFiles: [URL] = []
    @Published var selectedShelfFiles: Set<URL> = []
    @Published var clipboardEntries: [ClipboardEntry] = []
    @Published var pinnedClipboardIDs: Set<UUID> = []
    @Published var reminderItems: [ReminderItem] = []
    @Published var reminderStatusText = "Enable Mini Calendar in settings"
    @Published var currentDayText = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)

    @Published var focusPhase: FocusPhase = .idle
    @Published var focusRemainingSeconds: Int

    @Published var cpuValue = "--"
    @Published var memoryValue = "--"
    @Published var gpuValue = "--"
    @Published var batteryValue = "--"
    @Published var batteryIcon = "battery.100"
    @Published var weatherValue = "--"
    @Published var weatherIcon = "cloud"
    @Published var nowPlayingValue = "Not playing"
    @Published var nowPlayingIsPlaying: Bool = false
    @Published var nowPlayingDuration: Double? = nil
    @Published var nowPlayingPosition: Double? = nil
    @Published var nowPlayingArtwork: NSImage? = nil
    private var nowPlayingPositionFetchTime: Date = .distantPast
    private var lastArtworkSource: String? = nil
    private var artworkTask: Task<Void, Never>?
    @Published var networkDownValue = "--"
    @Published var networkUpValue = "--"
    @Published var pingValue = "--"
    @Published var vpnValue = "--"

    @Published var actionFeedback = ""

    let preferences = NotchPreferences.shared

    private let storageKey = "notchnook.fileShelf.paths"
    private let clipboardStorageKey = "notchnook.clipboard.entries"
    private let clipboardPinnedStorageKey = "notchnook.clipboard.pinned"
    private var statsTimer: Timer?
    private var clipboardTimer: Timer?
    private var focusTimer: Timer?
    private var cpuSampler = CPUSampler()
    private var networkSampler = NetworkSampler()
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount

    private var focusMinutesCancellable: AnyCancellable?
    private var breakMinutesCancellable: AnyCancellable?
    private var feedbackToken = UUID()
    private var lastWeatherFetch = Date.distantPast
    private var lastNowPlayingFetch = Date.distantPast
    private var lastCalendarFetch = Date.distantPast
    private var lastPingFetch = Date.distantPast
    private var weatherTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var calendarTask: Task<Void, Never>?
    private var appActivationObserver: NSObjectProtocol?
    private let eventStore = EKEventStore()
    private var reminderAccessRequested = false
    private var reminderAccessGranted = false

    var currentSize: NSSize {
        if expanded {
            var height: CGFloat = 56
            if preferences.showMediaNowPlaying { height += 80 }
            if preferences.showFocusTimer { height += 56 }
            if preferences.showClipboardHistory { height += 72 }
            if preferences.showMiniCalendar { height += 64 }
            if preferences.showFileShelf { height += 88 }
            return NSSize(width: 380, height: min(height, 460))
        }
        if hasLiveFocusWidget {
            return NSSize(width: 240, height: 32)
        }
        return NSSize(width: 190, height: 32)
    }

    init() {
        focusRemainingSeconds = NotchPreferences.shared.focusMinutes * 60
        loadDroppedFiles()
        loadClipboardState()
        refreshStats(forceWeather: true, forceNowPlaying: true, forceCalendar: true, forcePing: true)
        startStatsTimer()
        startClipboardMonitor()
        observeActiveAppChanges()

        focusMinutesCancellable = preferences.$focusMinutes
            .dropFirst()
            .sink { [weak self] newMinutes in
                guard let self else { return }
                self.handleFocusDurationChange(newMinutes: newMinutes)
            }
        breakMinutesCancellable = preferences.$breakMinutes
            .dropFirst()
            .sink { [weak self] newMinutes in
                guard let self else { return }
                self.handleBreakDurationChange(newMinutes: newMinutes)
            }
    }

    func cleanup() {
        statsTimer?.invalidate()
        statsTimer = nil
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        focusTimer?.invalidate()
        focusTimer = nil
        weatherTask?.cancel()
        pingTask?.cancel()
        calendarTask?.cancel()
        artworkTask?.cancel()
        nowPlayingTask?.cancel()
        if let observer = appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            appActivationObserver = nil
        }
        focusMinutesCancellable?.cancel()
        focusMinutesCancellable = nil
        breakMinutesCancellable?.cancel()
        breakMinutesCancellable = nil
    }

    func addFile(_ url: URL) {
        let cleanURL = url.standardizedFileURL
        if droppedFiles.contains(cleanURL) { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            droppedFiles.insert(cleanURL, at: 0)
        }
        persistDroppedFiles()
    }

    func removeFile(_ url: URL) {
        droppedFiles.removeAll { $0 == url }
        selectedShelfFiles.remove(url)
        persistDroppedFiles()
    }

    func isShelfSelected(_ url: URL) -> Bool {
        selectedShelfFiles.contains(url)
    }

    func toggleShelfSelection(_ url: URL) {
        if selectedShelfFiles.contains(url) {
            selectedShelfFiles.remove(url)
        } else {
            selectedShelfFiles.insert(url)
        }
    }

    func selectAllShelfFiles() {
        selectedShelfFiles = Set(droppedFiles)
    }

    func clearShelfSelection() {
        selectedShelfFiles.removeAll()
    }

    func openFile(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func copyLatestFileToPasteboard() {
        guard let latest = droppedFiles.first else {
            setFeedback("No file in shelf yet")
            NSSound.beep()
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        if pasteboard.writeObjects([latest as NSURL]) {
            setFeedback("Copied \(latest.lastPathComponent) for paste")
        } else {
            setFeedback("Couldn't copy file")
        }
    }

    var sortedClipboardEntries: [ClipboardEntry] {
        let pinned = clipboardEntries
            .filter { pinnedClipboardIDs.contains($0.id) }
            .sorted { $0.timestamp > $1.timestamp }

        let history = clipboardEntries
            .filter { !pinnedClipboardIDs.contains($0.id) }
            .sorted { $0.timestamp > $1.timestamp }

        return pinned + history
    }

    func isClipboardPinned(_ entry: ClipboardEntry) -> Bool {
        pinnedClipboardIDs.contains(entry.id)
    }

    func toggleClipboardPin(_ entry: ClipboardEntry) {
        if pinnedClipboardIDs.contains(entry.id) {
            pinnedClipboardIDs.remove(entry.id)
        } else {
            pinnedClipboardIDs.insert(entry.id)
        }
        persistClipboardState()
    }

    func copyClipboardEntry(_ entry: ClipboardEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.value, forType: .string)
        setFeedback("Copied from clipboard history")
    }

    func removeClipboardEntry(_ entry: ClipboardEntry) {
        clipboardEntries.removeAll { $0.id == entry.id }
        pinnedClipboardIDs.remove(entry.id)
        persistClipboardState()
    }

    var focusPhaseTitle: String {
        switch focusPhase {
        case .idle, .focus, .pausedFocus:
            return "Focus"
        case .breakTime, .pausedBreak:
            return "Break"
        }
    }

    var focusTimeString: String {
        String(format: "%02d:%02d", focusRemainingSeconds / 60, focusRemainingSeconds % 60)
    }

    var focusButtonTitle: String {
        focusPhase.isRunning ? "Pause" : "Start"
    }

    var hasLiveFocusWidget: Bool {
        preferences.showFocusTimer && focusPhase != .idle
    }

    var isNowPlaying: Bool {
        preferences.showMediaNowPlaying && nowPlayingValue != "Not playing" && nowPlayingValue != "Hidden in settings"
    }

    /// The media source icon based on what's currently playing.
    var nowPlayingIcon: String {
        if nowPlayingValue.hasPrefix("Spotify") { return "music.note" }
        if nowPlayingValue.hasPrefix("YouTube") { return "play.rectangle.fill" }
        if nowPlayingValue.hasPrefix("Music") { return "music.quarternote.3" }
        return "music.note"
    }

    /// Short track title without the source prefix (e.g. "Spotify • ").
    var nowPlayingShortTitle: String {
        if let range = nowPlayingValue.range(of: " • ") {
            return String(nowPlayingValue[range.upperBound...])
        }
        return nowPlayingValue
    }

    /// Source label (e.g. "Spotify", "YouTube (Brave)").
    var nowPlayingSource: String {
        if let range = nowPlayingValue.range(of: " • ") {
            return String(nowPlayingValue[..<range.lowerBound])
        }
        return ""
    }

    /// Interpolated current playback position in seconds.
    var nowPlayingCurrentPosition: Double? {
        guard let pos = nowPlayingPosition else { return nil }
        if nowPlayingIsPlaying {
            return min(pos + Date().timeIntervalSince(nowPlayingPositionFetchTime),
                       nowPlayingDuration ?? .infinity)
        }
        return pos
    }

    /// Formatted remaining time string, e.g. "-2:34".
    var nowPlayingRemainingText: String? {
        guard let duration = nowPlayingDuration, duration > 0,
              let current = nowPlayingCurrentPosition else { return nil }
        let remaining = max(0, duration - current)
        let minutes = Int(remaining) / 60
        let seconds = Int(remaining) % 60
        return "-\(minutes):\(String(format: "%02d", seconds))"
    }

    /// Playback progress from 0 to 1.
    var nowPlayingProgress: Double? {
        guard let duration = nowPlayingDuration, duration > 0,
              let current = nowPlayingCurrentPosition else { return nil }
        return min(1.0, max(0.0, current / duration))
    }

    func toggleFocus() {
        if focusPhase.isRunning {
            pauseFocus()
            return
        }

        if focusPhase == .idle {
            focusPhase = .focus
            focusRemainingSeconds = focusDurationSeconds
        } else if focusPhase == .pausedFocus {
            focusPhase = .focus
        } else if focusPhase == .pausedBreak {
            focusPhase = .breakTime
        }

        startFocusTimer()
    }

    func adjustAndStartFocus(delta: Int) {
        let currentPhaseIsFocus = focusPhase == .idle || focusPhase == .focus || focusPhase == .pausedFocus
        if currentPhaseIsFocus {
            preferences.focusMinutes = min(max(preferences.focusMinutes + delta, 5), 120)
        } else {
            preferences.breakMinutes = min(max(preferences.breakMinutes + delta, 1), 60)
        }
        // Start/restart timer with the new duration
        focusTimer?.invalidate()
        focusTimer = nil
        if focusPhase == .idle {
            focusPhase = .focus
        }
        let seconds = currentPhaseIsFocus ? focusDurationSeconds : breakDurationSeconds
        focusRemainingSeconds = seconds
        startFocusTimer()
    }

    func resetFocus() {
        focusTimer?.invalidate()
        focusTimer = nil
        focusPhase = .idle
        focusRemainingSeconds = focusDurationSeconds
        setFeedback("Focus timer reset")
    }

    private func handleFocusDurationChange(newMinutes: Int) {
        let newSeconds = max(1, newMinutes) * 60
        switch focusPhase {
        case .idle:
            focusRemainingSeconds = newSeconds
        case .focus, .pausedFocus:
            focusRemainingSeconds = newSeconds
            setFeedback("Focus: \(newMinutes) min")
        case .breakTime, .pausedBreak:
            break
        }
    }

    private func handleBreakDurationChange(newMinutes: Int) {
        let newSeconds = max(1, newMinutes) * 60
        switch focusPhase {
        case .idle:
            break
        case .breakTime, .pausedBreak:
            focusRemainingSeconds = newSeconds
            setFeedback("Break: \(newMinutes) min")
        case .focus, .pausedFocus:
            break
        }
    }

    func skipFocusPhase() {
        switch focusPhase {
        case .breakTime, .pausedBreak:
            focusPhase = .focus
            focusRemainingSeconds = focusDurationSeconds
        default:
            focusPhase = .breakTime
            focusRemainingSeconds = breakDurationSeconds
        }

        if focusPhase == .focus || focusPhase == .breakTime {
            startFocusTimer()
        }
    }

    private func loadDroppedFiles() {
        let paths = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
        droppedFiles = paths
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        selectedShelfFiles = Set(selectedShelfFiles.filter { droppedFiles.contains($0) })
    }

    private func persistDroppedFiles() {
        UserDefaults.standard.set(droppedFiles.map(\.path), forKey: storageKey)
    }

    private func loadClipboardState() {
        if
            let data = UserDefaults.standard.data(forKey: clipboardStorageKey),
            let decoded = try? JSONDecoder().decode([ClipboardEntry].self, from: data)
        {
            clipboardEntries = decoded
        } else {
            clipboardEntries = []
        }

        let pinnedStrings = UserDefaults.standard.stringArray(forKey: clipboardPinnedStorageKey) ?? []
        pinnedClipboardIDs = Set(pinnedStrings.compactMap(UUID.init(uuidString:)))
        pinnedClipboardIDs = Set(pinnedClipboardIDs.filter { id in
            clipboardEntries.contains(where: { $0.id == id })
        })
    }

    private func persistClipboardState() {
        if let encoded = try? JSONEncoder().encode(clipboardEntries) {
            UserDefaults.standard.set(encoded, forKey: clipboardStorageKey)
        }
        let pinned = pinnedClipboardIDs.map(\.uuidString)
        UserDefaults.standard.set(pinned, forKey: clipboardPinnedStorageKey)
    }

    private func startStatsTimer() {
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshStats(forceWeather: false, forceNowPlaying: false, forceCalendar: false, forcePing: false)
            }
        }
        statsTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func startClipboardMonitor() {
        let timer = Timer(timeInterval: 0.8, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.pollClipboard()
            }
        }
        clipboardTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func observeActiveAppChanges() {
        guard appActivationObserver == nil else { return }

        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard
                let self,
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }

            Task { @MainActor in
                self.preferences.applyProfileForActiveApp(bundleIdentifier: app.bundleIdentifier)
            }
        }
    }

    private func refreshStats(forceWeather: Bool, forceNowPlaying: Bool, forceCalendar: Bool, forcePing: Bool) {
        // Only refresh system metrics when panel is expanded or during initial load
        if expanded || forceWeather {
            if preferences.showCPU { cpuValue = cpuSampler.usagePercentString() ?? "--" }
            if preferences.showRAM { memoryValue = MemoryStats.usageString() ?? "--" }
            if preferences.showGPU { gpuValue = GPUStats.usageString() ?? "--" }

            if preferences.showBattery {
                let battery = BatteryStats.current()
                batteryValue = battery.value
                batteryIcon = battery.icon
            }
        }

        maybeRefreshWeather(force: forceWeather)
        maybeRefreshNowPlaying(force: forceNowPlaying)
        maybeRefreshCalendar(force: forceCalendar)
        maybeRefreshNetwork(forcePing: forcePing)
    }

    private func maybeRefreshWeather(force: Bool) {
        guard preferences.showWeather else {
            weatherValue = "--"
            weatherIcon = "cloud"
            return
        }

        let now = Date()
        guard force || now.timeIntervalSince(lastWeatherFetch) >= 600 else { return }
        lastWeatherFetch = now

        weatherTask?.cancel()
        weatherTask = Task { [weak self] in
            let weather = await WeatherService.fetchCurrent()
            await MainActor.run {
                guard let self else { return }
                if let weather {
                    self.weatherValue = weather.value
                    self.weatherIcon = weather.icon
                } else {
                    self.weatherValue = "--"
                    self.weatherIcon = "cloud.slash"
                }
            }
        }
    }

    private var nowPlayingTask: Task<Void, Never>?

    private func maybeRefreshNowPlaying(force: Bool) {
        guard preferences.showMediaNowPlaying else {
            nowPlayingValue = "Hidden in settings"
            nowPlayingIsPlaying = false
            nowPlayingDuration = nil
            nowPlayingPosition = nil
            nowPlayingArtwork = nil
            return
        }

        let now = Date()
        guard force || now.timeIntervalSince(lastNowPlayingFetch) >= 2.5 else { return }
        lastNowPlayingFetch = now

        nowPlayingTask?.cancel()
        nowPlayingTask = Task { [weak self] in
            let info = await Task.detached(priority: .userInitiated) {
                NowPlayingService.currentInfo()
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                if let info {
                    self.nowPlayingValue = "\(info.source) • \(info.track)"
                    self.nowPlayingIsPlaying = info.isPlaying
                    self.nowPlayingDuration = info.duration
                    self.nowPlayingPosition = info.position
                    self.nowPlayingPositionFetchTime = info.fetchTime

                    let artworkKey = info.artworkURL ?? (info.source + info.track)
                    if artworkKey != self.lastArtworkSource {
                        self.lastArtworkSource = artworkKey
                        self.nowPlayingArtwork = nil
                        self.artworkTask?.cancel()

                        if let data = info.artworkData, let image = NSImage(data: data) {
                            self.nowPlayingArtwork = image
                        } else if let urlString = info.artworkURL, let url = URL(string: urlString) {
                            self.artworkTask = Task {
                                do {
                                    let (data, _) = try await URLSession.shared.data(from: url)
                                    if !Task.isCancelled, let image = NSImage(data: data) {
                                        self.nowPlayingArtwork = image
                                    }
                                } catch {}
                            }
                        }
                    }
                } else {
                    self.nowPlayingValue = "Not playing"
                    self.nowPlayingIsPlaying = false
                    self.nowPlayingDuration = nil
                    self.nowPlayingPosition = nil
                    if self.lastArtworkSource != nil {
                        self.lastArtworkSource = nil
                        self.nowPlayingArtwork = nil
                        self.artworkTask?.cancel()
                    }
                }
            }
        }
    }

    private func maybeRefreshCalendar(force: Bool) {
        guard preferences.showMiniCalendar else {
            reminderItems = []
            reminderStatusText = "Enable Mini Calendar in settings"
            return
        }

        let now = Date()
        guard force || now.timeIntervalSince(lastCalendarFetch) >= 300 else { return }
        lastCalendarFetch = now

        calendarTask?.cancel()
        calendarTask = Task { [weak self] in
            await self?.refreshReminders()
        }
    }

    private func maybeRefreshNetwork(forcePing: Bool) {
        guard preferences.showNetworkTiles else {
            networkDownValue = "--"
            networkUpValue = "--"
            pingValue = "--"
            vpnValue = "--"
            return
        }

        let sample = networkSampler.sample()
        networkDownValue = sample.down
        networkUpValue = sample.up
        vpnValue = sample.vpnEnabled ? "On" : "Off"

        let now = Date()
        guard forcePing || now.timeIntervalSince(lastPingFetch) >= 8 else { return }
        lastPingFetch = now

        pingTask?.cancel()
        pingTask = Task { [weak self] in
            let ping = await PingService.singlePingAsync(host: "1.1.1.1") ?? "Timeout"
            self?.pingValue = ping
        }
    }

    private func pollClipboard() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastPasteboardChangeCount else { return }
        lastPasteboardChangeCount = pasteboard.changeCount

        guard let raw = pasteboard.string(forType: .string) else { return }
        let normalized = normalizeClipboardText(raw)
        guard !normalized.isEmpty else { return }

        clipboardEntries.removeAll { $0.value == normalized }
        clipboardEntries.insert(
            ClipboardEntry(id: UUID(), value: normalized, timestamp: Date()),
            at: 0
        )
        clipboardEntries = Array(clipboardEntries.prefix(5))

        pinnedClipboardIDs = Set(pinnedClipboardIDs.filter { id in
            clipboardEntries.contains(where: { $0.id == id })
        })
        persistClipboardState()
    }

    private func normalizeClipboardText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[^\\S\\r\\n]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshReminders() async {
        currentDayText = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)

        let granted = await ensureReminderAccess()
        guard granted else {
            reminderStatusText = "Reminders permission needed"
            reminderItems = []
            return
        }

        let calendar = Calendar.current
        let start = Date()
        guard let end = calendar.date(byAdding: .day, value: 3, to: start) else {
            reminderStatusText = "Could not load reminders"
            reminderItems = []
            return
        }

        let predicate = eventStore.predicateForIncompleteReminders(
            withDueDateStarting: start,
            ending: end,
            calendars: nil
        )

        struct ReminderSnapshot: Sendable {
            let title: String
            let dueDate: Date?
        }

        let reminders: [ReminderSnapshot] = await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: predicate) { fetched in
                let snapshots = (fetched ?? []).map {
                    ReminderSnapshot(
                        title: $0.title.isEmpty ? "Untitled reminder" : $0.title,
                        dueDate: $0.dueDateComponents?.date
                    )
                }
                continuation.resume(returning: snapshots)
            }
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short

        let sorted = reminders.sorted { lhs, rhs in
            let leftDate = lhs.dueDate ?? .distantFuture
            let rightDate = rhs.dueDate ?? .distantFuture
            return leftDate < rightDate
        }

        reminderItems = sorted.prefix(4).map { reminder in
            let dueDate = reminder.dueDate
            let dueText: String
            if let dueDate {
                dueText = formatter.string(from: dueDate)
            } else {
                dueText = "No due time"
            }

            return ReminderItem(
                title: reminder.title,
                dueText: dueText
            )
        }

        reminderStatusText = reminderItems.isEmpty ? "No upcoming reminders" : "Upcoming reminders"
    }

    private func ensureReminderAccess() async -> Bool {
        if reminderAccessRequested {
            return reminderAccessGranted
        }

        reminderAccessRequested = true

        if #available(macOS 14.0, *) {
            reminderAccessGranted = (try? await eventStore.requestFullAccessToReminders()) ?? false
        } else {
            reminderAccessGranted = await withCheckedContinuation { continuation in
                eventStore.requestAccess(to: .reminder) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        }

        return reminderAccessGranted
    }

    private func startFocusTimer() {
        focusTimer?.invalidate()
        focusTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tickFocus()
            }
        }
        if let focusTimer {
            RunLoop.main.add(focusTimer, forMode: .common)
        }
    }

    private func tickFocus() {
        guard focusPhase.isRunning else { return }

        focusRemainingSeconds -= 1
        if focusRemainingSeconds > 0 { return }

        if focusPhase == .focus {
            focusPhase = .breakTime
            focusRemainingSeconds = breakDurationSeconds
            setFeedback("Focus complete. Break started.")
        } else {
            focusPhase = .focus
            focusRemainingSeconds = focusDurationSeconds
            setFeedback("Break complete. Focus started.")
        }
    }

    private func pauseFocus() {
        focusTimer?.invalidate()
        focusTimer = nil

        switch focusPhase {
        case .focus:
            focusPhase = .pausedFocus
        case .breakTime:
            focusPhase = .pausedBreak
        default:
            break
        }
    }

    private var focusDurationSeconds: Int {
        max(1, preferences.focusMinutes) * 60
    }

    private var breakDurationSeconds: Int {
        max(1, preferences.breakMinutes) * 60
    }

    private func setFeedback(_ message: String) {
        actionFeedback = message
        let token = UUID()
        feedbackToken = token

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            guard let self, self.feedbackToken == token else { return }
            self.actionFeedback = ""
        }
    }
}

struct NotchRootView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        ZStack {
            if model.expanded {
                ExpandedNotch(model: model)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .top)),
                            removal: .opacity.combined(with: .scale(scale: 0.985, anchor: .top))
                        )
                    )
            } else {
                CollapsedNotch(model: model)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            }
        }
        .animation(NotchModel.transitionAnimation, value: model.expanded)
    }
}

struct CollapsedNotch: View {
    @ObservedObject var model: NotchModel
    @State private var isHovering = false

    var body: some View {
        Group {
            if model.hasLiveFocusWidget {
                focusLiveActivityView
            } else {
                defaultCollapsedView
            }
        }
        .animation(.easeInOut(duration: 0.16), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture {
            NotchWindowController.shared.toggleExpanded()
        }
    }

    @ViewBuilder
    private var defaultCollapsedView: some View {
        HStack(spacing: 8) {
            Image(systemName: "capsule.portrait")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
            Text("NotchNook")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Capsule().fill(Color(white: 0.10)))
        .overlay(Capsule().stroke(Color.white.opacity(isHovering ? 0.20 : 0.08), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.6), radius: 16, y: 6)
        .scaleEffect(isHovering ? 1.03 : 1.0)
    }

    @ViewBuilder
    private var focusLiveActivityView: some View {
        HStack(spacing: 6) {
            Image(systemName: model.focusPhaseTitle == "Focus" ? "brain.head.profile" : "cup.and.saucer.fill")
                .font(.system(size: 11, weight: .bold))
            Text(model.focusPhaseTitle)
                .font(.system(size: 11, weight: .semibold))
            Text(model.focusTimeString)
                .font(.system(size: 13, weight: .bold, design: .monospaced))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        .foregroundStyle(.white.opacity(0.95))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background(Capsule().fill(Color.black.opacity(0.96)))
        .overlay(Capsule().stroke(Color.cyan.opacity(isHovering ? 0.5 : 0.25), lineWidth: 0.5))
        .shadow(color: .cyan.opacity(isHovering ? 0.22 : 0.10), radius: isHovering ? 10 : 5, y: 3)
        .scaleEffect(isHovering ? 1.025 : 1.0)
    }
}

struct ExpandedNotch: View {
    @ObservedObject var model: NotchModel
    @ObservedObject private var preferences = NotchPreferences.shared
    @State private var dropActive = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            contentSections
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .environment(\.colorScheme, .dark)
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5)
        )
        .animation(.easeInOut(duration: 0.18), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .onTapGesture(count: 2) {
            NotchWindowController.shared.toggleExpanded()
        }
    }

    @ViewBuilder
    private var headerRow: some View {
        VStack(spacing: 6) {
            // Top row: action buttons on left, settings on right — nothing in center (notch area)
            HStack(spacing: 8) {
                if preferences.showMuteAction {
                    headerIconButton("speaker.slash.fill") {
                        MediaController.toggleMute()
                    }
                }
                if preferences.showFilePasteAction {
                    headerIconButton("doc.on.clipboard") {
                        model.copyLatestFileToPasteboard()
                    }
                }

                Spacer(minLength: 0)

                Button {
                    SettingsPresenter.open()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.50))
                .hoverLift(scale: 1.08, hoverOpacity: 1.0)
            }

            // Metrics row: below the notch, full width
            if preferences.showSystemMetrics {
                HStack(spacing: 8) {
                    if preferences.showBattery {
                        metricPill(icon: model.batteryIcon, value: model.batteryValue)
                    }
                    if preferences.showCPU {
                        metricPill(icon: "cpu", value: model.cpuValue)
                    }
                    if preferences.showRAM {
                        metricPill(icon: "memorychip", value: model.memoryValue)
                    }
                    if preferences.showGPU {
                        metricPill(icon: "gpu", value: model.gpuValue)
                    }
                    if preferences.showWeather {
                        metricPill(icon: model.weatherIcon, value: model.weatherValue)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    @ViewBuilder
    private var contentSections: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                if preferences.showMediaNowPlaying {
                    NowPlayingStrip(model: model)
                }

                if preferences.showFocusTimer {
                    FocusTimerView(model: model)
                }

                if preferences.showClipboardHistory {
                    ClipboardHistoryView(model: model)
                }

                if preferences.showMiniCalendar {
                    MiniCalendarView(model: model)
                }

                if preferences.showFileShelf {
                    FileShelfView(model: model, dropActive: $dropActive)
                }

                if !model.actionFeedback.isEmpty {
                    Text(model.actionFeedback)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.cyan.opacity(0.85))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private func headerIconButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 28, height: 28)
                .foregroundStyle(.white.opacity(0.55))
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverLift(scale: 1.06, hoverOpacity: 1.0)
    }

    private func metricPill(icon: String, value: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .foregroundStyle(.white.opacity(0.50))
        .background(Color.white.opacity(0.05), in: Capsule())
    }
}

struct QuickActionsRowView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var preferences: NotchPreferences

    private var hasAnyAction: Bool {
        preferences.showMediaNowPlaying
            || preferences.showMuteAction
            || preferences.showFilePasteAction
    }

    var body: some View {
        if hasAnyAction {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if preferences.showMediaNowPlaying {
                        QuickActionButton(title: "Prev", systemImage: "backward.fill") {
                            MediaController.previousTrack()
                        }
                        QuickActionButton(title: "Play", systemImage: "playpause.fill") {
                            MediaController.playPause()
                        }
                        QuickActionButton(title: "Next", systemImage: "forward.fill") {
                            MediaController.nextTrack()
                        }
                    }

                    if preferences.showMuteAction {
                        QuickActionButton(title: "Mute", systemImage: "speaker.slash.fill") {
                            MediaController.toggleMute()
                        }
                    }

                    if preferences.showFilePasteAction {
                        QuickActionButton(title: "File Paste", systemImage: "doc.on.clipboard") {
                            model.copyLatestFileToPasteboard()
                        }
                    }
                }
            }
        } else {
            Text("Enable quick actions from settings")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
        }
    }
}

struct FocusTimerView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: model.focusPhaseTitle == "Focus" ? "brain.head.profile" : "cup.and.saucer.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.cyan.opacity(0.7))
                .frame(width: 16)

            Text(model.focusPhaseTitle)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.60))

            focusButton(icon: "minus") {
                model.adjustAndStartFocus(delta: -5)
            }

            Text(model.focusTimeString)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.90))

            focusButton(icon: "plus") {
                model.adjustAndStartFocus(delta: 5)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                focusButton(icon: model.focusPhase.isRunning ? "pause.fill" : "play.fill") {
                    model.toggleFocus()
                }
                focusButton(icon: "forward.end.fill") {
                    model.skipFocusPhase()
                }
                focusButton(icon: "arrow.counterclockwise") {
                    model.resetFocus()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 0.5))
    }

    private func focusButton(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverLift(scale: 1.06, hoverOpacity: 1.0)
    }
}

struct ClipboardHistoryView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Section header
            HStack(spacing: 4) {
                Image(systemName: "clipboard")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.40))
                Text("Clipboard")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.50))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.top, 2)

            if model.sortedClipboardEntries.isEmpty {
                Text("Copy text to start history")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.30))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 4)
            } else {
                ForEach(Array(model.sortedClipboardEntries.prefix(3))) { entry in
                    HStack(spacing: 6) {
                        Button {
                            model.copyClipboardEntry(entry)
                        } label: {
                            Text(entry.value)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .foregroundStyle(.white.opacity(0.75))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)

                        Button {
                            model.copyClipboardEntry(entry)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.40))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .hoverLift(scale: 1.08, hoverOpacity: 1.0)

                        Button {
                            model.toggleClipboardPin(entry)
                        } label: {
                            Image(systemName: model.isClipboardPinned(entry) ? "star.fill" : "star")
                                .font(.system(size: 10))
                                .foregroundStyle(model.isClipboardPinned(entry) ? .yellow.opacity(0.7) : .white.opacity(0.30))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .hoverLift(scale: 1.08, hoverOpacity: 1.0)

                        Button {
                            model.removeClipboardEntry(entry)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white.opacity(0.25))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .hoverLift(scale: 1.08, hoverOpacity: 1.0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 0.5))
    }
}

struct MiniCalendarView: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.45))
                Text(model.currentDayText)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer(minLength: 0)
                if model.reminderItems.isEmpty {
                    Text(model.reminderStatusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.30))
                }
            }

            ForEach(model.reminderItems) { reminder in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 5, height: 5)
                    Text(reminder.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.65))
                    Spacer(minLength: 0)
                    Text(reminder.dueText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.40))
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 0.5))
    }
}

struct FileShelfView: View {
    @ObservedObject var model: NotchModel
    @Binding var dropActive: Bool
    // Drag state is tracked by FileShelfDraggingSource.shared.isDragging

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.droppedFiles.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.25))
                    Text("Drop files here")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.30))
                }
                .frame(maxWidth: .infinity, minHeight: 48)
                .padding(.horizontal, 10)
            } else {
                HStack(spacing: 6) {
                    shelfIconButton("checkmark.circle") {
                        model.selectAllShelfFiles()
                    }
                    shelfIconButton("minus.circle") {
                        model.clearShelfSelection()
                    }
                    Spacer(minLength: 0)
                    Text("\(model.droppedFiles.count) files")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .padding(.horizontal, 10)
                .padding(.top, 4)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(model.droppedFiles, id: \.self) { file in
                            HStack(spacing: 6) {
                                Button {
                                    model.toggleShelfSelection(file)
                                } label: {
                                    Image(systemName: model.isShelfSelected(file) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 12))
                                        .foregroundStyle(model.isShelfSelected(file) ? .white.opacity(0.70) : .white.opacity(0.30))
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    model.openFile(file)
                                } label: {
                                    Text(file.lastPathComponent)
                                        .font(.system(size: 12))
                                        .lineLimit(1)
                                        .foregroundStyle(.white.opacity(0.70))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .buttonStyle(.plain)

                                Button {
                                    model.removeFile(file)
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.25))
                                        .frame(width: 24, height: 24)
                                }
                                .buttonStyle(.plain)
                                .hoverLift(scale: 1.08, hoverOpacity: 1.0)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(model.isShelfSelected(file) ? Color.white.opacity(0.08) : Color.clear)
                            )
                            .contentShape(Rectangle())
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 5)
                                    .onChanged { _ in
                                        guard !FileShelfDraggingSource.shared.isDragging else { return }
                                        beginExternalFileDrag(from: file)
                                    }
                            )
                        }
                    }
                }
                .frame(maxHeight: 110)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(dropActive ? Color.cyan.opacity(0.40) : Color.white.opacity(0.10), lineWidth: dropActive ? 1.0 : 0.5)
        )
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropActive, perform: handleDrop(providers:))
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        return FileDropDecoder.loadURLs(from: providers) { urls in
            for url in urls {
                model.addFile(url)
            }
        }
    }

    @discardableResult
    private func beginExternalFileDrag(from anchorFile: URL) -> Bool {
        let files = filesForExternalDrag(anchorFile: anchorFile)
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return false }

        // Use the NotchWindowController's view directly (statusBar windows aren't key/main)
        guard let sourceView = NotchWindowController.shared.dragSourceView else { return false }
        guard let event = NSApp.currentEvent else { return false }

        let basePoint = sourceView.convert(event.locationInWindow, from: nil)
        let draggingItems = files.enumerated().compactMap { index, file -> NSDraggingItem? in
            let draggingItem = NSDraggingItem(pasteboardWriter: file as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: file.path)
            icon.size = NSSize(width: 26, height: 26)

            let offset = CGFloat(min(index, 6) * 2)
            let frame = NSRect(
                x: basePoint.x + offset,
                y: basePoint.y - offset,
                width: icon.size.width,
                height: icon.size.height
            )
            draggingItem.setDraggingFrame(frame, contents: icon)
            return draggingItem
        }

        guard !draggingItems.isEmpty else { return false }

        let dragSource = FileShelfDraggingSource.shared
        dragSource.isDragging = true
        dragSource.draggedFiles = files
        dragSource.onDragCompleted = { [weak model] draggedURLs in
            Task { @MainActor in
                guard let model else { return }
                for url in draggedURLs {
                    model.removeFile(url)
                }
                model.actionFeedback = "Moved \(draggedURLs.count) file\(draggedURLs.count == 1 ? "" : "s") out"
            }
        }
        let session = sourceView.beginDraggingSession(
            with: draggingItems,
            event: event,
            source: dragSource
        )
        session.animatesToStartingPositionsOnCancelOrFail = true
        return true
    }

    private func filesForExternalDrag(anchorFile: URL) -> [URL] {
        let selected = model.droppedFiles.filter { model.selectedShelfFiles.contains($0) }
        if model.selectedShelfFiles.contains(anchorFile), selected.count > 1 {
            return selected
        }
        return [anchorFile]
    }

    private func shelfIconButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverLift(scale: 1.06, hoverOpacity: 1.0)
    }
}

@MainActor
private final class FileShelfDraggingSource: NSObject, NSDraggingSource {
    static let shared = FileShelfDraggingSource()

    var isDragging = false
    var draggedFiles: [URL] = []
    var onDragCompleted: (([URL]) -> Void)?

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool {
        true
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        // If drag completed successfully (not cancelled), remove files from shelf
        if operation != [] {
            onDragCompleted?(draggedFiles)
        }
        draggedFiles = []
        onDragCompleted = nil
    }
}

private enum FileDropDecoder {
    static func loadURLs(from providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) -> Bool {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }

        guard !fileProviders.isEmpty else { return false }

        let collector = URLCollector()
        let group = DispatchGroup()

        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                guard let url = extractURL(from: item) else { return }
                collector.append(url.standardizedFileURL)
            }
        }

        group.notify(queue: .main) {
            completion(Array(Set(collector.values)))
        }
        return true
    }

    nonisolated private static func extractURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL {
            return url
        }

        if let data = item as? Data {
            if let url = URL(dataRepresentation: data, relativeTo: nil) {
                return url
            }
            if let string = String(data: data, encoding: .utf8) {
                return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if let string = item as? String {
            return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return nil
    }
}

private final class URLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }

    var values: [URL] {
        lock.lock()
        let snapshot = urls
        lock.unlock()
        return snapshot
    }
}

struct QuickActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(.white.opacity(0.85))
            .background(Color.white.opacity(isHovering ? 0.14 : 0.08), in: Capsule())
        }
        .buttonStyle(.plain)
        .scaleEffect(isHovering ? 1.03 : 1.0)
        .animation(.easeInOut(duration: 0.14), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

private struct HoverLiftModifier: ViewModifier {
    @State private var isHovering = false

    var scale: CGFloat
    var hoverOpacity: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovering ? scale : 1.0)
            .opacity(isHovering ? hoverOpacity : 1.0)
            .animation(.easeInOut(duration: 0.14), value: isHovering)
            .onHover { hovering in
                isHovering = hovering
            }
    }
}

private extension View {
    func hoverLift(scale: CGFloat = 1.05, hoverOpacity: Double = 1.0) -> some View {
        modifier(HoverLiftModifier(scale: scale, hoverOpacity: hoverOpacity))
    }
}

struct NowPlayingStrip: View {
    @ObservedObject var model: NotchModel

    var body: some View {
        HStack(spacing: 10) {
            // Artwork or source icon
            if let artwork = model.nowPlayingArtwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                    Image(systemName: model.nowPlayingIcon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
                .frame(width: 48, height: 48)
            }

            // Track info + progress
            VStack(alignment: .leading, spacing: 4) {
                Text(model.nowPlayingShortTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.90))

                HStack(spacing: 6) {
                    if !model.nowPlayingSource.isEmpty {
                        Text(model.nowPlayingSource)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.40))
                            .layoutPriority(1)
                    }
                    if let progress = model.nowPlayingProgress {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.08))
                                    .frame(height: 4)
                                Capsule()
                                    .fill(Color.white.opacity(0.40))
                                    .frame(width: max(4, geo.size.width * progress), height: 4)
                            }
                        }
                        .frame(height: 4)
                    }
                }
            }

            Spacer(minLength: 0)

            // Controls
            HStack(spacing: 8) {
                Button { MediaController.previousTrack(source: model.nowPlayingSource) } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 11))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.45))
                .hoverLift(scale: 1.08, hoverOpacity: 1.0)

                Button {
                    MediaController.playPause(source: model.nowPlayingSource)
                    model.nowPlayingIsPlaying.toggle()
                } label: {
                    Image(systemName: model.nowPlayingIsPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 14, weight: .medium))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
                .hoverLift(scale: 1.06, hoverOpacity: 1.0)

                Button { MediaController.nextTrack(source: model.nowPlayingSource) } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 11))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.45))
                .hoverLift(scale: 1.08, hoverOpacity: 1.0)
            }

            // Remaining time
            if let remaining = model.nowPlayingRemainingText {
                Text(remaining)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 0.5))
    }
}

// MARK: - Settings View

private struct SettingsSectionHeader: View {
    let title: String
    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
        )
    }
}

private struct SettingsRow<Trailing: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(iconColor, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct SettingsToggleRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

private struct SettingsRowDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 48)
    }
}

private struct SettingsActionButton: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

struct SettingsView: View {
    @ObservedObject private var preferences = NotchPreferences.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // MARK: General
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionHeader(title: "General")
                    SettingsCard {
                        SettingsToggleRow(
                            icon: "power", iconColor: .green,
                            title: "Launch at Login",
                            subtitle: "Start NotchNook when you log in",
                            isOn: $preferences.launchAtLogin
                        )
                        SettingsRowDivider()
                        SettingsToggleRow(
                            icon: "menubar.rectangle", iconColor: .blue,
                            title: "Menu Bar Icon",
                            subtitle: "Show icon in the menu bar",
                            isOn: $preferences.showMenuBarIcon
                        )
                    }
                }

                // MARK: Profiles
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionHeader(title: "Profiles")
                    SettingsCard {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 10) {
                                Image(systemName: "person.2")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white)
                                    .frame(width: 26, height: 26)
                                    .background(Color.purple, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                Picker("", selection: $preferences.selectedProfile) {
                                    ForEach(NotchProfile.allCases) { profile in
                                        Text(profile.label).tag(profile)
                                    }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                        SettingsRowDivider()
                        SettingsToggleRow(
                            icon: "arrow.triangle.swap", iconColor: .purple,
                            title: "Auto-Switch by App",
                            subtitle: "Gaming/meeting apps apply matching profile",
                            isOn: $preferences.autoProfileByActiveApp
                        )
                    }
                }

                // MARK: Quick Actions
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionHeader(title: "Quick Actions")
                    SettingsCard {
                        SettingsToggleRow(
                            icon: "play.circle", iconColor: .pink,
                            title: "Now Playing + Media",
                            isOn: $preferences.showMediaNowPlaying
                        )
                        SettingsRowDivider()
                        SettingsToggleRow(
                            icon: "speaker.slash", iconColor: .orange,
                            title: "Mute Button",
                            isOn: $preferences.showMuteAction
                        )
                        SettingsRowDivider()
                        SettingsToggleRow(
                            icon: "doc.on.clipboard", iconColor: .teal,
                            title: "File Paste Button",
                            isOn: $preferences.showFilePasteAction
                        )
                    }
                }

                // MARK: System Status
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionHeader(title: "System Status")
                    SettingsCard {
                        SettingsToggleRow(
                            icon: "gauge.with.dots.needle.bottom.50percent", iconColor: .indigo,
                            title: "System Metrics",
                            subtitle: "Show hardware stats in panel",
                            isOn: $preferences.showSystemMetrics
                        )
                        Group {
                            SettingsRowDivider()
                            SettingsToggleRow(
                                icon: "battery.75percent", iconColor: .green,
                                title: "Battery",
                                isOn: $preferences.showBattery
                            )
                            SettingsRowDivider()
                            SettingsToggleRow(
                                icon: "cpu", iconColor: .blue,
                                title: "CPU",
                                isOn: $preferences.showCPU
                            )
                            SettingsRowDivider()
                            SettingsToggleRow(
                                icon: "memorychip", iconColor: .orange,
                                title: "RAM",
                                isOn: $preferences.showRAM
                            )
                            SettingsRowDivider()
                            SettingsToggleRow(
                                icon: "gpu", iconColor: .purple,
                                title: "GPU",
                                isOn: $preferences.showGPU
                            )
                            SettingsRowDivider()
                            SettingsToggleRow(
                                icon: "cloud.sun", iconColor: .cyan,
                                title: "Weather",
                                isOn: $preferences.showWeather
                            )
                        }
                        .disabled(!preferences.showSystemMetrics)
                        .opacity(preferences.showSystemMetrics ? 1.0 : 0.5)
                    }
                }

                // MARK: Panels
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionHeader(title: "Panels")
                    SettingsCard {
                        SettingsToggleRow(
                            icon: "tray", iconColor: .blue,
                            title: "File Shelf",
                            isOn: $preferences.showFileShelf
                        )
                        SettingsRowDivider()
                        SettingsToggleRow(
                            icon: "clipboard", iconColor: .yellow,
                            title: "Clipboard History",
                            subtitle: "Pin & favorite slots",
                            isOn: $preferences.showClipboardHistory
                        )
                        SettingsRowDivider()
                        SettingsToggleRow(
                            icon: "calendar", iconColor: .red,
                            title: "Mini Calendar",
                            subtitle: "Upcoming reminders",
                            isOn: $preferences.showMiniCalendar
                        )
                        SettingsRowDivider()
                        SettingsToggleRow(
                            icon: "timer", iconColor: .mint,
                            title: "Focus Timer",
                            isOn: $preferences.showFocusTimer
                        )
                        Group {
                            SettingsRowDivider()
                            HStack(spacing: 12) {
                                Spacer().frame(width: 36)
                                Stepper("Focus: \(preferences.focusMinutes) min", value: $preferences.focusMinutes, in: 5...120, step: 1)
                                    .font(.system(size: 12))
                                Spacer()
                                Stepper("Break: \(preferences.breakMinutes) min", value: $preferences.breakMinutes, in: 1...60, step: 1)
                                    .font(.system(size: 12))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                        }
                        .disabled(!preferences.showFocusTimer)
                        .opacity(preferences.showFocusTimer ? 1.0 : 0.5)
                    }
                }

                // MARK: Actions
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionHeader(title: "Actions")
                    HStack(spacing: 8) {
                        SettingsActionButton(icon: "arrow.triangle.2.circlepath", title: "Toggle Notch") {
                            NotchWindowController.shared.toggleExpanded()
                        }
                        SettingsActionButton(icon: "display", title: "Move to MacBook") {
                            NotchWindowController.shared.reposition()
                        }
                    }
                    HStack(spacing: 8) {
                        SettingsActionButton(icon: "arrow.down.circle", title: "Check for Updates") {
                            AppDelegate.sharedUpdater?.checkForUpdates(nil)
                        }
                        SettingsActionButton(icon: "checkmark.circle", title: "Apply Profile") {
                            preferences.applySelectedProfile()
                        }
                    }
                    HStack(spacing: 8) {
                        SettingsActionButton(icon: "arrow.counterclockwise", title: "Reset Defaults") {
                            preferences.resetDefaults()
                        }
                        SettingsActionButton(icon: "xmark.circle", title: "Quit NotchNook") {
                            NSApplication.shared.terminate(nil)
                        }
                    }
                }

                Text("Hover trigger: 200\u{00D7}15 pt notch zone on MacBook screen")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, -4)
            }
            .padding(24)
        }
    }
}

private struct BatteryReading {
    let value: String
    let icon: String
}

private enum BatteryStats {
    static func current() -> BatteryReading {
        guard
            let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return BatteryReading(value: "N/A", icon: "battery.100")
        }

        for source in sources {
            guard
                let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                let current = description[kIOPSCurrentCapacityKey as String] as? Int,
                let max = description[kIOPSMaxCapacityKey as String] as? Int,
                max > 0
            else { continue }

            let percent = Int(Double(current) / Double(max) * 100.0)
            let charging = (description[kIOPSIsChargingKey as String] as? Bool) ?? false
            return BatteryReading(value: "\(percent)%", icon: batteryIcon(percent: percent, charging: charging))
        }

        return BatteryReading(value: "N/A", icon: "battery.100")
    }

    private static func batteryIcon(percent: Int, charging: Bool) -> String {
        if charging { return "battery.100.bolt" }
        switch percent {
        case ..<20:
            return "battery.0"
        case ..<45:
            return "battery.25"
        case ..<70:
            return "battery.50"
        case ..<90:
            return "battery.75"
        default:
            return "battery.100"
        }
    }
}

private enum MemoryStats {
    static func usageString() -> String? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }

        let pageSizeBytes = UInt64(pageSize)
        let usedPages = UInt64(stats.active_count + stats.inactive_count + stats.wire_count + stats.compressor_page_count)
        let usedBytes = usedPages * pageSizeBytes
        return byteCountToGB(usedBytes)
    }

    private static func byteCountToGB(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return String(format: "%.1f GB", gb)
    }
}

private enum GPUStats {
    static func usageString() -> String? {
        if let value = readUtilization(from: "IOAccelerator") {
            return value
        }
        if let value = readUtilization(from: "AGXAccelerator") {
            return value
        }
        return nil
    }

    private static func readUtilization(from serviceName: String) -> String? {
        guard let matching = IOServiceMatching(serviceName) else { return nil }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard
            let dictionary = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any]
        else {
            return nil
        }

        let numericKeys = ["Device Utilization %", "GPU Core Utilization", "GPU Busy"]

        for key in numericKeys {
            if let number = dictionary[key] as? NSNumber {
                return "\(number.intValue)%"
            }
            if let doubleValue = dictionary[key] as? Double {
                return "\(Int(doubleValue.rounded()))%"
            }
        }

        return nil
    }
}

private final class CPUSampler {
    private var previous: host_cpu_load_info_data_t?

    func usagePercentString() -> String? {
        guard let current = readLoadInfo() else { return nil }
        defer { previous = current }

        guard let previous else {
            return "0%"
        }

        let user = Double(current.cpu_ticks.0 - previous.cpu_ticks.0)
        let system = Double(current.cpu_ticks.1 - previous.cpu_ticks.1)
        let idle = Double(current.cpu_ticks.2 - previous.cpu_ticks.2)
        let nice = Double(current.cpu_ticks.3 - previous.cpu_ticks.3)

        let total = user + system + idle + nice
        guard total > 0 else { return nil }

        let usage = ((user + system + nice) / total) * 100.0
        return "\(Int(usage.rounded()))%"
    }

    private func readLoadInfo() -> host_cpu_load_info_data_t? {
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()

        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(size)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &size)
            }
        }

        return result == KERN_SUCCESS ? info : nil
    }
}

private struct NetworkSample {
    let down: String
    let up: String
    let vpnEnabled: Bool
}

private final class NetworkSampler {
    private var previous: (timestamp: Date, rx: UInt64, tx: UInt64)?

    func sample() -> NetworkSample {
        guard let totals = networkByteTotals() else {
            return NetworkSample(down: "--", up: "--", vpnEnabled: false)
        }

        let now = Date()
        let vpn = isVPNActive()

        guard let previous else {
            self.previous = (now, totals.rx, totals.tx)
            return NetworkSample(down: "0 B/s", up: "0 B/s", vpnEnabled: vpn)
        }

        let elapsed = now.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else {
            return NetworkSample(down: "--", up: "--", vpnEnabled: vpn)
        }

        let deltaDown = totals.rx > previous.rx ? totals.rx - previous.rx : 0
        let deltaUp = totals.tx > previous.tx ? totals.tx - previous.tx : 0

        self.previous = (now, totals.rx, totals.tx)

        let downPerSecond = Double(deltaDown) / elapsed
        let upPerSecond = Double(deltaUp) / elapsed

        return NetworkSample(
            down: formatBytesPerSecond(downPerSecond),
            up: formatBytesPerSecond(upPerSecond),
            vpnEnabled: vpn
        )
    }

    private func networkByteTotals() -> (rx: UInt64, tx: UInt64)? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        var totalRX: UInt64 = 0
        var totalTX: UInt64 = 0

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee

            let flags = Int32(interface.ifa_flags)
            if (flags & IFF_UP) == 0 || (flags & IFF_LOOPBACK) != 0 {
                cursor = interface.ifa_next
                continue
            }

            guard let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) else {
                cursor = interface.ifa_next
                continue
            }

            guard let dataPtr = interface.ifa_data else {
                cursor = interface.ifa_next
                continue
            }

            let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
            totalRX += UInt64(data.ifi_ibytes)
            totalTX += UInt64(data.ifi_obytes)
            cursor = interface.ifa_next
        }

        return (totalRX, totalTX)
    }

    private func isVPNActive() -> Bool {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return false }
        defer { freeifaddrs(pointer) }

        let vpnPrefixes = ["utun", "ppp", "ipsec", "tun", "tap"]
        var cursor: UnsafeMutablePointer<ifaddrs>? = first

        while let current = cursor {
            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)
            if (flags & IFF_UP) == 0 {
                cursor = interface.ifa_next
                continue
            }

            let name = String(cString: interface.ifa_name)
            if vpnPrefixes.contains(where: { name.hasPrefix($0) }) {
                return true
            }
            cursor = interface.ifa_next
        }

        return false
    }

    private func formatBytesPerSecond(_ value: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var amount = value
        var index = 0

        while amount >= 1024 && index < units.count - 1 {
            amount /= 1024
            index += 1
        }

        if index == 0 {
            return "\(Int(amount)) \(units[index])"
        }
        return String(format: "%.1f %@", amount, units[index])
    }
}

private enum PingService {
    static func singlePingAsync(host: String) async -> String? {
        await Task.detached(priority: .utility) {
            singlePing(host: host)
        }.value
    }

    static func singlePing(host: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = ["-c", "1", "-W", "1000", host]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let range = text.range(of: "time=") else { return nil }

        let suffix = text[range.upperBound...]
        let value = suffix.prefix { $0.isNumber || $0 == "." }
        guard let milliseconds = Double(value) else { return nil }
        return "\(Int(milliseconds.rounded())) ms"
    }
}

private struct WeatherSnapshot {
    let value: String
    let icon: String
}

private enum WeatherService {
    static func fetchCurrent() async -> WeatherSnapshot? {
        guard let url = URL(string: "https://wttr.in/?format=j1") else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 4

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                return nil
            }

            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard let condition = decoded.current_condition.first else { return nil }

            let description = condition.weatherDesc.first?.value ?? ""
            return WeatherSnapshot(value: "\(condition.temp_F)°F", icon: icon(for: description))
        } catch {
            return nil
        }
    }

    private static func icon(for description: String) -> String {
        let lowercased = description.lowercased()
        if lowercased.contains("rain") || lowercased.contains("drizzle") {
            return "cloud.rain"
        }
        if lowercased.contains("snow") {
            return "cloud.snow"
        }
        if lowercased.contains("thunder") || lowercased.contains("storm") {
            return "cloud.bolt.rain"
        }
        if lowercased.contains("cloud") {
            return "cloud"
        }
        if lowercased.contains("fog") || lowercased.contains("mist") {
            return "cloud.fog"
        }
        return "sun.max"
    }

    private struct Response: Decodable {
        let current_condition: [Condition]

        struct Condition: Decodable {
            let temp_F: String
            let weatherDesc: [DescriptionValue]
        }

        struct DescriptionValue: Decodable {
            let value: String
        }
    }
}

private struct NowPlayingInfo {
    let track: String
    let source: String
    let isPlaying: Bool
    let artworkURL: String?
    let artworkData: Data?
    let duration: Double?
    let position: Double?
    let fetchTime: Date
}

private enum NowPlayingService {
    static func currentTrack() -> String? {
        if let info = currentInfo() {
            return "\(info.source) • \(info.track)"
        }
        return nil
    }

    static func currentInfo() -> NowPlayingInfo? {
        // Try native apps first — short-circuit within each app but collect across apps
        var paused: NowPlayingInfo? = nil

        // Spotify (try name, then bundle ID)
        if let info = tryAppleScript(spotifyEnhancedScript, source: "Spotify", durationInMs: true)
            ?? tryAppleScript(spotifyBundleIDEnhancedScript, source: "Spotify", durationInMs: true) {
            if info.isPlaying { return info }
            if paused == nil { paused = info }
        }

        // Music (try name, then bundle ID)
        if let info = tryAppleScript(musicEnhancedScript, source: "Music", durationInMs: false)
            ?? tryAppleScript(musicBundleIDEnhancedScript, source: "Music", durationInMs: false) {
            if info.isPlaying { return info }
            if paused == nil { paused = info }
        }

        // Browser YouTube tabs
        let browserSources: [(String, String)] = [
            (braveYouTubeScript, "YouTube (Brave)"),
            (chromeYouTubeScript, "YouTube (Chrome)"),
            (safariYouTubeScript, "YouTube (Safari)"),
        ]
        for (script, source) in browserSources {
            if let tabTitle = run(script: script), !tabTitle.isEmpty {
                let mrInfo = MediaRemoteNowPlayingFallback.currentInfo()
                let info = NowPlayingInfo(
                    track: sanitize(tabTitle),
                    source: source,
                    isPlaying: mrInfo?.isPlaying ?? true,
                    artworkURL: nil,
                    artworkData: mrInfo?.artworkData,
                    duration: mrInfo?.duration,
                    position: mrInfo?.position,
                    fetchTime: Date()
                )
                if info.isPlaying { return info }
                if paused == nil { paused = info }
            }
        }

        // Nothing actively playing — try MediaRemote for system's last active session
        if let mrInfo = MediaRemoteNowPlayingFallback.currentInfo(), mrInfo.isPlaying {
            return mrInfo
        }

        // Fall back to first paused source, or MediaRemote paused info
        return paused ?? MediaRemoteNowPlayingFallback.currentInfo()
    }

    private static func tryAppleScript(_ script: String, source: String, durationInMs: Bool) -> NowPlayingInfo? {
        guard let raw = run(script: script), !raw.isEmpty else { return nil }
        return parseEnhancedResult(raw, source: source, durationInMs: durationInMs)
    }

    private static func parseEnhancedResult(_ raw: String, source: String, durationInMs: Bool) -> NowPlayingInfo? {
        let parts = raw.components(separatedBy: "\t")
        guard parts.count >= 6 else { return nil }
        let isPlaying = parts[0] == "playing"
        let artworkURL = parts[1].isEmpty ? nil : parts[1]
        let rawDuration = Double(parts[2]) ?? 0
        let duration = durationInMs ? rawDuration / 1000.0 : rawDuration
        let position = Double(parts[3]) ?? 0
        let artist = parts[4]
        let title = parts.dropFirst(5).joined(separator: "\t")
        let track = artist.isEmpty ? title : "\(artist) — \(title)"
        guard !track.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return NowPlayingInfo(
            track: sanitize(track),
            source: source,
            isPlaying: isPlaying,
            artworkURL: artworkURL,
            artworkData: nil,
            duration: duration > 0 ? duration : nil,
            position: position > 0 ? position : nil,
            fetchTime: Date()
        )
    }

    private static func sanitize(_ raw: String) -> String {
        var value = raw
            .replacingOccurrences(of: " - YouTube", with: "")
            .replacingOccurrences(of: "— YouTube", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if value.count > 90 {
            value = String(value.prefix(87)) + "..."
        }
        return value
    }

    private static func run(script: String) -> String? {
        return runViaOSAScript(script)
    }

    private static func runViaOSAScript(_ script: String) -> String? {
        let lines = script
            .split(whereSeparator: \.isNewline)
            .map { String($0) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !lines.isEmpty else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")

        var args: [String] = []
        for line in lines {
            args.append("-e")
            args.append(line)
        }
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            return nil
        }

        // Timeout: kill process if it takes longer than 2 seconds
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 2.0)
        timer.setEventHandler { process.terminate() }
        timer.resume()
        process.waitUntilExit()
        timer.cancel()

        guard process.terminationStatus == 0 else { return nil }
        guard let data = try? stdout.fileHandleForReading.readToEnd() else { return nil }
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    private static let spotifyEnhancedScript = """
    if application "Spotify" is running then
        tell application "Spotify"
            set playerState to player state as text
            if playerState is "playing" or playerState is "paused" then
                set sep to ASCII character 9
                try
                    set trackArtist to artist of current track
                on error
                    set trackArtist to ""
                end try
                try
                    set trackName to name of current track
                on error
                    set trackName to ""
                end try
                try
                    set artURL to artwork url of current track
                on error
                    set artURL to ""
                end try
                try
                    set trackDuration to duration of current track
                on error
                    set trackDuration to 0
                end try
                try
                    set trackPosition to player position
                on error
                    set trackPosition to 0
                end try
                return playerState & sep & artURL & sep & (trackDuration as text) & sep & (trackPosition as text) & sep & trackArtist & sep & trackName
            end if
        end tell
    end if
    return ""
    """

    private static let spotifyBundleIDEnhancedScript = """
    if application id "com.spotify.client" is running then
        tell application id "com.spotify.client"
            set playerState to player state as text
            if playerState is "playing" or playerState is "paused" then
                set sep to ASCII character 9
                try
                    set trackArtist to artist of current track
                on error
                    set trackArtist to ""
                end try
                try
                    set trackName to name of current track
                on error
                    set trackName to ""
                end try
                try
                    set artURL to artwork url of current track
                on error
                    set artURL to ""
                end try
                try
                    set trackDuration to duration of current track
                on error
                    set trackDuration to 0
                end try
                try
                    set trackPosition to player position
                on error
                    set trackPosition to 0
                end try
                return playerState & sep & artURL & sep & (trackDuration as text) & sep & (trackPosition as text) & sep & trackArtist & sep & trackName
            end if
        end tell
    end if
    return ""
    """

    private static let musicEnhancedScript = """
    if application "Music" is running then
        tell application "Music"
            set playerState to player state as text
            if playerState is "playing" or playerState is "paused" then
                set sep to ASCII character 9
                try
                    set trackArtist to artist of current track
                on error
                    set trackArtist to ""
                end try
                try
                    set trackName to name of current track
                on error
                    set trackName to ""
                end try
                try
                    set trackDuration to duration of current track
                on error
                    set trackDuration to 0
                end try
                try
                    set trackPosition to player position
                on error
                    set trackPosition to 0
                end try
                return playerState & sep & "" & sep & (trackDuration as text) & sep & (trackPosition as text) & sep & trackArtist & sep & trackName
            end if
        end tell
    end if
    return ""
    """

    private static let musicBundleIDEnhancedScript = """
    if application id "com.apple.Music" is running then
        tell application id "com.apple.Music"
            set playerState to player state as text
            if playerState is "playing" or playerState is "paused" then
                set sep to ASCII character 9
                try
                    set trackArtist to artist of current track
                on error
                    set trackArtist to ""
                end try
                try
                    set trackName to name of current track
                on error
                    set trackName to ""
                end try
                try
                    set trackDuration to duration of current track
                on error
                    set trackDuration to 0
                end try
                try
                    set trackPosition to player position
                on error
                    set trackPosition to 0
                end try
                return playerState & sep & "" & sep & (trackDuration as text) & sep & (trackPosition as text) & sep & trackArtist & sep & trackName
            end if
        end tell
    end if
    return ""
    """

    private static let safariYouTubeScript = """
    if application "Safari" is running then
        tell application "Safari"
            repeat with w in windows
                repeat with t in tabs of w
                    set tabTitle to name of t
                    set tabURL to URL of t
                    if tabURL contains "youtube.com" or tabURL contains "music.youtube.com" then
                        return tabTitle
                    end if
                end repeat
            end repeat
        end tell
    end if
    return ""
    """

    private static let chromeYouTubeScript = """
    if application "Google Chrome" is running then
        tell application "Google Chrome"
            repeat with w in windows
                repeat with t in tabs of w
                    set tabTitle to title of t
                    set tabURL to URL of t
                    if tabURL contains "youtube.com" or tabURL contains "music.youtube.com" then
                        return tabTitle
                    end if
                end repeat
            end repeat
        end tell
    end if
    return ""
    """

    private static let braveYouTubeScript = """
    if application "Brave Browser" is running then
        tell application "Brave Browser"
            repeat with w in windows
                repeat with t in tabs of w
                    set tabTitle to title of t
                    set tabURL to URL of t
                    if tabURL contains "youtube.com" or tabURL contains "music.youtube.com" then
                        return tabTitle
                    end if
                end repeat
            end repeat
        end tell
    end if
    return ""
    """
}

private enum MediaRemoteNowPlayingFallback {
    private typealias GetNowPlayingInfoFunction = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void

    private static let frameworkPaths = [
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
        "/System/Library/PrivateFrameworks/MediaRemote.framework/Versions/A/MediaRemote",
    ]
    private static let getNowPlayingInfo: GetNowPlayingInfoFunction? = {
        for path in frameworkPaths {
            guard let handle = dlopen(path, RTLD_LAZY) else { continue }

            if let symbol = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
                return unsafeBitCast(symbol, to: GetNowPlayingInfoFunction.self)
            }

            if let symbol = dlsym(handle, "MRMediaRemoteCopyNowPlayingInfo") {
                return unsafeBitCast(symbol, to: GetNowPlayingInfoFunction.self)
            }
        }
        return nil
    }()

    static func currentTrack() -> String? {
        guard let info = currentInfo() else { return nil }
        return "\(info.source) • \(info.track)"
    }

    static func currentInfo() -> NowPlayingInfo? {
        guard let info = nowPlayingInfo() else { return nil }

        guard let title = firstString(
            in: info,
            keys: [
                "kMRMediaRemoteNowPlayingInfoTitle",
                "title",
                "Title",
            ]
        ) else {
            return nil
        }

        let artist = firstString(
            in: info,
            keys: [
                "kMRMediaRemoteNowPlayingInfoArtist",
                "artist",
                "Artist",
            ]
        )
        let bundleID = firstString(
            in: info,
            keys: [
                "kMRMediaRemoteNowPlayingInfoOriginClientBundleIdentifier",
                "kMRMediaRemoteNowPlayingInfoClientBundleIdentifier",
                "kMRMediaRemoteNowPlayingInfoApplicationBundleIdentifier",
                "bundleIdentifier",
            ]
        )?.lowercased()

        let playbackRate = firstNumber(
            in: info,
            keys: ["kMRMediaRemoteNowPlayingInfoPlaybackRate", "playbackRate"]
        )
        let isPlaying = (playbackRate ?? 0) > 0

        let duration = firstNumber(
            in: info,
            keys: ["kMRMediaRemoteNowPlayingInfoDuration", "duration", "Duration"]
        )
        let position = firstNumber(
            in: info,
            keys: ["kMRMediaRemoteNowPlayingInfoElapsedTime", "elapsedTime", "ElapsedTime"]
        )

        var artworkData: Data? = nil
        for key in ["kMRMediaRemoteNowPlayingInfoArtworkData", "artworkData", "ArtworkData"] {
            if let data = info[key] as? Data {
                artworkData = data
                break
            }
        }

        let track = [artist, title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")

        guard !track.isEmpty else { return nil }

        let source = sourceLabel(bundleID: bundleID) ?? "Now Playing"

        return NowPlayingInfo(
            track: track,
            source: source,
            isPlaying: isPlaying,
            artworkURL: nil,
            artworkData: artworkData,
            duration: duration,
            position: position,
            fetchTime: Date()
        )
    }

    private static func nowPlayingInfo(timeout: TimeInterval = 0.3) -> [String: Any]? {
        guard let getNowPlayingInfo else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        var captured: [String: Any]?

        getNowPlayingInfo(DispatchQueue.global(qos: .userInitiated)) { info in
            defer { semaphore.signal() }
            guard let info else { return }

            let dictionary = info as NSDictionary
            var mapped: [String: Any] = [:]
            for (key, value) in dictionary {
                mapped[String(describing: key)] = value
            }
            captured = mapped
        }

        _ = semaphore.wait(timeout: .now() + timeout)
        return captured
    }

    private static func isLikelyPlaying(info: [String: Any]) -> Bool {
        guard let playbackRate = firstNumber(
            in: info,
            keys: [
                "kMRMediaRemoteNowPlayingInfoPlaybackRate",
                "playbackRate",
            ]
        ) else {
            return true
        }
        return playbackRate > 0
    }

    private static func firstString(in info: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = info[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        let lowercased = Dictionary(uniqueKeysWithValues: info.map { ($0.key.lowercased(), $0.value) })
        for key in keys.map({ $0.lowercased() }) {
            if let value = lowercased[key] as? String {
                let trimmed = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        let fallbackHints: [String]
        if keys.contains(where: { $0.localizedCaseInsensitiveContains("title") }) {
            fallbackHints = ["title", "name", "track"]
        } else if keys.contains(where: { $0.localizedCaseInsensitiveContains("artist") }) {
            fallbackHints = ["artist", "author", "performer"]
        } else if keys.contains(where: { $0.localizedCaseInsensitiveContains("bundle") }) {
            fallbackHints = ["bundle", "client", "origin", "application"]
        } else {
            fallbackHints = []
        }

        if !fallbackHints.isEmpty {
            for (key, value) in info {
                guard let text = value as? String else { continue }
                let loweredKey = key.lowercased()
                guard fallbackHints.contains(where: { loweredKey.contains($0) }) else { continue }
                let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    private static func firstNumber(in info: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = info[key] as? NSNumber {
                return value.doubleValue
            }
            if let value = info[key] as? Double {
                return value
            }
            if let value = info[key] as? Int {
                return Double(value)
            }
            if let value = info[key] as? String, let parsed = Double(value) {
                return parsed
            }
        }
        return nil
    }

    private static func sourceLabel(bundleID: String?) -> String? {
        guard let bundleID else { return nil }
        if bundleID.contains("spotify") {
            return "Spotify"
        }
        if bundleID.contains("music") {
            return "Music"
        }
        if bundleID.contains("brave") {
            return "Brave"
        }
        if bundleID.contains("chrome") {
            return "Chrome"
        }
        if bundleID.contains("safari") {
            return "Safari"
        }
        return nil
    }
}

private enum MediaController {
    // MRMediaRemoteSendCommand constants
    private static let kMRPlay: Int = 0
    private static let kMRPause: Int = 1
    private static let kMRTogglePlayPause: Int = 2
    private static let kMRNextTrack: Int = 4
    private static let kMRPreviousTrack: Int = 5

    private typealias SendCommandFunction = @convention(c) (Int, UnsafeRawPointer?) -> Bool

    private static let sendCommand: SendCommandFunction? = {
        let paths = [
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            "/System/Library/PrivateFrameworks/MediaRemote.framework/Versions/A/MediaRemote",
        ]
        for path in paths {
            guard let handle = dlopen(path, RTLD_LAZY) else { continue }
            if let symbol = dlsym(handle, "MRMediaRemoteSendCommand") {
                return unsafeBitCast(symbol, to: SendCommandFunction.self)
            }
        }
        return nil
    }()

    static func playPause(source: String = "") {
        if source.contains("Spotify") {
            runAppleScript("""
            if application "Spotify" is running then
                tell application "Spotify" to playpause
            end if
            """)
        } else if source == "Music" {
            runAppleScript("""
            if application "Music" is running then
                tell application "Music" to playpause
            end if
            """)
        } else {
            _ = sendCommand?(kMRTogglePlayPause, nil)
        }
    }

    static func nextTrack(source: String = "") {
        if source.contains("Spotify") {
            runAppleScript("""
            if application "Spotify" is running then
                tell application "Spotify" to next track
            end if
            """)
        } else if source == "Music" {
            runAppleScript("""
            if application "Music" is running then
                tell application "Music" to next track
            end if
            """)
        } else {
            _ = sendCommand?(kMRNextTrack, nil)
        }
    }

    static func previousTrack(source: String = "") {
        if source.contains("Spotify") {
            runAppleScript("""
            if application "Spotify" is running then
                tell application "Spotify"
                    if player position > 3 then
                        set player position to 0
                    else
                        previous track
                    end if
                end tell
            end if
            """)
        } else if source == "Music" {
            runAppleScript("""
            if application "Music" is running then
                tell application "Music" to back track
            end if
            """)
        } else {
            _ = sendCommand?(kMRPreviousTrack, nil)
        }
    }

    static func toggleMute() {
        runAppleScript("""
        set currentSettings to get volume settings
        set volume output muted not (output muted of currentSettings)
        """)
    }

    static func runAppleScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let lines = source
                .split(whereSeparator: \.isNewline)
                .map { String($0) }
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            guard !lines.isEmpty else { return }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            var args: [String] = []
            for line in lines {
                args.append("-e")
                args.append(line)
            }
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                return
            }

            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + 3.0)
            timer.setEventHandler { process.terminate() }
            timer.resume()
            process.waitUntilExit()
            timer.cancel()
        }
    }
}
