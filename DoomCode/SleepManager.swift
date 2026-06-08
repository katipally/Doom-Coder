// SleepManager.swift
//
// The keep-awake engine. This is the core of Doom Coder: it holds an
// IOPMAssertion (the same kernel flag caffeinate and Amphetamine use) so
// the Mac never falls asleep mid-task and kills a long agent run.
//
// Three modes drive it: Off (no assertion), On (always held, Screen On or
// Screen Off), and Auto (held only while a tracked agent is working or you
// are at the keyboard, released after a grace period once both go quiet).
// It also owns the session timer, the Screen Off re-arm loop, and the
// master on/off gate. State is the single source of truth that the menu bar
// panel and the iOS companion both read from.
import Foundation
import IOKit.pwr_mgt
import CoreGraphics
import AppKit
import ServiceManagement
import UserNotifications
import DoomCodeCore

// MARK: - Types

enum DoomCodeMode: String, CaseIterable {
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

    // MARK: - Threading model (audit 2026-06)

    // This class is `@MainActor` and ALL public and internal state is
    // mutated only on the main actor. Several stored properties are
    // marked `@ObservationIgnored nonisolated(unsafe)` because the Swift
    // 6 strict-concurrency checker does not understand the legacy
    // C-handle + Timer/Observer interaction patterns:
    //
    //   - `assertionID`  : IOPMAssertionID, an Int32 C handle. Only
    //                      read/written on the main actor (via
    //                      `createAssertion()` and `releaseAssertion()`).
    //   - `activityToken`: `NSObjectProtocol?` returned by
    //                      `ProcessInfo.beginActivity`. Only touched on
    //                      the main actor; passed to
    //                      `ProcessInfo.endActivity` from
    //                      `releaseAssertion()`.
    //   - All `Timer` properties: their callbacks are scheduled on the
    //                      main `RunLoop` (`.main` + `.common` mode) and
    //                      hop back to the main actor via
    //                      `MainActor.assumeIsolated`. The Timer objects
    //                      themselves are only invalidated on the main
    //                      actor.
    //   - All `NotificationCenter` observers: registered with
    //                      `queue: .main` and route through
    //                      `MainActor.assumeIsolated` to call back into
    //                      the actor.
    //
    // If you ever see a `Sendable` warning on these properties, the
    // fix is NOT to remove `nonisolated(unsafe)` — that would silently
    // break the threading model. The fix is to either (a) move the
    // property to a separate `@unchecked Sendable` holder, or (b) wrap
    // the C handle in an `actor`. Both are tracked in Phase 2.

    // MARK: - Public state

    private(set) var isActive = false
    private(set) var elapsedTimeString = ""
    private(set) var thermalStateText = "Normal"
    private(set) var sessionTimerRemainingText: String?
    private(set) var isScreenOff = false
    private(set) var screenOffCountdown: Int? = nil
    private(set) var hasAccessibilityPermission: Bool = false

    /// True when the most recent keyboard/mouse/trackpad event was within
    /// the silence window. Auto mode treats this as a "user is still here"
    /// signal alongside agent hooks.
    private(set) var isUserActive: Bool = false

    /// Single source of truth for the master suspend gate. When `false` the
    /// app is fully idle — no sleep blocker, no agent notifications. When
    /// `true` everything is active.
    ///
    /// This replaces the previous pattern where `PanelRootView` used
    /// `@AppStorage("doomcoder.masterEnabled")` and `StatusItemController`
    /// read the same UserDefaults key directly. Both consumers now bind
    /// here; the menu-bar icon observes via `withObservationTracking` and
    /// the panel binds via `@Bindable`.
    var masterEnabled: Bool = true {
        didSet {
            guard oldValue != masterEnabled else { return }
            UserDefaults.standard.set(masterEnabled, forKey: "doomcoder.masterEnabled")
            // Turning the master OFF releases any keep-awake assertion.
            // Turning it ON does NOT force keep-awake — the Keep Awake
            // card's Off/On/Auto selector owns that intent.
            if !masterEnabled { disable() }
            notifyStateChanged()
        }
    }

    /// While non-nil in Auto mode, the sleep assertion is held until this
    /// time regardless of agent or user activity. `nil` = no snooze.
    /// Snooze is also persisted across launches while Auto is selected
    /// (so an "indefinite" snooze survives a reboot — Caffeine behavior).
    private(set) var snoozeUntil: Date? = nil

    /// Active snooze duration. When `.indefinite`, `snoozeUntil` is `nil`
    /// (sentinel: the snooze is conceptually unbounded).
    private(set) var snoozeDuration: SnoozeDuration? = nil

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

    var mode: DoomCodeMode {
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
        // Master suspend gate — restored from UserDefaults so the app
        // remembers whether the user left it suspended across launches.
        // Default to `true` (active) for first-run users; the pre-2.7
        // @AppStorage key in `PanelRootView` used the same default.
        self.masterEnabled = UserDefaults.standard.object(forKey: "doomcoder.masterEnabled") as? Bool ?? true

        let saved = UserDefaults.standard.string(forKey: "doomcoder.mode") ?? DoomCodeMode.screenOn.rawValue
        // v1.8 migration: legacy "full" → "screenOn" (same behaviour, new name).
        let resolved = (saved == "full") ? .screenOn : (DoomCodeMode(rawValue: saved) ?? .screenOn)
        self.mode = resolved
        if saved == "full" {
            UserDefaults.standard.set(DoomCodeMode.screenOn.rawValue, forKey: "doomcoder.mode")
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
        // Restore persisted snooze state. Two keys:
        //   • "doomcoder.snoozeDuration" — the duration enum raw value
        //   • "doomcoder.snoozeUntil"    — the absolute end timestamp
        // We persist the absolute timestamp so a relaunch after the snooze
        // was partially elapsed (e.g. user quit 30 min into a 1h snooze)
        // resumes the remaining time, not a fresh full duration. If only
        // the duration is present (legacy data), we fall back to a fresh
        // full duration from now.
        if let raw = UserDefaults.standard.string(forKey: "doomcoder.snoozeDuration"),
           let d = SnoozeDuration(rawValue: raw) {
            self.snoozeDuration = d
            if let until = UserDefaults.standard.object(forKey: "doomcoder.snoozeUntil") as? Date,
               until > Date() {
                self.snoozeUntil = until
            } else if d == .indefinite {
                self.snoozeUntil = nil
            } else {
                // Legacy / no persisted timestamp → fresh full duration.
                self.snoozeUntil = d.seconds.map { Date().addingTimeInterval($0) }
            }
        }
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

    // MARK: - Enable / Disable / Toggle (public intent)
    //
    // These now drive `keepAwakeMode` so the panel master toggle, the global
    // hotkey, the menu-bar item and remote (iOS) commands all converge on a
    // single source of truth. `.on`/`.off` map to the legacy manual behaviour.

    func enable()  { keepAwakeMode = .on }
    func disable() { keepAwakeMode = .off }
    func toggle()  { keepAwakeMode = (keepAwakeMode == .off) ? .on : .off }

    // MARK: - Snooze (Auto mode only — Caffeine-style override)
    //
    // Snooze holds the sleep assertion for the chosen duration regardless
    // of agent or user-activity signals. It is only meaningful in Auto mode.
    // Calling snooze() from any other mode switches to Auto and starts the
    // snooze (intuitive — the user clearly wants the Mac held awake).

    func snooze(_ duration: SnoozeDuration) {
        // Always switch to Auto so the snooze is observed by evaluateAuto().
        // If the user was in On/Off, switching to Auto is the only way the
        // snooze can release at the right time.
        if keepAwakeMode != .auto { keepAwakeMode = .auto }
        snoozeDuration = duration
        snoozeUntil = duration.seconds.map { Date().addingTimeInterval($0) }
        UserDefaults.standard.set(duration.rawValue, forKey: "doomcoder.snoozeDuration")
        // Persist the absolute end timestamp so a relaunch (or the periodic
        // refreshAutoInputs expiry check) can resume the snooze at the right
        // moment without resetting to a fresh full duration.
        if let until = snoozeUntil {
            UserDefaults.standard.set(until, forKey: "doomcoder.snoozeUntil")
        } else {
            // Indefinite — no end timestamp to persist.
            UserDefaults.standard.removeObject(forKey: "doomcoder.snoozeUntil")
        }
        evaluateAuto()
        notifyStateChanged()
    }

    func cancelSnooze() {
        snoozeDuration = nil
        snoozeUntil = nil
        UserDefaults.standard.removeObject(forKey: "doomcoder.snoozeDuration")
        UserDefaults.standard.removeObject(forKey: "doomcoder.snoozeUntil")
        // Force a re-evaluation so we release immediately if both signals
        // are already stale.
        evaluateAuto()
        notifyStateChanged()
    }

    /// True while a snooze override is in effect. Includes indefinite
    /// snoozes (`snoozeUntil == nil` but `snoozeDuration == .indefinite`).
    var isSnoozed: Bool { snoozeDuration != nil }

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
            // Leaving Auto: cancel any in-flight snooze so it doesn't
            // resurrect on the next Auto entry.
            if snoozeDuration != nil { cancelSnooze() }
            if isActive { releaseAssertion() }
        case .on:
            stopAutoEval()
            if snoozeDuration != nil { cancelSnooze() }
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
            reason: "Doom Coder session active"
        )
        isActive = true
        activeSince = .now
        startElapsedTimer()
        resetSessionTimer()
        if mode == .screenOff { startScreenOff() }
        notifyStateChanged()
        // Notify user when Auto mode takes sleep control. The copy reflects
        // WHY the Mac is held (agents / user activity / snooze) so the user
        // can tell at a glance.
        if keepAwakeMode == .auto {
            let reason: SleepStateNotifier.TakeReason
            if isSnoozed {
                reason = .snoozed
            } else {
                let names = autoStatusLines.map(\.agentDisplayName)
                reason = names.isEmpty ? .userActive : .agents(names)
            }
            SleepStateNotifier.shared.notifyTookControl(reason: reason)
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

    /// Any keyboard / mouse / trackpad event within this window means the
    /// user is at their Mac — keep awake. Same window as agent hooks so the
    /// user can mentally treat "agent OR me" as one freshness rule.
    private let userActivityWindowSeconds: TimeInterval = 600

    /// True while any tracked agent hook has fired recently. Renamed from
    /// `isHookFresh` in v2.6 to disambiguate from the keyboard/mouse signal.
    var isAgentHookFresh: Bool {
        AgentTrackingManager.shared.lastAnyHookAt.timeIntervalSinceNow > -hookWindowSeconds
    }

    /// True while the most recent keyboard/mouse event was within the
    /// silence window. Computed via `CGEventSource.secondsSinceLastEventType`
    /// which queries the system's last-input timestamp directly — no
    /// Accessibility permission required.
    var isUserActivityFresh: Bool {
        let events: [CGEventType] = [
            .keyDown, .leftMouseDown, .rightMouseDown, .mouseMoved, .scrollWheel
        ]
        let minSeconds = events
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .infinity
        return minSeconds < userActivityWindowSeconds
    }

    /// True while Auto should hold the assertion: either signal is fresh,
    /// OR a snooze override is in effect.
    var shouldHoldAuto: Bool {
        isSnoozed || isAgentHookFresh || isUserActivityFresh
    }

    /// The dominant freshness signal for UI display. Pick the most-recently
    /// active signal. Used by the panel + iOS card to show a single
    /// human-readable status line.
    enum AutoSignal: String, Sendable {
        case agents     = "agents"        // some agent hook within window
        case userActive = "user_active"   // keyboard/mouse within window
        case snoozed    = "snoozed"       // snooze override active
        case idle       = "idle"          // both signals stale
    }

    /// Dominant signal for UI. Snooze always wins; otherwise the most
    /// informative non-stale signal wins. Agents > user-active > idle, so
    /// when both fire (user is typing AND an agent is working) the panel
    /// surfaces the agent count — the more concrete fact.
    var dominantAutoSignal: AutoSignal {
        if isSnoozed { return .snoozed }
        if isAgentHookFresh { return .agents }
        if isUserActivityFresh { return .userActive }
        return .idle
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
        // Also refreshes the user-activity signal and snooze countdown so the
        // UI can transition between "agents working" / "you're active" /
        // "snoozed" / "macOS controls sleep" smoothly.
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAutoInputs()
                self?.evaluateAuto()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        _autoEvalTimer = t
    }

    /// Refreshes inputs that `evaluateAuto` consumes: user activity,
    /// dominant signal, and snooze expiry. Pure read; no side effects.
    private func refreshAutoInputs() {
        let userFresh = isUserActivityFresh
        if isUserActive != userFresh {
            isUserActive = userFresh
        }
        // Expire an ended snooze: the next evaluateAuto will release if
        // signals are also stale. We also clear the persisted snooze so a
        // restart doesn't try to re-arm a finished snooze.
        if let until = snoozeUntil, Date() >= until {
            snoozeUntil = nil
            snoozeDuration = nil
            UserDefaults.standard.removeObject(forKey: "doomcoder.snoozeDuration")
            UserDefaults.standard.removeObject(forKey: "doomcoder.snoozeUntil")
        }
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
        // Refresh cheap-to-compute inputs first (user activity, snooze
        // expiry) so the rest of the decision uses the latest snapshot.
        refreshAutoInputs()
        if shouldHoldAuto {
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
        let reason = "Doom Coder: keeping Mac awake for AI coding session" as CFString
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
