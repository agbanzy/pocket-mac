import Foundation

/// Thrown when an operation wrapped in ``withDeadline(_:operation:)`` runs out of time.
public struct DeadlineExceeded: Error, CustomStringConvertible {
    public let seconds: Double
    public init(seconds: Double) { self.seconds = seconds }
    public var description: String { "timed out after \(Int(seconds))s" }
}

/// Run `operation`, failing if it has not finished within `seconds`.
///
/// Every step of connecting is a read from a socket a peer may never write to, and none of them had
/// a deadline. A peer that opened a TCP connection and then said nothing left the Mac parked in
/// `transport.receive()` forever, holding the connection; sockets accumulated one per retry. On the
/// phone the same gap showed as a session stuck on "Connecting" with no error.
///
/// ## `onExpiry` is not optional in practice — cancellation alone does nothing here
///
/// The obvious shape (race a sleeper, cancel the loser) does **not** work for these transports, and
/// silently so. Two facts combine:
///
/// 1. When the sleeper throws, `withThrowingTaskGroup` cancels the remaining children and then
///    **awaits them** before rethrowing. Structured concurrency will not let the group return while
///    a child is still running, so `group.cancelAll()` below is never even reached on the timeout
///    path.
/// 2. `NWConnectionTransport.receiveExactly` and `RelayTransport.receive` are bare
///    `withCheckedThrowingContinuation`s around a framework read, with no cancellation handler.
///    Cancelling them is a no-op: the continuation resumes only when bytes or an error arrive.
///
/// So the operation child parks forever, the group waits on it forever, and the deadline that was
/// supposed to make the failure observable produces the exact hang it was written to prevent —
/// measured: a silent client held a connection open indefinitely, no error, no close.
///
/// `onExpiry` is what breaks the tie. It runs **before** the error is thrown, so closing the socket
/// there resumes the parked read with an error, the child finishes, and the group can unwind.
/// Callers that pass a transport read must close it here; there is no other way out.
public func withDeadline<T: Sendable>(
    _ seconds: Double,
    onExpiry: (@Sendable () -> Void)? = nil,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            // Unblock the operation first — see the note above. Throwing before this would deadlock
            // against the very child the group is about to wait for.
            onExpiry?()
            throw DeadlineExceeded(seconds: seconds)
        }
        guard let first = try await group.next() else {
            throw DeadlineExceeded(seconds: seconds)
        }
        group.cancelAll()
        return first
    }
}
