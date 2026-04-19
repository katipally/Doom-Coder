import Foundation
import IOKit.pwr_mgt
import CoreGraphics
import AppKit
import ServiceManagement

// MARK: - Types

enum DoomCoderMode: String, CaseIterable {
    case screenOn  = "screenOn"
    case screenOff = "screenOff"

    var displayName: String {
        switch self {
        case .screenOn:  return "Screen On"
        case .screenOff: return "Screen Off"
        }
    }
}

// MARK: - SleepManager

@Observable
@MainActor
final class SleepManager {

    // Shared instance so AgentTrackingManager and SwiftUI scenes bind to the
    // same object without depending on @State init ordering.
    static let shared = SleepManager()

    // MARK: - Public state

    private(set) var isActive = false
    private(set) var elapsedTimeString = ""
    private(set) var thermalStateText = "Normal"
    private(set) var sessionTimerRemainingText: String?
    private(set) var isScreenOff = false
    private(set) var screenOffCountdown: Int? = nil
    private(set) var hasAccessibilityPermission: Bool = false

    // MARK: - Persisted settings

    var mode: DoomCoderMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "doomcoder.mode")
            handleModeChange()
        }
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

    // MARK: - Launch at Login

    private(set) var isLaunchAtLoginEnabled: Bool = (SMAppService.mainApp.status == .enabled)

    func toggleLaunchAtLogin() {
        do {
            if isLaunchAtLoginEnabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {}
        isLaunchAtLoginEnabled = (SMAppService.mainApp.status == .enabled)
    }

    // MARK: - Accessibility (required for global ⌥Space hotkey)

    func requestAccessibilityPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        startPermissionPolling()
    }

    private func startPermissionPolling() {
        _permissionPollTimer?.invalidate()
        _permissionPollCount = 0
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self._permissionPollCount += 1
                if AXIsProcessTrustedWithOptions(nil) {
                    self.hasAccessibilityPermission = true
                    self.setupGlobalHotkey()
                    self._permissionPollTimer?.invalidate()
                    self._permissionPollTimer = nil
                } else if self._permissionPollCount >= 15 {
                    self._permissionPollTimer?.invalidate()
                    self._permissionPollTimer = nil
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        _permissionPollTimer = t
    }

    // MARK: - Private state

    private var activeSince: Date?
    private var sessionEndDate: Date?
    private var _permissionPollCount: Int = 0

    @ObservationIgnored nonisolated(unsafe) private var assertionID: IOPMAssertionID = 0
    // ProcessInfo activity token — belt-and-braces complement to the IOPM
    // assertion. On Apple Silicon the IOPM `PreventSystemSleep` assertion
    // keeps the CPU alive (verified via `pmset -g assertions` + powermetrics
    // sampling during Screen-Off). The `.idleSystemSleepDisabled` activity
    // additionally opts our own process out of App Nap.
    @ObservationIgnored nonisolated(unsafe) private var activityToken: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var _elapsedTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) private var _sessionTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) private var _permissionPollTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) private var thermalObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var _screenOffTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var _screenWakeObserver: NSObjectProtocol?
    @ObservationIgnored nonisolated(unsafe) private var _hotkeyMonitor: Any?

    // MARK: - Init

    init() {
        let saved = UserDefaults.standard.string(forKey: "doomcoder.mode") ?? DoomCoderMode.screenOn.rawValue
        // v1.8 migration: legacy "full" → "screenOn" (same behaviour, new name).
        let resolved = (saved == "full") ? .screenOn : (DoomCoderMode(rawValue: saved) ?? .screenOn)
        self.mode = resolved
        if saved == "full" {
            UserDefaults.standard.set(DoomCoderMode.screenOn.rawValue, forKey: "doomcoder.mode")
        }
        self.sessionTimerHours = UserDefaults.standard.object(forKey: "doomcoder.sessionTimer") as? Int ?? 0
        self.screenOffRearmMinutes = UserDefaults.standard.object(forKey: "doomcoder.screenOffRearm") as? Int ?? 10
        startThermalMonitoring()
        updateThermalState()
        setupGlobalHotkey()
    }

    // MARK: - Global Hotkey (⌥ Space)
    // Requires Accessibility permission. Prompts via requestAccessibilityPermission(),
    // then re-installs automatically once permission is detected via polling.

    private func setupGlobalHotkey() {
        if let existing = _hotkeyMonitor {
            NSEvent.removeMonitor(existing)
            _hotkeyMonitor = nil
        }
        hasAccessibilityPermission = AXIsProcessTrustedWithOptions(nil)
        guard hasAccessibilityPermission else { return }

        _hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 49,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .option
            else { return }
            Task { @MainActor [weak self] in self?.toggle() }
        }
    }

    // MARK: - Enable / Disable / Toggle

    func enable() {
        guard !isActive else { return }
        guard let id = createAssertion() else { return }
        assertionID = id
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "DoomCoder session active"
        )
        isActive = true
        activeSince = .now
        startElapsedTimer()
        resetSessionTimer()
        if mode == .screenOff { startScreenOff() }
    }

    func disable() {
        guard isActive else { return }
        stopScreenOff()
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        if let t = activityToken {
            ProcessInfo.processInfo.endActivity(t)
            activityToken = nil
        }
        isActive = false
        activeSince = nil
        elapsedTimeString = ""
        isScreenOff = false
        screenOffCountdown = nil
        sessionTimerRemainingText = nil
        sessionEndDate = nil
        stopElapsedTimer()
        stopSessionTimer()
    }

    func toggle() {
        if isActive {
            // Manual user-initiated disable. Start cool-down so agent-fuse
            // does not immediately re-enable.
            _manualOffUntil = Date.now.addingTimeInterval(15 * 60)
        }
        isActive ? disable() : enable()
    }

    // MARK: - Agent auto-fuse

    @ObservationIgnored nonisolated(unsafe) private var _manualOffUntil: Date?
    private(set) var isFusedByAgents: Bool = false
    private(set) var agentFuseReason: String?

    /// Called by AgentTrackingManager when at least one tracked session is
    /// running or waiting. Safe to call repeatedly; subject to a 15-minute
    /// cool-down following a manual toggle-off.
    func forceScreenOn(reason: String) {
        if let until = _manualOffUntil, until > .now { return }
        agentFuseReason = reason
        if isActive {
            isFusedByAgents = true
            return
        }
        // Force screen-on semantics regardless of current mode selection.
        // We do not mutate `mode` — the fuse is transparent.
        let previousMode = mode
        if previousMode != .screenOn { mode = .screenOn }
        enable()
        isFusedByAgents = true
    }

    /// Called by AgentTrackingManager when no tracked session is in a live
    /// state. Releases the fuse and disables the blocker if it was only
    /// active because of the fuse.
    func releaseAgentFuse() {
        guard isFusedByAgents else { return }
        isFusedByAgents = false
        agentFuseReason = nil
        disable()
    }


    // MARK: - IOPMAssertion

    private func createAssertion() -> IOPMAssertionID? {
        var id: IOPMAssertionID = 0
        // Screen Off: prevent system sleep only — display is allowed to sleep (we sleep it manually)
        // Full: prevent both display idle sleep and system sleep
        let type: CFString = (mode == .screenOff)
            ? (kIOPMAssertionTypePreventSystemSleep as CFString)
            : (kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString)
        let reason = "DoomCoder: keeping Mac awake for AI coding session" as CFString
        let result = IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id)
        return result == kIOReturnSuccess ? id : nil
    }

    // MARK: - Mode Change

    private func handleModeChange() {
        guard isActive else { return }
        if assertionID != 0 { IOPMAssertionRelease(assertionID); assertionID = 0 }
        guard let id = createAssertion() else { disable(); return }
        assertionID = id
        stopScreenOff()
        if mode == .screenOff { startScreenOff() }
    }

    // MARK: - Elapsed Timer

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
        elapsedTimeString = h > 0 ? "Active for \(h)h \(m)m" : "Active for \(m < 1 ? "<1" : "\(m)")m"
    }

    // MARK: - Screen Off Mode
    // Shows a 5-second countdown, then fades the display to black using CGDisplayFade,
    // then calls pmset displaysleepnow to sleep the display (Mac stays fully awake).
    // On user activity (any input), macOS wakes the display automatically.
    // After wake, re-arm timer restarts and sleeps the display again after idle threshold.

    private func startScreenOff() {
        screenOffCountdown = 5
        _screenOffTask = Task { @MainActor [weak self] in
            for remaining in stride(from: 4, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled, self.isActive, self.mode == .screenOff else { return }
                self.screenOffCountdown = remaining
            }
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled, self.isActive, self.mode == .screenOff else { return }
            self.screenOffCountdown = nil
            await self.executeScreenOff()
        }
    }

    // Fades the display to black over 0.8s, then sleeps it via pmset.
    // Uses CGAcquireDisplayFadeReservation / CGDisplayFade (public CoreGraphics API, macOS 10.0+).
    private func executeScreenOff() async {
        if let obs = _screenWakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
            _screenWakeObserver = nil
        }

        // Smooth fade to black before sleeping the display
        var token: CGDisplayFadeReservationToken = 0
        let fadeAcquired = CGAcquireDisplayFadeReservation(3.0, &token) == CGError.success
        if fadeAcquired {
            // Async (non-blocking) fade from normal → solid black over 0.8 seconds
            CGDisplayFade(token, 0.8,
                          CGDisplayBlendFraction(kCGDisplayBlendNormal),
                          CGDisplayBlendFraction(kCGDisplayBlendSolidColor),
                          0, 0, 0, boolean_t(0))
        }

        try? await Task.sleep(for: .milliseconds(850))
        guard !Task.isCancelled, isActive, mode == .screenOff else {
            if fadeAcquired { CGReleaseDisplayFadeReservation(token) }
            return
        }

        isScreenOff = true

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError  = FileHandle.nullDevice
        try? task.run()

        if fadeAcquired { CGReleaseDisplayFadeReservation(token) }

        // Watch for display wake from any user input
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

    // Polls every 30s; re-arms screen-off when user has been idle for screenOffRearmMinutes.
    private func startRearmMonitoring() {
        _screenOffTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled,
                      self.isActive, self.mode == .screenOff, !self.isScreenOff else { break }
                await self.checkAndRearm()
            }
        }
    }

    private func checkAndRearm() async {
        let idleTimes: [CFTimeInterval] = [
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .rightMouseDown),
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel),
        ]
        let minIdle = idleTimes.min() ?? 0
        if minIdle >= Double(screenOffRearmMinutes * 60) {
            await executeScreenOff()
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
        case .nominal:  thermalStateText = "Normal"
        case .fair:     thermalStateText = "Fair"
        case .serious:  thermalStateText = "Serious"
        case .critical: thermalStateText = "Critical"
        @unknown default: thermalStateText = "Unknown"
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
        _sessionTimer?.invalidate()
        _permissionPollTimer?.invalidate()
        if let obs = thermalObserver  { NotificationCenter.default.removeObserver(obs) }
        if let obs = _screenWakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let monitor = _hotkeyMonitor { NSEvent.removeMonitor(monitor) }
    }
}
