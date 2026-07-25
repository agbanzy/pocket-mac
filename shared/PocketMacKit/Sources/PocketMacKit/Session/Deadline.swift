import Foundation

/// Thrown when an operation wrapped in ``withDeadline(_:operation:)`` runs out of time.
public struct DeadlineExceeded: Error, CustomStringConvertible {
    public let seconds: Double
    public init(seconds: Double) { self.seconds = seconds }
    public var description: String { "timed out after \(Int(seconds))s" }
}

/// Run `operation`, failing if it has not finished within `seconds`.
///
/// Every step of connecting is a read from a socket that a peer may simply never write to, and none
/// of them had a deadline. A phone that opened a TCP connection and then said nothing left the Mac
/// parked in `transport.receive()` forever, holding the connection open; the sockets accumulated one
/// per retry and were never closed. On the phone the same gap showed as a session stuck on
/// "Connecting" with no error, which hides whatever actually went wrong.
///
/// A deadline converts both into something observable: the loser is cancelled, the caller gets an
/// error it can show or log, and the connection can be closed.
public func withDeadline<T: Sendable>(
    _ seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw DeadlineExceeded(seconds: seconds)
        }
        // Whichever finishes first decides; cancelling the group stops the other.
        guard let first = try await group.next() else {
            throw DeadlineExceeded(seconds: seconds)
        }
        group.cancelAll()
        return first
    }
}
