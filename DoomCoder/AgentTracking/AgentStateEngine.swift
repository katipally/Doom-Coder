import Foundation
import OSLog

// Per-agent state machine. Receives signals from 4 layers:
//   1. Hook events (from socket)
//   2. kqueue process-exit notifications
//   3. NSWorkspace / pgrep polling
//   4. CPU sampling (CLI agents)
actor AgentStateEngine {
    private static let logger = Logger(subsystem: "DoomCoder", category: "AgentStateEngine")

    let agent: TrackedAgent
    private(set) var state: AgentState = .installed
    private let onStateChange: @Sendable (TrackedAgent, AgentState) -> Void

    private var watchedPID: pid_t = 0
    private var watcher: ProcessWatcher?
    private var cpuProbe: CLICPUProbe?

    init(agent: TrackedAgent,
         onStateChange: @escaping @Sendable (TrackedAgent, AgentState) -> Void) {
        self.agent = agent
        self.onStateChange = onStateChange
    }

    // MARK: - Hook signals

    func applyHookSignal(phase: NormalizedEventPhase, pid: pid_t) {
        if pid > 0 && pid != watchedPID { attachWatcher(pid: pid) }
        switch phase {
        case .sessionStart:
            transition(to: .idle)
        case .userPrompt, .toolStart, .subagentStart:
            transition(to: .working)
        case .toolEnd, .toolError, .subagentEnd, .agentResponse:
            break
        case .permissionNeeded:
            transition(to: .idle)
        case .sessionEnd:
            transition(to: .closed)
            detachWatcher()
        case .error:
            transition(to: .closed)
            detachWatcher()
        case .fileChanged, .other:
            break
        }
    }

    // MARK: - kqueue signals

    func applyProcessExited() {
        detachWatcher()
        transition(to: .closed)
    }

    // MARK: - NSWorkspace / pgrep signals

    func applyProcessAlive(pid: pid_t) {
        if pid > 0 && pid != watchedPID { attachWatcher(pid: pid) }
        if state == .notInstalled || state == .installed || state == .closed {
            transition(to: .idle)
        }
    }

    func applyProcessNotFound() {
        if state == .idle || state == .working {
            transition(to: .closed)
        }
        detachWatcher()
    }

    // MARK: - Agent detection result (from AgentDetector)

    func applyDetectionResult(_ runState: AgentRunState) {
        switch runState {
        case .notInstalled:
            transition(to: .notInstalled)
        case .installed:
            if !state.isRunning { transition(to: .installed) }
        case .running, .active:
            if state == .notInstalled || state == .installed || state == .closed {
                transition(to: .idle)
            }
        }
    }

    // MARK: - CPU hint (CLI agents only)

    func applyCPUHint(isHigh: Bool) {
        guard state == .idle || state == .working else { return }
        transition(to: isHigh ? .working : .idle)
    }

    // MARK: - Private

    private func attachWatcher(pid: pid_t) {
        watcher?.cancel()
        cpuProbe?.stop()
        watchedPID = pid

        let isCLI = (agent == .copilotCLI || agent == .codexCLI || agent == .claude)
        if isCLI {
            cpuProbe = CLICPUProbe(pid: pid) { [weak self] in
                Task { await self?.applyCPUHint(isHigh: true) }
            } onLow: { [weak self] in
                Task { await self?.applyCPUHint(isHigh: false) }
            }
        }

        watcher = ProcessWatcher(pid: pid) { [weak self] in
            Task { await self?.applyProcessExited() }
        }
    }

    private func detachWatcher() {
        watcher?.cancel()
        watcher = nil
        cpuProbe?.stop()
        cpuProbe = nil
        watchedPID = 0
    }

    private func transition(to newState: AgentState) {
        guard newState != state else { return }
        let old = state
        state = newState
        Self.logger.info("engine: \(self.agent.rawValue) \(old.rawValue) → \(newState.rawValue)")
        let cb = onStateChange
        let agent = self.agent
        Task { @MainActor in cb(agent, newState) }
    }
}
