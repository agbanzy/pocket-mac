import Foundation
@preconcurrency import Network
import PocketMacKit

/// Advertises the helper on the LAN (`_pocketmac._tcp`) and hands each inbound connection to the
/// caller already wrapped in an ``NWConnectionTransport`` (Sendable), so raw `NWConnection` values
/// never cross a concurrency boundary.
final class ListenerService: @unchecked Sendable {
    private let advertising = BonjourAdvertising()
    private var task: Task<Void, Never>?

    func start(instanceName: String, onTransport: @escaping @Sendable (NWConnectionTransport) -> Void) throws {
        let stream = try advertising.start(instanceName: instanceName)
        task = Task {
            for await connection in stream {
                // Wrap at the source; the transport (not the connection) is what travels onward.
                onTransport(NWConnectionTransport(connection: connection))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        advertising.stop()
    }
}
