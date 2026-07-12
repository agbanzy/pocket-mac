// WebSocket message pump to the zero-knowledge relay — the browser counterpart of
//   shared/PocketMacKit/Sources/PocketMacKit/Session/RelayTransport.swift
//
// Open WSS, send the hex-encoded rendezvous token as the first (text) HELLO, then every
// subsequent binary WS message carries exactly one record verbatim — a raw Noise handshake
// message during the handshake, a sealed AEAD record afterwards. Because WSS already delimits
// messages, one message == one record (no length prefix, unlike the LAN TCP transport).
//
// The relay blind-forwards and never sees plaintext, so this transport is interchangeable with
// the LAN one above the security layer: "keyed to identity, not path."

import { bytesToHex } from '../crypto/pairing';

/** A minimal message transport: ordered binary send + awaitable receive, with a HELLO on start. */
export class RelayTransport {
  private ws: WebSocket | null = null;
  private opened = false;
  // Inbound records buffer + a single pending receive() waiter (receive is called serially).
  private inbox: Uint8Array[] = [];
  private waiter: { resolve: (d: Uint8Array) => void; reject: (e: Error) => void } | null = null;
  private failure: Error | null = null;

  constructor(
    private readonly url: string,
    private readonly rendezvousToken: Uint8Array,
  ) {}

  /** Opens the socket and sends the HELLO. Resolves once the socket is open. */
  start(): Promise<void> {
    return new Promise((resolve, reject) => {
      let settled = false;
      const ws = new WebSocket(this.url);
      ws.binaryType = 'arraybuffer';
      this.ws = ws;

      ws.onopen = () => {
        this.opened = true;
        settled = true;
        ws.send(bytesToHex(this.rendezvousToken)); // HELLO: hex token as a text frame
        resolve();
      };
      ws.onmessage = (ev) => this.deliver(ev.data);
      ws.onclose = () => this.fail(new Error(this.opened ? 'Connection closed' : "Couldn't reach the relay"));
      ws.onerror = () => {
        if (!settled) {
          settled = true;
          reject(new Error("Couldn't reach the relay"));
        }
        // Post-open errors surface through onclose → fail().
      };
    });
  }

  /** Sends one record. Synchronous and order-preserving, matching the iOS hot path. */
  send(record: Uint8Array): void {
    const ws = this.ws;
    if (!ws || ws.readyState !== WebSocket.OPEN) throw this.failure ?? new Error('Connection not ready');
    ws.send(record);
  }

  /** Awaits the next inbound record. Rejects if the transport has failed/closed. */
  receive(): Promise<Uint8Array> {
    if (this.inbox.length > 0) return Promise.resolve(this.inbox.shift()!);
    if (this.failure) return Promise.reject(this.failure);
    return new Promise((resolve, reject) => {
      this.waiter = { resolve, reject };
    });
  }

  close(): void {
    this.ws?.close();
    this.ws = null;
  }

  // ---- internals ----

  private deliver(data: unknown): void {
    // The relay only ever forwards our peer's binary records; coerce an unexpected text frame to bytes
    // for parity with the Swift transport rather than dropping it.
    const bytes =
      data instanceof ArrayBuffer
        ? new Uint8Array(data)
        : typeof data === 'string'
          ? new TextEncoder().encode(data)
          : new Uint8Array(0);
    if (this.waiter) {
      const w = this.waiter;
      this.waiter = null;
      w.resolve(bytes);
    } else {
      this.inbox.push(bytes);
    }
  }

  private fail(error: Error): void {
    if (this.failure) return;
    this.failure = error;
    if (this.waiter) {
      const w = this.waiter;
      this.waiter = null;
      w.reject(error);
    }
  }
}
