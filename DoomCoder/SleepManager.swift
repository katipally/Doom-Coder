import Foundation
import IOKit.pwr_mgt
import CoreGraphics
import AppKit
import ServiceManagement

// MARK: - Types

enum DoomCoderMode: String, CaseIterable {
    case full      = "full"
    case autoDim   = "autoDim"
    case screenOff = "screenOff"

    var displayName: String {
        switch self {
        case .full:      return "Full Mode"
        case .autoDim:   return "Auto-Dim"
        case .screenOff: return "Screen Off"
        }
    }

    var description: String {
        switch self {
        case .full:      return "Screen stays fully on"
        case .autoDim:   return "Dims screen when idle"
        case .screenOff: return "Turns screen off, Mac stays awake"
        }
    }
}

// MARK: - SleepManager

@Observable
@MainActor
final class SleepManager {

    // MARK: Public state

    private(set) var isActive = false
    private(set) var elapsedTimeString = ""
    private(set) var thermalStateText = "🟢 Normal"
    private(set) var sessionTimerRemainingText: String?
    private(set) var isDimmed = false
    private(set) var isScreenOff = false
    private(set) var screenOffCountdown: Int? = nil  // nil = not counting, N = seconds remaining
    private(set) var hasAccessibilityPermission: Bool = false

    // MARK: User settings (persisted to UserDefaults)

    var mode: DoomCoderMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "doomcoder.mode")
            handleModeChange()
        }
    }

    var idleTimeoutMinutes: Int {
        didSet { UserDefaults.standard.set(idleTimeoutMinutes, forKey: "doomcoder.idleTimeout") }
    }

    var dimBrightnessPercent: Int {
        didSet { UserDefaults.standard.set(dimBrightnessPercent, forKey: "doomcoder.dimBrightness") }
    }

    var sessionTimerHours: Int {
        didSet {
            UserDefaults.standard.set(sessionTimerHours, forKey: "doomcoder.sessionTimer")
            resetSessionTimer()
        }
    }

    var screenOffRearmMinutes: Int {
        didSet { UserDefaults.standard.set(screenOffRearmMinutes, forKey: "doomcoder.screenOffRearm") }
    }

    // MARK: Launch at Login (via SMAppService)

    var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func toggleLaunchAtLogin() {
        do {
            if isLaunchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Silently ignore — toggle will reflect actual SMAppService state
        }
    }

    // MARK: Accessibility (required for global Fn+F1 hotkey)

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        hasAccessibilityPermission = AXIsProcessTrustedWithOptions(nil)
    }

    // MARK: Private — gamma state

    private typealias GammaState = (
        rMin: CGGammaValue, rMax: CGGammaValue, rGamma: CGGammaValue,
        gMin: CGGammaValue, gMax: CGGammaValue, gGamma: CGGammaValue,
        bMin: CGGammaValue, bMax: CGGammaValue, bGamma: CGGammaValue
    )
    private var savedGamma: GammaState?

    private var activeSince: Date?
    private var sessionEndDate: Date?

    // MARK: Private — stored nonisolated for deinit access

    @ObservationIgnored nonisolated(unsafe) private var assertionID: IOPMAssertionID = 0
    @ObservationIgnored nonisolated(unsafe) private var _elapsedTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) private var _idleTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) private var _sessionTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) private var thermalObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var _screenOffTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var _screenWakeObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var _hotkeyMonitor: Any?

    // MARK: Init

    init() {
        let savedMode = UserDefaults.standard.string(forKey: "doomcoder.mode") ?? DoomCoderMode.full.rawValue
        self.mode            = DoomCoderMode(rawValue: savedMode) ?? .full
        self.idleTimeoutMinutes  = UserDefaults.standard.object(forKey: "doomcoder.idleTimeout")    as? Int ?? 5
        self.dimBrightnessPercent = UserDefaults.standard.object(forKey: "doomcoder.dimBrightness") as? Int ?? 10
        self.sessionTimerHours   = UserDefaults.standard.object(forKey: "doomcoder.sessionTimer")   as? Int ?? 0
        self.screenOffRearmMinutes = UserDefaults.standard.object(forKey: "doomcoder.screenOffRearm") as? Int ?? 10

        startThermalMonitoring()
        updateThermalState()
        setupGlobalHotkey()
    }

    // MARK: - Global Hotkey (Fn+F1 = keyCode 122)
    // Requires Accessibility permission. Works when Fn+F1 pressed (not regular F1/brightness key).

    private func setupGlobalHotkey() {
        hasAccessibilityPermission = AXIsProcessTrustedWithOptions(nil)
        guard hasAccessibilityPermission else { return }

        _hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 122 else { return }
            Task { @MainActor [weak self] in self?.toggle() }
        }
    }

    // MARK: - Enable / Disable / Toggle

    func enable() {
        guard !isActive else { return }
        guard let id = createAssertion() else { return }
        assertionID = id
        isActive = true
        activeSince = .now
        startElapsedTimer()
        resetSessionTimer()
        switch mode {
        case .full:      break
        case .autoDim:   startIdleMonitoring()
        case .screenOff: startScreenOff()
        }
    }

    func disable() {
        guard isActive else { return }
        stopScreenOff()
        restoreGamma()
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
        activeSince = nil
        elapsedTimeString = ""
        isDimmed = false
        isScreenOff = false
        screenOffCountdown = nil
        sessionTimerRemainingText = nil
        sessionEndDate = nil
        stopElapsedTimer()
        stopIdleMonitoring()
        stopSessionTimer()
    }

    func toggle() { isActive ? disable() : enable() }

    // MARK: - Assertion Management

    private func createAssertion() -> IOPMAssertionID? {
        var id: IOPMAssertionID = 0
        // Screen-Off mode: prevent system sleep only (display is allowed to sleep)
        // Other modes: prevent both display and system idle sleep
        let type: CFString = (mode == .screenOff)
            ? (kIOPMAssertionTypePreventSystemSleep as CFString)
            : (kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString)
        let reason = "DoomCoder: Keeping Mac alive for AI coding session" as CFString
        let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id)
        return result == kIOReturnSuccess ? id : nil
    }

    // MARK: - Mode Change

    private func handleModeChange() {
        guard isActive else { return }

        // Swap the IOPMAssertion for the new mode (different assertion types)
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
        }
        guard let id = createAssertion() else { disable(); return }
        assertionID = id

        // Stop all mode-specific activity
        restoreGamma()
        isDimmed = false
        stopIdleMonitoring()
        stopScreenOff()

        // Start mode-specific activity
        switch mode {
        case .full:      break
        case .autoDim:   startIdleMonitoring()
        case .screenOff: startScreenOff()
        }
    }

    // MARK: - Elapsed Time

    private func startElapsedTimer() {
        _elapsedTimer?.invalidate()
        updateElapsedTime()
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateElapsedTime()
                self?.updateSessionTimerRemaining()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        _elapsedTimer = t
    }

    private func stopElapsedTimer() {
        _elapsedTimer?.invalidate()
        _elapsedTimer = nil
    }

    private func updateElapsedTime() {
        guard let since = activeSince else { return }
        let total = Int(Date.now.timeIntervalSince(since))
        let h = total / 3600
        let m = (total % 3600) / 60
        elapsedTimeString = h > 0
            ? "Active for \(h)h \(m)m"
            : "Active for \(m < 1 ? "<1" : "\(m)")m"
    }

    // MARK: - Screen-Off Mode
    // Uses pmset displaysleepnow to turn off the display while keeping the Mac fully awake.
    // System stays awake via kIOPMAssertionTypePreventSystemSleep assertion.

    private func startScreenOff() {
        screenOffCountdown = 5
        _screenOffTask = Task { @MainActor [weak self] in
            // 5-second countdown before turning screen off
            for remaining in stride(from: 4, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.isActive, self.mode == .screenOff else { return }
                self.screenOffCountdown = remaining
            }
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled, self.isActive, self.mode == .screenOff else { return }
            self.screenOffCountdown = nil
            self.executeScreenOff()
        }
    }

    private func executeScreenOff() {
        // Deregister any previous wake observer before registering a new one
        if let obs = _screenWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            _screenWakeObserver = nil
        }

        isScreenOff = true

        // pmset displaysleepnow: turns off display only, system stays awake
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError  = FileHandle.nullDevice
        try? task.run()

        // When display wakes (any user input), macOS fires screensDidWakeNotification
        _screenWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive, self.mode == .screenOff, self.isScreenOff else { return }
                if let obs = self._screenWakeObserver {
                    NSWorkspace.shared.notificationCenter.removeObserver(obs)
                    self._screenWakeObserver = nil
                }
                self.isScreenOff = false
                self.startRearmMonitoring()
            }
        }
    }

    // Polls idle state every 30s; re-arms screen-off when user has been idle for screenOffRearmMinutes.
    private func startRearmMonitoring() {
        _screenOffTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled,
                      self.isActive, self.mode == .screenOff, !self.isScreenOff else { break }
                self.checkRearm()
            }
        }
    }

    private func checkRearm() {
        let idleTimes: [CFTimeInterval] = [
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .rightMouseDown),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel),
        ]
        let minIdle = idleTimes.min() ?? 0
        let threshold = Double(screenOffRearmMinutes * 60)
        if minIdle >= threshold {
            executeScreenOff()
        }
    }

    private func stopScreenOff() {
        _screenOffTask?.cancel()
        _screenOffTask = nil
        if let obs = _screenWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            _screenWakeObserver = nil
        }
        isScreenOff = false
        screenOffCountdown = nil
    }

    // MARK: - Auto-Dim (Idle Monitoring + CoreGraphics Gamma Dimming)
    // Uses CGSetDisplayTransferByFormula (software gamma overlay) — works on all Macs
    // including Apple Silicon where IODisplaySetFloatParameter returns zero services.

    private func startIdleMonitoring() {
        stopIdleMonitoring()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdleState() }
        }
        RunLoop.main.add(t, forMode: .common)
        _idleTimer = t
    }

    private func stopIdleMonitoring() {
        _idleTimer?.invalidate()
        _idleTimer = nil
    }

    private func checkIdleState() {
        let idleTimes: [CFTimeInterval] = [
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .rightMouseDown),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel),
        ]
        let minIdle = idleTimes.min() ?? 0
        let threshold = Double(idleTimeoutMinutes * 60)

        if minIdle >= threshold && !isDimmed {
            dimScreen()
        } else if minIdle < threshold && isDimmed {
            restoreGamma()
            isDimmed = false
        }
    }

    private func dimScreen() {
        let display = CGMainDisplayID()
        var rMin: CGGammaValue = 0, rMax: CGGammaValue = 0, rGamma: CGGammaValue = 0
        var gMin: CGGammaValue = 0, gMax: CGGammaValue = 0, gGamma: CGGammaValue = 0
        var bMin: CGGammaValue = 0, bMax: CGGammaValue = 0, bGamma: CGGammaValue = 0
        CGGetDisplayTransferByFormula(display, &rMin, &rMax, &rGamma, &gMin, &gMax, &gGamma, &bMin, &bMax, &bGamma)
        savedGamma = (rMin, rMax, rGamma, gMin, gMax, gGamma, bMin, bMax, bGamma)
        let dim = CGGammaValue(dimBrightnessPercent) / 100.0
        CGSetDisplayTransferByFormula(display, rMin, dim, rGamma, gMin, dim, gGamma, bMin, dim, bGamma)
        isDimmed = true
    }

    private func restoreGamma() {
        guard let g = savedGamma else { return }
        CGSetDisplayTransferByFormula(
            CGMainDisplayID(),
            g.rMin, g.rMax, g.rGamma,
            g.gMin, g.gMax, g.gGamma,
            g.bMin, g.bMax, g.bGamma
        )
        savedGamma = nil
    }

    // MARK: - Thermal Monitoring

    private func startThermalMonitoring() {
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateThermalState() }
        }
    }

    private func updateThermalState() {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  thermalStateText = "🟢 Normal"
        case .fair:     thermalStateText = "🟡 Fair"
        case .serious:  thermalStateText = "🟠 Serious"
        case .critical: thermalStateText = "🔴 Critical"
        @unknown default: thermalStateText = "⚪ Unknown"
        }
    }

    // MARK: - Session Timer

    private func resetSessionTimer() {
        stopSessionTimer()
        sessionTimerRemainingText = nil
        sessionEndDate = nil
        guard isActive, sessionTimerHours > 0 else { return }
        sessionEndDate = Date.now.addingTimeInterval(Double(sessionTimerHours) * 3600)
        updateSessionTimerRemaining()
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSessionTimer() }
        }
        RunLoop.main.add(t, forMode: .common)
        _sessionTimer = t
    }

    private func stopSessionTimer() {
        _sessionTimer?.invalidate()
        _sessionTimer = nil
    }

    private func checkSessionTimer() {
        guard let end = sessionEndDate else { return }
        if Date.now >= end { disable() }
        else { updateSessionTimerRemaining() }
    }

    private func updateSessionTimerRemaining() {
        guard let end = sessionEndDate else { sessionTimerRemainingText = nil; return }
        let remaining = Int(end.timeIntervalSince(.now))
        guard remaining > 0 else { sessionTimerRemainingText = nil; return }
        let h = remaining / 3600
        let m = (remaining % 3600) / 60
        sessionTimerRemainingText = h > 0 ? "Auto-disable in \(h)h \(m)m" : "Auto-disable in \(m)m"
    }

    // MARK: - Cleanup

    deinit {
        _screenOffTask?.cancel()
        if assertionID != 0 { IOPMAssertionRelease(assertionID) }
        _elapsedTimer?.invalidate()
        _idleTimer?.invalidate()
        _sessionTimer?.invalidate()
        if let obs = thermalObserver  { NotificationCenter.default.removeObserver(obs) }
        if let obs = _screenWakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let monitor = _hotkeyMonitor { NSEvent.removeMonitor(monitor) }
        // Safety net: always restore display gamma on exit/crash
        CGDisplayRestoreColorSyncSettings()
    }
}
