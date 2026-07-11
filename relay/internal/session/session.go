// Package session implements the blind, zero-knowledge byte pump at the heart
// of the relay.
//
// ZERO-KNOWLEDGE INVARIANT: this package copies opaque messages between two
// peers and MUST NOT import any cryptographic or key-management package, MUST
// NOT import the concrete websocket transport, and MUST NOT parse or inspect
// message contents. It forwards bytes verbatim. The invariant is enforced by
// construction in deps_test.go, which fails the build if the dependency graph
// of this package ever contains "crypto" or the websocket library.
//
// Because the pump talks to peers only through the minimal Peer interface, it
// is structurally incapable of terminating the end-to-end encryption that the
// phone and Mac perform between themselves.
package session

import (
	"context"
	"time"
)

// Message is a single websocket message forwarded verbatim between peers.
//
// Type mirrors the underlying websocket message kind (text vs binary) so the
// frame is delivered bit-for-bit; the pump never interprets it, it only carries
// it across. Data is the raw payload — opaque ciphertext, as far as the relay
// is concerned.
type Message struct {
	Type int
	Data []byte
}

// Peer is one end of a spliced connection. Implementations wrap a transport
// (a websocket, in production) but expose only opaque message I/O to this
// package. Closing the transport is the caller's responsibility — the pump
// never owns or closes a Peer, keeping this package free of transport concerns.
type Peer interface {
	// Read returns the next message, blocking until one arrives, ctx is
	// cancelled, or the transport fails.
	Read(ctx context.Context) (Message, error)
	// Write sends a message, preserving its Type.
	Write(ctx context.Context, msg Message) error
}

// Config tunes the pump.
type Config struct {
	// WriteTimeout bounds a single Write to a peer. A peer that stops reading
	// stalls the write behind TCP backpressure; once this elapses the write
	// fails and the whole session is torn down, rather than buffering without
	// bound. A non-positive value disables the per-write deadline.
	WriteTimeout time.Duration
}

// Splice runs a blind, bidirectional copy between a and b until either
// direction ends (peer close, read/write error, or ctx cancellation), then
// tears both directions down and returns the first error observed.
//
// It spawns exactly two goroutines — one per direction — and forwards every
// message verbatim. Exactly one message is ever in flight per direction, so no
// unbounded buffering can occur.
func Splice(ctx context.Context, a, b Peer, cfg Config) error {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	errc := make(chan error, 2)
	go func() { errc <- copyMessages(ctx, a, b, cfg.WriteTimeout) }()
	go func() { errc <- copyMessages(ctx, b, a, cfg.WriteTimeout) }()

	// The first direction to return decides the session is over. Cancel so the
	// other direction unblocks, then drain it before returning.
	first := <-errc
	cancel()
	<-errc
	return first
}

// copyMessages forwards messages from src to dst one at a time. It reads a
// single opaque message and writes it to dst under a write deadline. It never
// inspects Message.Data.
func copyMessages(ctx context.Context, src, dst Peer, writeTimeout time.Duration) error {
	for {
		msg, err := src.Read(ctx)
		if err != nil {
			return err
		}
		if err := writeMessage(ctx, dst, msg, writeTimeout); err != nil {
			return err
		}
	}
}

// writeMessage writes one message to dst, bounding the write by writeTimeout so
// a slow or stalled consumer cannot wedge the pump.
func writeMessage(ctx context.Context, dst Peer, msg Message, writeTimeout time.Duration) error {
	if writeTimeout > 0 {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, writeTimeout)
		defer cancel()
	}
	return dst.Write(ctx, msg)
}
