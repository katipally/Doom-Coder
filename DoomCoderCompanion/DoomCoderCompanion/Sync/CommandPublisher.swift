// CommandPublisher.swift — DoomCoder Companion
// Sends ControlCommandRecords to CloudKit and tracks their applied/failed
// lifecycle with optimistic AsyncThrowingStream feedback so the UI can show
// accurate status without polling.

import Foundation
import DoomCoderCore

@MainActor
@Observable
final class CommandPublisher {

    // MARK: - Singleton

    static let shared = CommandPublisher()
    private init() {}

    // MARK: - Nested types

    enum Status: Sendable {
        /// We've enqueued the CKRecord locally (CompanionSyncEngine will send it).
        case sent
        /// >5s since send and Mac has not yet acknowledged. Surfaced so the
        /// UI can show a "Waiting for Mac…" indicator and reassure the user
        /// that the request is still in flight (e.g. Mac asleep, push
        /// pending wake).
        case waitingForMac
        case applied(String?)
        case failed(String)
    }

    private struct Waiter {
        let continuation: AsyncThrowingStream<Status, Error>.Continuation
    }

    // MARK: - State

    /// commandId → waiter for outstanding commands.
    private var waiters: [String: Waiter] = [:]

    // MARK: - Public API

    /// Sends a verb to the target Mac and returns a stream of Status updates.
    /// The stream emits `.sent` immediately, `.waitingForMac` after 5 seconds
    /// if the Mac has not yet acknowledged, and finally `.applied` / `.failed`
    /// — or times out with an error after 60 seconds (covers worst-case
    /// silent-push wake on a sleeping Mac).
    func send(
        verb: ControlCommandRecord.Verb,
        args: [String: String] = [:],
        targetMacId: String
    ) -> AsyncThrowingStream<Status, Error> {
        let argsJSON = ControlCommandRecord.encodeArgs(args)
        let cmd = ControlCommandRecord(
            macId: targetMacId,
            verb: verb,
            argsJSON: argsJSON,
            requestedBy: "iOS"
        )

        return AsyncThrowingStream { continuation in
            // Register the waiter before enqueueing the save so there is no
            // window where the echo could arrive before we are listening.
            self.waiters[cmd.commandId] = Waiter(continuation: continuation)

            CompanionSyncEngine.shared.enqueueSave(cmd.toCKRecord())
            continuation.yield(.sent)

            let id = cmd.commandId

            // After 5 s, surface "Waiting for Mac…" if no echo yet.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                if self.waiters[id] != nil {
                    continuation.yield(.waitingForMac)
                }
            }

            // 60-second hard timeout. Long enough for a sleeping Mac to be
            // woken via silent push and apply the command, short enough that
            // the UI doesn't spin forever if the Mac is unreachable.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                if self.waiters[id] != nil {
                    self.waiters.removeValue(forKey: id)
                    continuation.finish(throwing: CommandTimeoutError(commandId: id))
                }
            }
        }
    }

    /// Called by CompanionSyncEngine when a ControlCommand echo arrives from
    /// CloudKit with appliedAt set (meaning the Mac applied it).
    func handleEcho(_ cmd: ControlCommandRecord) {
        guard let waiter = waiters.removeValue(forKey: cmd.commandId) else { return }
        if let err = cmd.error {
            waiter.continuation.yield(.failed(err))
        } else {
            waiter.continuation.yield(.applied(cmd.result))
        }
        waiter.continuation.finish()
    }
}

// MARK: - CommandTimeoutError

struct CommandTimeoutError: Error, LocalizedError {
    let commandId: String
    var errorDescription: String? { "Command \(commandId) timed out after 60 seconds." }
}
