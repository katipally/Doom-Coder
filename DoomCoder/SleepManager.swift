import Foundation
import IOKit.pwr_mgt

@Observable
@MainActor
final class SleepManager {
    private(set) var isActive = false
    private(set) var elapsedTimeString = ""
    private var activeSince: Date?

    // nonisolated(unsafe) allows access in deinit without actor isolation.
    // IOPMAssertionRelease and Timer.invalidate are safe to call from any thread.
    @ObservationIgnored
    nonisolated(unsafe) private var assertionID: IOPMAssertionID = 0

    @ObservationIgnored
    nonisolated(unsafe) private var _timer: Timer?

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
        startTimer()
    }

    func disable() {
        guard isActive else { return }
        IOPMAssertionRelease(assertionID)
        assertionID = 0
        isActive = false
        activeSince = nil
        elapsedTimeString = ""
        stopTimer()
    }

    func toggle() {
        isActive ? disable() : enable()
    }

    private func startTimer() {
        _timer?.invalidate()
        updateElapsedTime()
        let t = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateElapsedTime()
            }
        }
        _timer = t
    }

    private func stopTimer() {
        _timer?.invalidate()
        _timer = nil
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

    deinit {
        if assertionID != 0 {
            IOPMAssertionRelease(assertionID)
        }
        _timer?.invalidate()
    }
}
