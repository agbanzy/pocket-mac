import Foundation
import Network

/// Advertises the Mac helper on the LAN via `NWListener` and surfaces inbound connections.
///
/// Uses unicast Bonjour over TCP, so it needs **no** `com.apple.developer.networking.multicast`
/// entitlement (that gates only raw multicast/broadcast and would complicate App Review).
public final class BonjourAdvertising: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.innoedge.pocketmac.advertise")
    private var listener: NWListener?

    public init() {}

    /// Starts advertising `instanceName` and returns a stream of incoming `NWConnection`s (each
    /// unstarted — the caller wraps it in an ``NWConnectionTransport`` and starts it).
    public func start(instanceName: String) throws -> AsyncStream<NWConnection> {
        let listener = try NWListener(using: .tcp)
        listener.service = NWListener.Service(name: instanceName, type: PocketMac.bonjourServiceType)
        self.listener = listener
        let queue = self.queue

        return AsyncStream<NWConnection> { continuation in
            listener.newConnectionHandler = { connection in
                continuation.yield(connection)
            }
            listener.stateUpdateHandler = { state in
                if case .cancelled = state { continuation.finish() }
                if case .failed = state { continuation.finish() }
            }
            continuation.onTermination = { _ in listener.cancel() }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }
}
