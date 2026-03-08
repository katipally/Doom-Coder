import Foundation
import IOKit.pwr_mgt
import CoreGraphics
import AppKit
import ServiceManagement
import UserNotifications
import DoomCoderCore

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

    // Shared instance for SwiftUI scenes.
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

    /// Single source of truth for the keep-awake intent. `.off` / `.on` map to
    /// the legacy manual toggle; `.auto` holds the assertion only while at
    /// least one tracked agent is in a live state (with a grace period).
    var keepAwakeMode: KeepAwakeMode {
        didSet {
            guard oldValue != keepAwakeMode else { return }
            UserDefaults.standard.set(keepAwakeMode.rawValue, forKey: "doomcoder.keepAwakeMode")
            applyKeepAwakeMode()
            notifyStateChanged()
        }
    }

    var mode: DoomCoderMode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "doomcoder.mode")
            handleModeChange()
            notifyStateChanged()
        }
    }

    var sessionTimerHours: Int {
        didSet {
            UserDefaults.standard.set(sessionTimerHours, forKey: "doomcoder.sessionTimer")
            resetSessionTimer()
            notifyStateChanged()
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

    // MARK: - Accessibility (optional — kept for legacy diagnostics only.
    // The ⌥Space global hotkey uses Carbon RegisterEventHotKey which does
    // NOT require Accessibility. This is surfaced only in the Settings
    // diagnostics section if the user ever asks.)

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
    @ObservationIgnored nonisolated(unsafe) private var _trackingObserver: NSObjectProtocol?

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
        let savedKeepAwake = UserDefaults.standard.string(forKey: "doomcoder.keepAwakeMode")
        if let s = savedKeepAwake, let m = KeepAwakeMode(rawValue: s) {
            self.keepAwakeMode = m
        } else {
            // Migration from pre-2.5 (no keepAwakeMode key): the app used to
            // auto-enable keep-awake on launch whenever the master toggle was
            // on. Preserve that behaviour so upgrading users don't suddenly
            // start letting their Mac sleep.
            let masterOn = UserDefaults.standard.object(forKey: "doomcoder.masterEnabled") as? Bool ?? true
            self.keepAwakeMode = masterOn ? .on : .off
            UserDefaults.standard.set(self.keepAwakeMode.rawValue, forKey: "doomcoder.keepAwakeMode")
        }
        startThermalMonitoring()
        updateThermalState()
        hasAccessibilityPermission = AXIsProcessTrustedWithOptions(nil)
        // Apply the persisted intent. `.on` re-acquires the assertion on launch
        // (explicit user intent). `.auto` does NOT acquire without fresh agent
        // evidence (crash-safety — never restore a stale assertion).
        applyKeepAwakeMode()
        // Re-evaluate Auto immediately when the user toggles an agent's tracking
        // on/off (the `sessions` map doesn't mutate, so the observation-tracking
        // path wouldn't otherwise fire until the 20s backstop).
        _trackingObserver = NotificationCenter.default.addObserver(
            forName: .trackingStoreChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.keepAwakeMode == .auto else { return }
                self.evaluateAuto()
            }
        }
    }

    // MARK: - Global Hotkey
    // Owned by GlobalHotkey (Carbon RegisterEventHotKey). No AX permission
    // required. This class no longer installs a duplicate NSEvent monitor.

    private func setupGlobalHotkey() {
        if let existing = _hotkeyMonitor {
            NSEvent.removeMonitor(existing)
            _hotkeyMonitor = nil
        }
    }

    // MARK: - Enable / Disable / Toggle (public intent)
    //
    // These now drive `keepAwakeMode` so the panel master toggle, the global
    // hotkey, the menu-bar item and remote (iOS) commands all converge on a
    // single source of truth. `.on`/`.off` map to the legacy manual behaviour.

    func enable()  { keepAwakeMode = .on }
    func disable() { keepAwakeMode = .off }
    func toggle()  { keepAwakeMode = (keepAwakeMode == .off) ? .on : .off }

    /// Releases the IOPM assertion without changing the persisted keep-awake
    /// intent. Use on app termination so On/Auto are restored on next launch.
    func prepareForTermination() {
        if isActive { releaseAssertion() }
    }

    // MARK: - Apply keep-awake intent

    private func applyKeepAwakeMode() {
        switch keepAwakeMode {
        case .off:
            stopAutoEval()
            if isActive { releaseAssertion() }
        case .on:
            stopAutoEval()
            if !isActive { acquireAssertion() }
        case .auto:
            startAutoEval()
            evaluateAuto()
        }
    }

    // MARK: - Assertion mechanics (low level)

    private func acquireAssertion() {
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
        notifyStateChanged()
        // Notify user when Auto mode takes sleep control.
        if keepAwakeMode == .auto {
            let names = autoStatusLines.map(\.agentDisplayName)
            SleepStateNotifier.shared.notifyTookControl(agentNames: names)
        }
    }

    private func releaseAssertion() {
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
        notifyStateChanged()
    }

    // MARK: - Auto mode

    /// Per-agent status line for the expandable detail view (Mac panel + iOS card).
    struct AutoAgentLine: Identifiable, Sendable {
        /// Unique per session (agent::sessionId) — avoids ForEach ID collisions
        /// when the same agent has multiple concurrent sessions.
        let id: String                 // = sessionKey ("claude::abc123")
        let agentDisplayName: String   // e.g. "Claude Code", "Cursor"
        let agentRaw: String           // TrackedAgent.rawValue
        let state: String              // "running" | "idle Xm" | "waiting approval" | "waiting input"
        let agentType: String          // "CLI" | "IDE"
        let idleSecs: Int
        let pidAlive: Bool
    }

    // MARK: - Auto mode configuration

    /// Any hook received within this window means an agent is working — keep awake.
    /// After this window of silence, release the assertion and delegate to macOS.
    private let hookWindowSeconds: TimeInterval = 600

    /// True while DoomCoder should hold the sleep assertion in Auto mode.
    var isHookFresh: Bool {
        AgentTrackingManager.shared.lastAnyHookAt.timeIntervalSinceNow > -hookWindowSeconds
    }

    // MARK: - Auto mode state

    @ObservationIgnored nonisolated(unsafe) private var _autoEvalTimer: Timer?
    @ObservationIgnored private var _autoObservationGeneration: Int = 0

    // MARK: - Active session computation (single source of truth)

    var activeAgentCount: Int { AgentTrackingManager.shared.hookFreshAgents.count }

    /// Per-agent detail lines for the expandable UI panel (one row per agent type).
    var autoStatusLines: [AutoAgentLine] {
        let now = Date()
        return AgentTrackingManager.shared.lastHookByAgent
            .filter { _, t in now.timeIntervalSince(t) < hookWindowSeconds }
            .map { agent, t in
                let idleSecs = max(0, Int(now.timeIntervalSince(t)))
                return AutoAgentLine(
                    id: agent.rawValue,
                    agentDisplayName: agent.displayName,
                    agentRaw: agent.rawValue,
                    state: idleSecs < 60 ? "running" : "idle \(idleSecs / 60)m",
                    agentType: agent.isIDEAgent ? "IDE" : "CLI",
                    idleSecs: idleSecs,
                    pidAlive: true
                )
            }
            .sorted { $0.idleSecs < $1.idleSecs }
    }

    /// Seconds the assertion has been held (0 when inactive). Published to iOS.
    var elapsedSeconds: Int {
        guard let since = activeSince else { return 0 }
        return max(0, Int(Date.now.timeIntervalSince(since)))
    }

    private func startAutoEval() {
        _autoObservationGeneration += 1
        observeAgentsForAuto()
        _autoEvalTimer?.invalidate()
        // Backstop poll: ensures the 10-min TTL expiry is honoured even when
        // no new hooks arrive (the observation only fires when hooks land).
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateAuto() }
        }
        RunLoop.main.add(t, forMode: .common)
        _autoEvalTimer = t
    }

    private func stopAutoEval() {
        _autoObservationGeneration += 1
        _autoEvalTimer?.invalidate()
        _autoEvalTimer = nil
    }

    private func observeAgentsForAuto() {
        let generation = _autoObservationGeneration
        withObservationTracking {
            _ = AgentTrackingManager.shared.lastAnyHookAt
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self,
                      self._autoObservationGeneration == generation,
                      self.keepAwakeMode == .auto else { return }
                self.evaluateAuto()
                self.observeAgentsForAuto()
            }
        }
    }

    private func evaluateAuto() {
        guard keepAwakeMode == .auto else { return }
        if isHookFresh {
            if !isActive { acquireAssertion() }
        } else {
            if isActive {
                releaseAssertion()
                SleepStateNotifier.shared.notifyReleasedControl()
            }
        }
    }

    // MARK: - State-change broadcast (CloudKit publish + UI)

    private func notifyStateChanged() {
        NotificationCenter.default.post(name: .sleepManagerStateChanged, object: nil)
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
        // Remove any stale wake observer from a previous cycle.
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

        // Install the wake observer BEFORE issuing pmset so we never miss the
        // screensDidWake notification in the window between pmset completing and
        // the observer being installed. The guard on `isScreenOff` in the
        // callback is a no-op if it fires prematurely (before pmset succeeds).
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

        // Run pmset and only mark isScreenOff = true on success. On failure,
        // tear down the observer and leave the display in its current state.
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["displaysleepnow"]
        pmset.standardOutput = FileHandle.nullDevice
        pmset.standardError  = FileHandle.nullDevice

        let pmsetSucceeded: Bool = await withCheckedContinuation { cont in
            pmset.terminationHandler = { p in cont.resume(returning: p.terminationStatus == 0) }
            do {
                try pmset.run()
            } catch {
                cont.resume(returning: false)
            }
        }

        if fadeAcquired { CGReleaseDisplayFadeReservation(token) }

        if pmsetSucceeded {
            isScreenOff = true
        } else {
            // pmset failed — remove the observer we just installed and notify.
            if let obs = _screenWakeObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(obs)
                _screenWakeObserver = nil
            }
            // Post a local notification so the user knows screen-sleep failed.
            let content = UNMutableNotificationContent()
            content.title = "Screen Sleep Failed"
            content.body = "Could not sleep the display. Check System Settings › Energy Saver."
            let req = UNNotificationRequest(identifier: "doomcoder.screenOffFailed",
                                            content: content, trigger: nil)
            Task { try? await UNUserNotificationCenter.current().add(req) }
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
        // The auto-off cap only applies to the explicit `.on` mode. In `.auto`
        // the assertion is governed by agent activity, so a hard time cap would
        // either fight the activity logic or permanently disable Auto on expiry.
        guard isActive, keepAwakeMode == .on, sessionTimerHours > 0 else { return }
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
        _autoEvalTimer?.invalidate()
        if assertionID != 0 { IOPMAssertionRelease(assertionID) }
        _elapsedTimer?.invalidate()
        _sessionTimer?.invalidate()
        _permissionPollTimer?.invalidate()
        if let obs = thermalObserver  { NotificationCenter.default.removeObserver(obs) }
        if let obs = _screenWakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(obs) }
        if let monitor = _hotkeyMonitor { NSEvent.removeMonitor(monitor) }
        if let obs = _trackingObserver { NotificationCenter.default.removeObserver(obs) }
    }
}

extension Notification.Name {
    /// Posted whenever the keep-awake intent, active assertion, screen mode or
    /// session timer changes. CloudKitPusherLifecycle observes this to publish
    /// a fresh MacStatus (so iOS reflects local + remote edits promptly).
    static let sleepManagerStateChanged = Notification.Name("doomcoder.sleepManager.stateChanged")
}
