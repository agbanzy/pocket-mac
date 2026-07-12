import Foundation
import PocketMacKit

/// Keeps the Mac reachable **through the relay** when it isn't on the phone's LAN.
///
/// For each rendezvous it should serve (a paired peer's token, or the active pairing token), it holds
/// an outbound WSS connection to the relay as the Noise **responder** and waits for the phone to meet
/// it there. When the session ends — or the relay times out a lonely waiter — it re-dials with a
/// short backoff. This is a polling rendezvous; a later APNs "wake" (Phase 11) lets the phone signal
/// the Mac to dial in on demand instead of parking connections.
///
/// Honest limit: this only works while the Mac is **awake**. Asleep, the outbound socket dies and the
/// Mac is unreachable until it wakes (the opt-in keep-awake toggle addresses that trade-off).
final class RelayReachability: @unchecked Sendable {
    private let accepter: SessionAccepter
    private let translator: CGEventTranslator
    private let actions: ActionExecutor
    private let backoff: Duration

    private let lock = NSLock()
    private var tasks: [String: Task<Void, Never>] = [:]

    init(accepter: SessionAccepter, translator: CGEventTranslator, actions: ActionExecutor,
         backoff: Duration = .seconds(2)) {
        self.accepter = accepter
        self.translator = translator
        self.actions = actions
        self.backoff = backoff
    }

    /// Starts (or restarts) a maintained responder rendezvous, keyed by `id` so it can be replaced or
    /// stopped later. `authorize` gates who may open the session; `prologue` binds the SAS during a
    /// pairing window (empty for an already-paired peer).
    /// - Parameter continueWhile: checked at the top of each loop iteration. The pairing responder
    ///   passes `{ gate.value }` so that once the pairing window closes (gate consumed or expired) it
    ///   self-terminates AFTER its current session finishes — never cancelled mid-session. Per-peer
    ///   reconnect responders pass `{ true }` to loop indefinitely.
    func startResponder(
        id: String,
        relayURL: URL,
        token: Data,
        prologue: Data,
        privateKeyData: Data,
        continueWhile: @escaping @Sendable () -> Bool = { true },
        authorize: @escaping @Sendable (PeerID, Data) -> Bool
    ) {
        let task = Task { [accepter, translator, actions, backoff] in
            while !Task.isCancelled && continueWhile() {
                let transport = RelayTransport(relayURL: relayURL, rendezvousToken: token)
                await accepter.serve(
                    transport: transport, privateKeyData: privateKeyData, prologue: prologue,
                    authorize: authorize, translator: translator, actions: actions)
                if Task.isCancelled || !continueWhile() { break }
                try? await Task.sleep(for: backoff) // session ended / timed out — re-establish
            }
        }
        lock.lock()
        tasks[id]?.cancel()
        tasks[id] = task
        lock.unlock()
    }

    func stop(id: String) {
        lock.lock(); let task = tasks.removeValue(forKey: id); lock.unlock()
        task?.cancel()
    }

    func stopAll() {
        lock.lock(); let all = tasks; tasks.removeAll(); lock.unlock()
        all.values.forEach { $0.cancel() }
    }
}
