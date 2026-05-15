import Foundation

// Polls CPU% for a given PID via `ps` every 5 seconds.
// Calls `onHigh` when ≥ 5% CPU (agent is actively computing),
// `onLow` when < 5% (agent is idle / waiting).
final class CLICPUProbe: @unchecked Sendable {
    private let pid: pid_t
    private let onHigh: @Sendable () -> Void
    private let onLow:  @Sendable () -> Void
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "dc.CLICPUProbe", qos: .utility)
    private let threshold: Double = 5.0
    private let intervalSecs: Double = 5.0

    init(pid: pid_t,
         onHigh: @escaping @Sendable () -> Void,
         onLow: @escaping @Sendable () -> Void) {
        self.pid = pid
        self.onHigh = onHigh
        self.onLow = onLow
        start()
    }

    deinit { stop() }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + intervalSecs,
                   repeating: intervalSecs,
                   leeway: .seconds(1))
        let pid = self.pid
        let hi = onHigh; let lo = onLow
        let thresh = threshold
        t.setEventHandler {
            let cpu = CLICPUProbe.sample(pid: pid)
            if cpu >= thresh { hi() } else { lo() }
        }
        t.resume()
        timer = t
    }

    private static func sample(pid: pid_t) -> Double {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-o", "%cpu", "-p", "\(pid)"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch { return 0 }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let lines = String(data: data, encoding: .utf8)?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        // First line is the "%cpu" header, second is the value.
        if lines.count >= 2, let val = Double(lines[1]) { return val }
        return 0
    }
}
