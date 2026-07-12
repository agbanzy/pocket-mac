// The browser session controller — counterpart of
//   ios/PocketMac/Connection/ConnectionController.swift
//
// Lifecycle: open the relay transport → run the Noise IK handshake as INITIATOR (the browser knows
// the Mac's static key from pairing) → bring up the AEAD record channel → send the app HELLO → start
// the 2s ping heartbeat and the receive loop → ask the Mac to start streaming. Input frames are sealed
// and sent fire-and-forget in order. Everything below the transport is identical to the LAN path.

import { RelayTransport } from '../transport/relay';
import { NoiseHandshakeIK } from '../crypto/noise';
import { AEADChannel } from '../crypto/aead';
import { BrowserIdentity } from '../crypto/identity';
import { PairingPayload } from '../crypto/pairing';
import { control, decodeFrame, encodeFrame, Frame, FrameDomain, InputFrame } from '../protocol/frames';
import { ReassembledFrame, VideoReassembler } from '../protocol/video';

export type ConnState =
  | { t: 'idle' }
  | { t: 'connecting' }
  | { t: 'secured' }
  | { t: 'offline'; reason: string };

export interface ConnectionCallbacks {
  onState: (state: ConnState) => void;
  onLatency: (ms: number | null) => void;
  onVideoFrame: (frame: ReassembledFrame) => void;
}

const EMPTY = new Uint8Array(0);
const APP_VERSION = '1.0';

export class Connection {
  private transport: RelayTransport | null = null;
  private channel: AEADChannel | null = null;
  private reassembler = new VideoReassembler();
  private heartbeat: ReturnType<typeof setInterval> | null = null;
  private pendingPings = new Map<number, number>(); // nonce -> sent-at (ms)
  private pingNonce = 0;
  private generation = 0; // bumps on every connect/disconnect so stale loops exit

  constructor(
    private readonly relayURL: string,
    private readonly cb: ConnectionCallbacks,
  ) {}

  get isSecured(): boolean {
    return this.channel !== null;
  }

  /** Establishes an encrypted session over the relay using the paired Mac's payload. Never throws. */
  async connect(payload: PairingPayload, identity: BrowserIdentity): Promise<void> {
    this.disconnect();
    const gen = ++this.generation;
    const transport = new RelayTransport(this.relayURL, payload.rendezvousToken);
    this.cb.onState({ t: 'connecting' });

    try {
      await transport.start();

      // The browser is the Noise initiator; it already knows the Mac's static key from pairing.
      const hs = new NoiseHandshakeIK('initiator', identity.privateKey, payload.macPublicKey, EMPTY);
      transport.send(hs.writeMessage1());
      hs.readMessage2(await transport.receive());
      const keys = hs.makeSessionKeys();

      if (gen !== this.generation) {
        transport.close();
        return;
      }

      this.transport = transport;
      this.channel = new AEADChannel(keys);
      this.cb.onState({ t: 'secured' });

      this.startReceiveLoop(gen);
      this.startHeartbeat();

      // Post-handshake application hello so the Mac can show who connected, then start streaming.
      this.send(control({ t: 'hello', deviceName: browserName(), appVersion: APP_VERSION, capabilities: 0 }));
      this.startVideo(30);
    } catch (err) {
      transport.close();
      if (gen === this.generation) {
        this.teardown();
        this.cb.onState({ t: 'offline', reason: describe(err) });
      }
    }
  }

  /** Tears the session down and returns to idle. Safe to call repeatedly. */
  disconnect(): void {
    const wasLive = this.transport !== null || this.channel !== null;
    this.generation++;
    this.teardown();
    if (wasLive) this.cb.onState({ t: 'idle' });
  }

  // MARK: outbound (hot path — synchronous, ordered)

  send(frame: Frame): void {
    const ch = this.channel;
    const tr = this.transport;
    if (!ch || !tr) return;
    try {
      tr.send(ch.seal(encodeFrame(frame)));
    } catch (err) {
      this.linkFailed(err);
    }
  }

  sendInput(i: InputFrame): void {
    this.send({ domain: FrameDomain.Input, input: i });
  }

  startVideo(fps = 30): void {
    this.send(control({ t: 'startVideo', fps }));
  }

  stopVideo(): void {
    this.send(control({ t: 'stopVideo' }));
  }

  // MARK: receive / heartbeat

  private async startReceiveLoop(gen: number): Promise<void> {
    const tr = this.transport;
    const ch = this.channel;
    if (!tr || !ch) return;
    while (gen === this.generation) {
      let record: Uint8Array;
      try {
        record = await tr.receive();
      } catch (err) {
        if (gen === this.generation) this.linkFailed(err); // transport-level failure — stop
        return;
      }
      try {
        this.handle(decodeFrame(ch.open(record)));
      } catch {
        // Frame-level decode/replay error — a single bad frame must not drop a good session.
      }
    }
  }

  private startHeartbeat(): void {
    this.heartbeat = setInterval(() => {
      if (!this.channel) return;
      this.pingNonce = (this.pingNonce + 1) >>> 0;
      const nonce = this.pingNonce;
      this.pendingPings.set(nonce, performance.now());
      this.send(control({ t: 'ping', nonce }));
    }, 2000);
  }

  private handle(frame: Frame): void {
    if (frame.domain === FrameDomain.Control) {
      const c = frame.control;
      if (c.t === 'pong') {
        const sent = this.pendingPings.get(c.nonce);
        if (sent !== undefined) {
          this.pendingPings.delete(c.nonce);
          this.cb.onLatency(Math.round(performance.now() - sent));
        }
      } else if (c.t === 'ping') {
        this.send(control({ t: 'pong', nonce: c.nonce }));
      }
    } else if (frame.domain === FrameDomain.Video) {
      const done = this.reassembler.accept(frame.video);
      if (done) this.cb.onVideoFrame(done);
    }
  }

  private linkFailed(err: unknown): void {
    const reason = describe(err);
    this.teardown();
    this.cb.onState({ t: 'offline', reason });
  }

  private teardown(): void {
    if (this.heartbeat !== null) {
      clearInterval(this.heartbeat);
      this.heartbeat = null;
    }
    this.transport?.close();
    this.transport = null;
    this.channel = null;
    this.pendingPings.clear();
    this.reassembler = new VideoReassembler();
    this.cb.onLatency(null);
  }
}

function browserName(): string {
  const ua = navigator.userAgent;
  if (ua.includes('Edg/')) return 'Edge browser';
  if (ua.includes('Chrome/')) return 'Chrome browser';
  if (ua.includes('Firefox/')) return 'Firefox browser';
  if (ua.includes('Safari/')) return 'Safari browser';
  return 'Browser';
}

function describe(err: unknown): string {
  const msg = err instanceof Error ? err.message : String(err);
  if (/authoriz|handshake|decrypt|tag/i.test(msg)) return 'Handshake failed — check the pairing code';
  return msg || 'Disconnected';
}
