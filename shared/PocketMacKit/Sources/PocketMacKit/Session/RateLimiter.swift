import Foundation

/// A token-bucket rate limiter — the floor against a runaway or hostile client flooding input
/// events at the Mac. The helper consults it per inbound frame; over-budget frames are dropped.
///
/// `now` is injectable so the policy is deterministically testable without waiting on the clock.
public struct RateLimiter: Sendable {
    private let capacity: Double
    private let refillPerSecond: Double
    private var tokens: Double
    private var lastRefill: TimeInterval

    /// - Parameters:
    ///   - capacity: burst size (max tokens).
    ///   - refillPerSecond: sustained rate.
    ///   - now: current monotonic-ish seconds; defaults to wall clock.
    public init(capacity: Double, refillPerSecond: Double, now: TimeInterval = Date().timeIntervalSinceReferenceDate) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
        self.tokens = capacity
        self.lastRefill = now
    }

    /// Returns `true` and consumes `cost` tokens if the budget allows; otherwise returns `false`.
    public mutating func allow(cost: Double = 1, now: TimeInterval = Date().timeIntervalSinceReferenceDate) -> Bool {
        let elapsed = max(0, now - lastRefill)
        tokens = min(capacity, tokens + elapsed * refillPerSecond)
        lastRefill = now
        guard tokens >= cost else { return false }
        tokens -= cost
        return true
    }
}
