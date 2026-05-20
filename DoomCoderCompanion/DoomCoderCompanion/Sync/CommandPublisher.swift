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
        case sent
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
    /// The stream emits `.sent` immediately, then `.applied` or `.failed`
    /// within 10 seconds (or times out with an error).
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

            // 10-second hard timeout.
            let id = cmd.commandId
            Task { [weak self] in
                try await Task.sleep(for: .seconds(10))
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
    var errorDescription: String? { "Command \(commandId) timed out after 10 seconds." }
}
