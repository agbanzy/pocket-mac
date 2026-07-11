import Foundation

/// A ``Transport`` over the zero-knowledge relay's WebSocket (WSS), for the away-from-home path.
///
/// Both peers open an outbound WSS connection to the relay and send one HELLO — the hex-encoded
/// rendezvous token — as the first message. The relay matches the two connections sharing a token
/// and blind-forwards every subsequent message verbatim. Because WSS already delimits messages, one
/// WS message carries exactly one sealed record (no length prefix needed, unlike the TCP transport).
///
/// The relay sees only the cleartext token and opaque ciphertext — it never terminates the
/// ``SecureSession``'s encryption, so this transport is interchangeable with ``NWConnectionTransport``
/// above the security layer. That's the "keyed to identity, not path" invariant made concrete.
public final class RelayTransport: Transport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let rendezvousToken: Data

    /// - Parameters:
    ///   - relayURL: the relay's `wss://…/ws` endpoint.
    ///   - rendezvousToken: the 16-byte routing token minted at pairing time (from ``PairingPayload``).
    public init(relayURL: URL, rendezvousToken: Data, session: URLSession = .shared) {
        self.task = session.webSocketTask(with: relayURL)
        self.rendezvousToken = rendezvousToken
    }

    public func start() async throws {
        task.resume()
        // HELLO: the hex-encoded rendezvous token as the first (text) message.
        try await task.send(.string(rendezvousToken.hexEncodedString))
    }

    public func send(_ record: Data) async throws {
        guard record.count <= maxTransportRecordSize else {
            throw TransportError.recordTooLarge(declared: record.count, cap: maxTransportRecordSize)
        }
        try await task.send(.data(record))
    }

    public func receive() async throws -> Data {
        switch try await task.receive() {
        case .data(let data):
            return data
        case .string(let string):
            // The relay only ever forwards our peer's binary records; a text frame is unexpected.
            return Data(string.utf8)
        @unknown default:
            throw TransportError.closed
        }
    }

    public func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

public extension Data {
    /// Lowercase hex encoding — the relay hex-decodes the HELLO token.
    var hexEncodedString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
