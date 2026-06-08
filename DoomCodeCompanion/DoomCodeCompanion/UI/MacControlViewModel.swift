import Foundation
import SwiftUI
import Observation
import DoomCoderCore

// MARK: - MacControlViewModel
//
// Lightweight state container that holds the optimistic-UI state for
// the four Mac controls. Extracted from the 921-line `MacControlView`
// so the view body is purely declarative. The view still owns the
// actual command-sending + ack polling + timeout handling (those need
// access to the SwiftUI environment and the view is already long-
// lived there). The model is just a value holder.
@MainActor
@Observable
final class MacControlViewModel {

    /// The live Mac status; we reconcile against this on every change.
    /// `MacStatusStore.shared` is itself @Observable so SwiftUI picks
    /// up updates without explicit subscriptions.
    var macStore = MacStatusStore.shared

    /// Used to send control commands; exposed so the view can also
    /// read its `accountAvailable` and `lastSyncAt` for diagnostics.
    var sync = CompanionSyncEngine.shared

    // MARK: - Optimistic state (the values the user is currently editing)

    var masterEnabled: Bool = true
    var mode: KeepAwakeMode = .off
    var screen: ScreenMode = .screenOn
    var timerHours: Int = 0

    // MARK: - Pending-ack state

    /// The command-id we're waiting to be acked (for non-master commands).
    private(set) var waitingCommandId: String?
    /// The command-id we're waiting to be acked (for the master toggle).
    private(set) var waitingMasterCommandId: String?
    /// The desired master state we're reconciling by value (the master
    /// toggle can land on the Mac as `true`/`false` either way, so we
    /// additionally wait for the published `masterEnabled` to match).
    var desiredMaster: Bool?

    /// User-visible timeout flag — set when the Mac doesn't ack within
    /// 30 seconds. The view shows a "Retry" action.
    private(set) var showTimeoutError: Bool = false

    // MARK: - Convenience

    /// True when the UI is waiting for the Mac to confirm any control change.
    var isWaiting: Bool { waitingCommandId != nil || desiredMaster != nil }

    // MARK: - Sync / mutation

    /// Re-sync the local UI from the latest Mac status. Called on
    /// appear and after any ack.
    func syncFromMac() {
        guard let mac = macStore.primary else { return }
        masterEnabled = mac.masterEnabled ?? true
        if let m = mac.keepAwakeMode.flatMap(KeepAwakeMode.init) { mode = m }
        if let s = ScreenMode(rawValue: mac.mode) { screen = s }
        if let h = mac.sessionTimerHours { timerHours = h }
    }

    func setWaitingCommandId(_ id: String?) { waitingCommandId = id }
    func setWaitingMasterCommandId(_ id: String?) { waitingMasterCommandId = id }
    func setDesiredMaster(_ value: Bool?) { desiredMaster = value }
    func setShowTimeoutError(_ value: Bool) { showTimeoutError = value }

    func clearWaiting() {
        waitingCommandId = nil
        showTimeoutError = false
    }

    func clearMasterWaiting() {
        desiredMaster = nil
        waitingMasterCommandId = nil
        showTimeoutError = false
    }
}
