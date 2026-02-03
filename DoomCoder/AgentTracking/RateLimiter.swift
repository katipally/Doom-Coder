import Foundation

/// Per-agent token-bucket rate limiter. Prevents tight-loop notification
/// storms (e.g. an agent failing in a retry loop). Allows a small burst,
/// then refills at a steady rate.
///
/// Defaults: capacity 6, refill 12/min (one token every 5 s).
/// Override via UserDefaults:
///   - `doomcoder.rateLimit.burst`      (Int, default 6)
///   - `doomcoder.rateLimit.perMinute`  (Int, default 12)
final class RateLimiter: @unchecked Sendable {
    static let shared = RateLimiter()

    private struct Bucket {
        var tokens: Double
        var lastRefill: Date
        var didEmitWarning: Bool
    }

    private let lock = NSLock()
    private var buckets: [TrackedAgent: Bucket] = [:]

    private var capacity: Double {
        let v = UserDefaults.standard.object(forKey: "doomcoder.rateLimit.burst") as? Int
        return Double(v ?? 6)
    }

    private var refillPerSecond: Double {
        let perMinute = UserDefaults.standard.object(forKey: "doomcoder.rateLimit.perMinute") as? Int ?? 12
        return Double(perMinute) / 60.0
    }

    /// Attempts to consume a token for `agent`. Returns true if allowed.
    /// On the first drop in a window, returns `.dropped(emitWarning: true)`
    /// so the dispatcher can emit a single informational rate-limit notif;
    /// subsequent drops in the same depleted window return
    /// `.dropped(emitWarning: false)` and the dispatcher stays silent.
    enum Decision {
        case allow
        case dropped(emitWarning: Bool)
    }

    func evaluate(agent: TrackedAgent) -> Decision {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        var b = buckets[agent] ?? Bucket(tokens: capacity, lastRefill: now, didEmitWarning: false)
        let elapsed = now.timeIntervalSince(b.lastRefill)
        b.tokens = min(capacity, b.tokens + elapsed * refillPerSecond)
        b.lastRefill = now
        if b.tokens >= 1 {
            b.tokens -= 1
            b.didEmitWarning = false
            buckets[agent] = b
            return .allow
        } else {
            let shouldWarn = !b.didEmitWarning
            b.didEmitWarning = true
            buckets[agent] = b
            return .dropped(emitWarning: shouldWarn)
        }
    }
}
