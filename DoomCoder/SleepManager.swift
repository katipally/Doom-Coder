import Foundation
import IOKit.pwr_mgt
import CoreGraphics

// MARK: - Types

enum DoomCoderMode: String, CaseIterable {
    case full = "full"
    case autoDim = "autoDim"

    var displayName: String {
        switch self {
        case .full: return "Full Mode"
        case .autoDim: return "Auto-Dim Mode"
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

    // MARK: User settings (persisted)

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

    // MARK: Private

    private var activeSince: Date?
    private var sessionEndDate: Date?

    // Saved CoreGraphics gamma state for brightness restore
    private typealias GammaState = (
        rMin: CGGammaValue, rMax: CGGammaValue, rGamma: CGGammaValue,
        gMin: CGGammaValue, gMax: CGGammaValue, gGamma: CGGammaValue,
        bMin: CGGammaValue, bMax: CGGammaValue, bGamma: CGGammaValue
    )
    private var savedGamma: GammaState?

    @ObservationIgnored nonisolated(unsafe) private var assertionID: IOPMAssertionID = 0
    @ObservationIgnored nonisolated(unsafe) private var _elapsedTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) private var _idleTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) private var _sessionTimer: Timer?
    @ObservationIgnored nonisolated(unsafe) private var thermalObserver: NSObjectProtocol?

    // MARK: Init

    init() {
        let savedMode = UserDefaults.standard.string(forKey: "doomcoder.mode") ?? DoomCoderMode.full.rawValue
        self.mode = DoomCoderMode(rawValue: savedMode) ?? .full
        self.idleTimeoutMinutes = UserDefaults.standard.object(forKey: "doomcoder.idleTimeout") as? Int ?? 5
        self.dimBrightnessPercent = UserDefaults.standard.object(forKey: "doomcoder.dimBrightness") as? Int ?? 10
        self.sessionTimerHours = UserDefaults.standard.object(forKey: "doomcoder.sessionTimer") as? Int ?? 0
        startThermalMonitoring()
        updateThermalState()
    }

    // MARK: - Enable / Disable / Toggle

    func enable() {
        guard !isActive else { return }
        var id: IOPMAssertionID = 0
        let reason = "DoomCoder: Preventing sleep for AI coding session" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &id
        )
        guard result == kIOReturnSuccess else { return }
        assertionID = id
        isActive = true
        activeSince = .now
        startElapsedTimer()
        resetSessionTimer()
        if mode == .autoDim {
            startIdleMonitoring()
        }
    }

    func disable() {
        guard isActive else { return }
        restoreGamma()
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
        activeSince = nil
        elapsedTimeString = ""
        isDimmed = false
        sessionTimerRemainingText = nil
        sessionEndDate = nil
        stopElapsedTimer()
        stopIdleMonitoring()
        stopSessionTimer()
    }

    func toggle() { isActive ? disable() : enable() }

    // MARK: - Mode Change

    private func handleModeChange() {
        guard isActive else { return }
        if mode == .autoDim {
            startIdleMonitoring()
        } else {
            restoreGamma()
            isDimmed = false
            stopIdleMonitoring()
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
        if h > 0 {
            elapsedTimeString = "Active for \(h)h \(m)m"
        } else {
            elapsedTimeString = "Active for \(m < 1 ? "<1" : "\(m)")m"
        }
    }

    // MARK: - Auto-Dim (Idle Monitoring + Gamma Dimming)

    private func startIdleMonitoring() {
        stopIdleMonitoring()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkIdleState()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        _idleTimer = t
    }

    private func stopIdleMonitoring() {
        _idleTimer?.invalidate()
        _idleTimer = nil
    }

    private func checkIdleState() {
        // All meaningful input events to avoid false-positive idle detection
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

    // MARK: - CoreGraphics Gamma Dimming
    // Uses CGSetDisplayTransferByFormula to reduce display brightness via software gamma.
    // Works on all Macs including Apple Silicon (IOKit display APIs return 0 services there).

    private func dimScreen() {
        let display = CGMainDisplayID()
        var rMin: CGGammaValue = 0, rMax: CGGammaValue = 0, rGamma: CGGammaValue = 0
        var gMin: CGGammaValue = 0, gMax: CGGammaValue = 0, gGamma: CGGammaValue = 0
        var bMin: CGGammaValue = 0, bMax: CGGammaValue = 0, bGamma: CGGammaValue = 0
        CGGetDisplayTransferByFormula(
            display,
            &rMin, &rMax, &rGamma,
            &gMin, &gMax, &gGamma,
            &bMin, &bMax, &bGamma
        )
        savedGamma = (rMin, rMax, rGamma, gMin, gMax, gGamma, bMin, bMax, bGamma)

        let dim = CGGammaValue(dimBrightnessPercent) / 100.0
        CGSetDisplayTransferByFormula(
            display,
            rMin, dim, rGamma,
            gMin, dim, gGamma,
            bMin, dim, bGamma
        )
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
            MainActor.assumeIsolated {
                self?.updateThermalState()
            }
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
            MainActor.assumeIsolated {
                self?.checkSessionTimer()
            }
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
        if Date.now >= end {
            disable()
        } else {
            updateSessionTimerRemaining()
        }
    }

    private func updateSessionTimerRemaining() {
        guard let end = sessionEndDate else {
            sessionTimerRemainingText = nil
            return
        }
        let remaining = Int(end.timeIntervalSince(.now))
        guard remaining > 0 else {
            sessionTimerRemainingText = nil
            return
        }
        let h = remaining / 3600
        let m = (remaining % 3600) / 60
        sessionTimerRemainingText = h > 0
            ? "Auto-disable in \(h)h \(m)m"
            : "Auto-disable in \(m)m"
    }

    // MARK: - Cleanup

    deinit {
        if assertionID != 0 { IOPMAssertionRelease(assertionID) }
        _elapsedTimer?.invalidate()
        _idleTimer?.invalidate()
        _sessionTimer?.invalidate()
        if let observer = thermalObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        // Safety net: restore all display gamma tables if app exits/crashes while dimmed.
        // CGDisplayRestoreColorSyncSettings is safe to call from any thread and is a no-op
        // if gamma was never modified.
        CGDisplayRestoreColorSyncSettings()
    }
}
