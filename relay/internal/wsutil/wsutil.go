// Package wsutil adapts a coder/websocket connection to the transport-agnostic
// session.Peer interface and applies the per-connection safety guards
// (message-size cap, keepalive ping, explicit close codes).
//
// This package — not the session pump — is where the websocket library and its
// transitive crypto dependencies live. Keeping the adapter here is what lets
// the session package stay provably crypto-free.
package wsutil

import (
	"context"
	"net/http"
	"time"

	"github.com/coder/websocket"

	"github.com/innoedge/pocketmac-relay/internal/session"
)

// Config controls websocket acceptance and per-connection guards.
type Config struct {
	// MaxMessageBytes caps a single inbound message. Exceeding it fails the
	// read and closes the connection with StatusMessageTooBig — the payload is
	// dropped, never buffered.
	MaxMessageBytes int64
}

// Conn adapts a *websocket.Conn to session.Peer. It exposes only opaque message
// I/O plus transport-level control (ping, close). The session pump depends on
// session.Peer, never on this concrete type or on the websocket package.
type Conn struct {
	c *websocket.Conn
}

// Accept upgrades an HTTP request to a websocket connection and applies the
// message-size cap.
//
// Compression is disabled deliberately: payloads are end-to-end encrypted
// opaque bytes, so per-message deflate yields nothing and only adds attack
// surface (and CRIME-class side channels).
func Accept(w http.ResponseWriter, r *http.Request, cfg Config) (*Conn, error) {
	c, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		return nil, err
	}
	c.SetReadLimit(cfg.MaxMessageBytes)
	return &Conn{c: c}, nil
}

// Read returns the next opaque message. It blocks until a message arrives, ctx
// is cancelled, or the connection fails.
func (c *Conn) Read(ctx context.Context) (session.Message, error) {
	typ, data, err := c.c.Read(ctx)
	if err != nil {
		return session.Message{}, err
	}
	return session.Message{Type: int(typ), Data: data}, nil
}

// Write sends an opaque message, preserving its original text/binary type so
// the encrypted payload is delivered bit-for-bit.
func (c *Conn) Write(ctx context.Context, msg session.Message) error {
	return c.c.Write(ctx, websocket.MessageType(msg.Type), msg.Data)
}

// Keepalive pings the peer every interval until ctx is cancelled or a ping goes
// unanswered within pingTimeout, returning the resulting error. It must run
// concurrently with a reader on this connection (the pump provides one) so that
// pongs are read. A non-positive interval disables active pings and simply
// blocks until ctx is done.
func (c *Conn) Keepalive(ctx context.Context, interval, pingTimeout time.Duration) error {
	if interval <= 0 {
		<-ctx.Done()
		return ctx.Err()
	}
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-t.C:
			pctx, cancel := context.WithTimeout(ctx, pingTimeout)
			err := c.c.Ping(pctx)
			cancel()
			if err != nil {
				return err
			}
		}
	}
}

// Close sends a normal closure. It is safe to call from a defer as a safety
// net: a second close after the connection already failed, or after an explicit
// CloseWith, is harmless.
func (c *Conn) Close() error {
	return c.c.Close(websocket.StatusNormalClosure, "")
}

// CloseWith closes the connection with a specific status and reason, used to
// signal rejections (invalid hello, rendezvous timeout, pairing already
// active). Only the first close frame reaches the peer; later closes are no-ops.
func (c *Conn) CloseWith(code websocket.StatusCode, reason string) error {
	return c.c.Close(code, reason)
}
