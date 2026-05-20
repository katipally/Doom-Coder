// BackgroundRefresh.swift — DoomCoder Companion
// Registers and schedules the BGAppRefreshTask that keeps the stores fresh
// when the app is suspended. Calls CompanionSyncEngine.fetchChanges with a
// 25-second budget and re-schedules itself on completion.

import BackgroundTasks
import Foundation

enum BackgroundRefresh {

    static let taskIdentifier = "com.doomcoder.app.companion.refresh"

    /// Must be called from `application(_:didFinishLaunchingWithOptions:)` —
    /// BGTaskScheduler requires registration before the app finishes launching.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            Self.handle(refreshTask)
        }
    }

    /// Requests the system to wake the app in the background. Safe to call
    /// multiple times; the scheduler deduplicates by identifier.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 min min interval
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: - Private

    private static func handle(_ task: BGAppRefreshTask) {
        // Re-schedule immediately so we stay in the queue.
        schedule()

        let fetchTask = Task { @MainActor in
            await CompanionSyncEngine.shared.fetchChanges()
        }

        task.expirationHandler = {
            fetchTask.cancel()
        }

        Task {
            // Give the engine up to 25 seconds.
            let deadline = ContinuousClock.now + .seconds(25)
            do {
                try await withDeadline(deadline) { await fetchTask.value }
                task.setTaskCompleted(success: true)
            } catch {
                task.setTaskCompleted(success: false)
            }
        }
    }

    /// Runs `body` and cancels it if the deadline elapses.
    private static func withDeadline<T: Sendable>(
        _ deadline: ContinuousClock.Instant,
        body: @escaping @Sendable () async -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { await body() }
            group.addTask {
                try await Task.sleep(until: deadline, clock: .continuous)
                throw CancellationError()
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
