import SwiftUI
import AppKit
import UserNotifications
import DoomCoderCore

// MARK: - Connection Doctor
//
// Inline step-wizard that replaces the old Test Helper / Run Demo /
// Watch Live / liveEventsSection Test button row. Runs a fixed
// sequence of checks that trace the full path from the dc-hook
// binary through the unix socket into a macOS local notification.
// Each step renders with a status pill (pending/running/ok/warn/
// fail) and an optional Fix CTA so the user can act on the specific
// failure.
//
// macOS 26 polish: status pills use `.contentTransition(.symbolEffect(.replace))`
// so the icon morphs in place when the state changes. The summary
// "Connected" line uses a `Label` (not raw text + emoji) for cleaner
// VoiceOver.

struct ConnectionDoctorSection: View {
    let agent: TrackedAgent

    enum StepStatus: Equatable {
        case pending
        case running
        case ok
        case warn
        case fail
    }

    struct DoctorStep: Identifiable, Equatable {
        let id: Int
        let title: String
        var detail: String
        var status: StepStatus
        var fixTitle: String?
    }

    @State private var steps: [DoctorStep] = Self.initialSteps()
    @State private var running = false
    @State private var summary: String? = nil
    @State private var summaryIsGood: Bool = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Button {
                        Task { await runDoctor() }
                    } label: {
                        if running {
                            Label("Running…", systemImage: "stopwatch")
                        } else {
                            Label("Run Doctor", systemImage: "stethoscope")
                        }
                    }
                    .disabled(running)

                    Spacer()

                    if let summary {
                        HStack(spacing: 6) {
                            Image(systemName: summaryIsGood ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(summaryIsGood ? .green : .orange)
                                .contentTransition(.symbolEffect(.replace))
                                .accessibilityHidden(true)
                            Text(summary)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .transition(.opacity.combined(with: .move(edge: .trailing)))
                    }
                }

                Divider().opacity(0.4)

                ForEach(steps) { step in
                    stepRow(step)
                }
            }
            .animation(DCAnim.smooth, value: steps)
            .animation(DCAnim.fade, value: summary)
        } label: {
            Label("Connection Doctor", systemImage: "waveform.path.ecg")
        }
    }

    @ViewBuilder
    private func stepRow(_ step: DoctorStep) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusPill(step.status)
                .frame(width: 70, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.callout.weight(.medium))
                if !step.detail.isEmpty {
                    Text(step.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            if (step.status == .fail || step.status == .warn), let fix = step.fixTitle {
                Button(fix) {
                    Task { await applyFix(for: step) }
                }
                .controlSize(.small)
                .disabled(running)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusPill(_ status: StepStatus) -> some View {
        switch status {
        case .pending:
            Label("pending", systemImage: "circle")
                .foregroundStyle(.tertiary)
                .font(.caption2)
                .labelStyle(.titleAndIcon)
        case .running:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("running").font(.caption2).foregroundStyle(.secondary)
            }
        case .ok:
            Label("ok", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption2)
        case .warn:
            Label("warn", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption2)
        case .fail:
            Label("fail", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.caption2)
        }
    }

    // MARK: - Steps

    private static func initialSteps() -> [DoctorStep] {
        [
            DoctorStep(id: 0, title: "Helper binary present",
                       detail: "Checks dc-hook exists at its stable path and is executable.",
                       status: .pending, fixTitle: "Reinstall helper"),
            DoctorStep(id: 1, title: "Socket listening",
                       detail: "Confirms the in-app unix socket is bound and accepting connections.",
                       status: .pending, fixTitle: "Restart listener"),
            DoctorStep(id: 2, title: "Config parsed & events mapped",
                       detail: "Verifies every expected hook event is mapped to the correct binary.",
                       status: .pending, fixTitle: "Repair"),
            DoctorStep(id: 3, title: "End-to-end ping round-trip",
                       detail: "Sends dc-hook --ping and waits for the envelope to arrive over the socket.",
                       status: .pending, fixTitle: "Check helper permissions"),
            DoctorStep(id: 4, title: "Notification dispatch",
                       detail: "Posts a local test notification via macOS Notification Center.",
                       status: .pending, fixTitle: "Open notification settings")
        ]
    }

    // MARK: - Run

    private func runDoctor() async {
        running = true
        summary = nil
        steps = Self.initialSteps()
        var failures = 0
        var firstFailedIndex: Int? = nil

        for idx in steps.indices {
            if firstFailedIndex != nil { break }
            setStatus(idx, .running)
            let outcome = await runStep(idx)
            setStatus(idx, outcome.status, detail: outcome.detail)
            if outcome.status == .fail || outcome.status == .warn {
                failures += 1
                if firstFailedIndex == nil { firstFailedIndex = idx }
            }
        }

        running = false
        if failures == 0 {
            summary = "Connected"
            summaryIsGood = true
        } else {
            summary = "\(failures) issue\(failures == 1 ? "" : "s") found"
            summaryIsGood = false
        }
    }

    private struct StepOutcome {
        let status: StepStatus
        let detail: String
    }

    private func runStep(_ idx: Int) async -> StepOutcome {
        switch idx {
        case 0: return checkHelperBinary()
        case 1: return checkSocketListening()
        case 2: return checkConfigMapping()
        case 3: return await checkEndToEndPing()
        case 4: return await checkNotificationDispatch()
        default: return StepOutcome(status: .ok, detail: "")
        }
    }

    private func setStatus(_ idx: Int, _ status: StepStatus, detail: String? = nil) {
        guard idx < steps.count else { return }
        var step = steps[idx]
        step.status = status
        if let detail { step.detail = detail }
        steps[idx] = step
    }

    // MARK: - Step implementations

    private func checkHelperBinary() -> StepOutcome {
        let path = AgentInstallerV2.helperBinaryPath()
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            return StepOutcome(status: .fail, detail: "Not found at \(path).")
        }
        if !fm.isExecutableFile(atPath: path) {
            return StepOutcome(status: .fail, detail: "Not executable: \(path).")
        }
        return StepOutcome(status: .ok, detail: "Found at \(path).")
    }

    private func checkSocketListening() -> StepOutcome {
        if HookSocketListener.shared.isRunning {
            return StepOutcome(status: .ok, detail: "Listener bound and accepting connections.")
        }
        return StepOutcome(status: .fail, detail: "In-app unix socket listener is not running.")
    }

    private func checkConfigMapping() -> StepOutcome {
        switch AgentInstallerV2.verifyInstalled(agent) {
        case .success:
            return StepOutcome(status: .ok, detail: "All expected hook events mapped.")
        case .failure(let err):
            return StepOutcome(status: .fail, detail: err.localizedDescription)
        }
    }

    private func checkEndToEndPing() async -> StepOutcome {
        // Register a one-shot observer on the shared socket listener so
        // we can confirm the envelope actually made the round-trip.
        let listener = HookSocketListener.shared
        let pidStr = String(ProcessInfo.processInfo.processIdentifier)
        let box = EnvelopeBox()
        listener.setTestObserver { env in
            if env.event.lowercased() == "unknown" || env.event.lowercased().contains("ping") {
                box.signal(env)
            }
        }
        defer { listener.setTestObserver(nil) }

        let helperPath = AgentInstallerV2.helperBinaryPath()
        guard FileManager.default.isExecutableFile(atPath: helperPath) else {
            return StepOutcome(status: .fail, detail: "Helper binary missing or not executable.")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: helperPath)
        proc.arguments = ["--ping"]
        do {
            try proc.run()
        } catch {
            return StepOutcome(status: .fail, detail: "Failed to launch dc-hook --ping: \(error.localizedDescription)")
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            return StepOutcome(status: .fail, detail: "dc-hook --ping exited with status \(proc.terminationStatus). Host pid: \(pidStr).")
        }

        // Wait up to 5s for an envelope to arrive via the socket.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if box.received { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if box.received {
            return StepOutcome(status: .ok, detail: "Ping envelope received on socket within 5s.")
        }
        return StepOutcome(status: .fail, detail: "dc-hook --ping exited 0 but no envelope arrived on the socket within 5s.")
    }

    private func checkNotificationDispatch() async -> StepOutcome {
        let disp = NotificationDispatcher.shared
        let granted: Bool = await withCheckedContinuation { cont in
            disp.requestPermission { ok in cont.resume(returning: ok) }
        }
        if !granted {
            return StepOutcome(status: .fail, detail: "macOS notifications are not authorized for DoomCoder.")
        }
        let content = UNMutableNotificationContent()
        content.title = "Doom Coder · Doctor"
        content.body = "Connection Doctor test — this is not a real agent event."
        content.categoryIdentifier = "doomcoder.doctor"
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(req)
            return StepOutcome(status: .ok, detail: "Test notification posted. You should see a banner momentarily.")
        } catch {
            return StepOutcome(status: .fail, detail: "Failed to post notification: \(error.localizedDescription)")
        }
    }

    // MARK: - Fixes

    private func applyFix(for step: DoctorStep) async {
        switch step.id {
        case 0:
            _ = AgentInstallerV2.ensureStableHelper()
        case 1:
            // Restart listener in-place. The primary callback is owned by
            // the AppDelegate, so stop+start without a new callback is
            // deliberately skipped — we ping again instead.
            HookSocketListener.shared.stop()
            // Give the raw fd time to close + rebind via AppDelegate
            // lifecycle. We don't re-subscribe the primary callback from
            // here. The user can relaunch if the listener is wedged.
            try? await Task.sleep(nanoseconds: 400_000_000)
        case 2:
            _ = AgentInstallerV2.install(agent)
        case 3:
            // Nothing we can do programmatically — point user at perms.
            NSWorkspace.shared.selectFile(AgentInstallerV2.helperBinaryPath(),
                                          inFileViewerRootedAtPath: "")
        case 4:
            NotificationDispatcher.shared.openSystemSettings()
        default:
            break
        }
        await runDoctor()
    }
}

/// Thread-safe one-shot flag used by the end-to-end ping step to signal
/// when the expected envelope arrives from the socket listener.
private final class EnvelopeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _received = false
    var received: Bool { lock.lock(); defer { lock.unlock() }; return _received }
    func signal(_ env: HookEnvelope) {
        lock.lock(); _received = true; lock.unlock()
    }
}
