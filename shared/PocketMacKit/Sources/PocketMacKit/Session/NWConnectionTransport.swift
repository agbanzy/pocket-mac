import Foundation
import Network

/// A ``Transport`` over an established `NWConnection` (LAN, and — later — the relay's tunnelled
/// connection). Records are delimited with a 4-byte big-endian length prefix over the byte stream.
///
/// `NWConnection` is thread-safe when driven from a target queue but is not `Sendable`; it is
/// confined to a private serial queue here and the type is `@unchecked Sendable` on that basis.
public final class NWConnectionTransport: Transport, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    public init(connection: NWConnection, queue: DispatchQueue = DispatchQueue(label: "com.innoedge.pocketmac.transport")) {
        self.connection = connection
        self.queue = queue
    }

    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumer = ContinuationResumer(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumer.resume(returning: ())
                case .failed(let error):
                    resumer.resume(throwing: TransportError.connectionFailed(String(describing: error)))
                case .cancelled:
                    resumer.resume(throwing: TransportError.closed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    public func send(_ record: Data) async throws {
        guard record.count <= maxTransportRecordSize else {
            throw TransportError.recordTooLarge(declared: record.count, cap: maxTransportRecordSize)
        }
        var framed = Data(capacity: 4 + record.count)
        var length = UInt32(record.count).bigEndian
        framed.append(withUnsafeBytes(of: &length) { Data($0) })
        framed.append(record)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumer = ContinuationResumer(continuation)
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error {
                    resumer.resume(throwing: TransportError.connectionFailed(String(describing: error)))
                } else {
                    resumer.resume(returning: ())
                }
            })
        }
    }

    public func receive() async throws -> Data {
        let header = try await receiveExactly(4)
        let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let count = Int(length)
        guard count > 0 else { return Data() }
        guard count <= maxTransportRecordSize else {
            throw TransportError.recordTooLarge(declared: count, cap: maxTransportRecordSize)
        }
        return try await receiveExactly(count)
    }

    public func close() {
        connection.cancel()
    }

    /// Reads exactly `count` bytes, coalescing partial deliveries.
    private func receiveExactly(_ count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let resumer = ContinuationResumer(continuation)
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { content, _, isComplete, error in
                if let error {
                    resumer.resume(throwing: TransportError.connectionFailed(String(describing: error)))
                } else if let content, content.count == count {
                    resumer.resume(returning: content)
                } else if isComplete {
                    resumer.resume(throwing: TransportError.closed)
                } else {
                    resumer.resume(throwing: TransportError.connectionFailed("short read"))
                }
            }
        }
    }
}

/// Guards a `CheckedContinuation` against a double-resume (defensive: `NWConnection` handlers can, in
/// edge cases, fire more than once). Resumes at most once.
private final class ContinuationResumer<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock(); defer { lock.unlock() }
        continuation?.resume(returning: value)
        continuation = nil
    }

    func resume(throwing error: Error) {
        lock.lock(); defer { lock.unlock() }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
