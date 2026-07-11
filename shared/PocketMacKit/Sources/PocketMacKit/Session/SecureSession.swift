import Foundation

/// The transport-agnostic send/receive pipeline — the piece that makes LAN and relay identical.
///
/// ```
/// send:    Frame → codec.encode → channel.seal → transport.send
/// receive: transport.receive → channel.open → codec.decode → Frame
/// ```
/// An `actor` so the mutating ``SecureChannel`` (send counter, replay window) is accessed serially.
/// Seal only touches send state and open only touches receive state, and each mutation is synchronous
/// (never spans an `await`), so the two directions never race.
public actor SecureSession {
    private let transport: any Transport
    private var channel: any SecureChannel
    private let codec: any FrameCoding

    /// The authenticated peer on the other end.
    public let peerID: PeerID

    public init(transport: any Transport, channel: any SecureChannel, codec: any FrameCoding = FrameCodec()) {
        self.transport = transport
        self.channel = channel
        self.codec = codec
        self.peerID = channel.peerID
    }

    /// Encrypts and sends one frame.
    public func send(_ frame: Frame) async throws {
        let plaintext = try codec.encode(frame)
        let record = try channel.seal(plaintext)
        try await transport.send(record)
    }

    /// Receives, decrypts, and decodes one frame. Replays and tampering surface as thrown errors.
    public func receiveFrame() async throws -> Frame {
        let record = try await transport.receive()
        let plaintext = try channel.open(record)
        return try codec.decode(plaintext)
    }

    /// Runs a receive loop until cancelled or the transport closes, handing each decoded frame to
    /// `onFrame`. Decode/decrypt errors for a single frame are surfaced via `onError` and the loop
    /// continues (a bad frame should not tear down a good session); transport errors end the loop.
    public func run(
        onFrame: @Sendable (Frame) async -> Void,
        onError: @Sendable (Error) async -> Void = { _ in }
    ) async {
        while !Task.isCancelled {
            do {
                let record = try await transport.receive()
                do {
                    let frame = try codec.decode(try channel.open(record))
                    await onFrame(frame)
                } catch {
                    await onError(error) // frame-level failure — keep the session alive
                }
            } catch {
                await onError(error) // transport-level failure — stop
                return
            }
        }
    }

    public func close() {
        transport.close()
    }
}
