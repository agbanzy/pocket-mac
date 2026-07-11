import Foundation

/// Rejects replayed or reordered records by their monotonic counter.
///
/// For Milestone 0 the transport is ordered, reliable TCP (LAN `NWConnection`), so a **strictly
/// increasing** policy is correct and simplest: any counter ≤ the highest seen is dropped. When the
/// relay path introduces possible reordering, this is replaced with a sliding-window bitmap (the
/// interface stays the same); that upgrade is tracked in the plan's Phase 12.
public struct ReplayWindow: Sendable {
    private var highestSeen: UInt64?

    public init() {}

    /// Validates and records an incoming counter. Throws ``CryptoError/replayDetected(counter:)``
    /// if the counter does not strictly exceed every counter seen so far.
    public mutating func validate(_ counter: UInt64) throws {
        if let highest = highestSeen, counter <= highest {
            throw CryptoError.replayDetected(counter: counter)
        }
        highestSeen = counter
    }
}
