// Package rendezvous is the relay's orchestrator: it accepts websocket
// connections, reads the cleartext HELLO pairing token, matches the two peers
// that share a token, and hands the matched pair to the blind session pump.
//
// The relay is deliberately dumb. The only cleartext it ever sees is the
// rendezvous token (a random 128-bit id, not a key). Everything after HELLO is
// forwarded verbatim by package session, which cannot inspect it.
//
// # HELLO protocol
//
// The first websocket message on each connection is the pairing token: a
// lowercase hex string encoding 16–64 random bytes (128–512 bits). It may be
// sent as a text or binary frame; only the bytes matter. It is read under a
// short deadline as a slowloris guard. Every subsequent frame is opaque and is
// spliced to the peer untouched.
//
// An id admits exactly two connections: the first waits, the second matches and
// drives the session, and a third is rejected. A lone waiter is closed after
// RendezvousTimeout.
package rendezvous

import (
	"context"
	"encoding/hex"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/coder/websocket"

	"github.com/innoedge/pocketmac-relay/internal/ratelimit"
	"github.com/innoedge/pocketmac-relay/internal/session"
	"github.com/innoedge/pocketmac-relay/internal/wsutil"
)

// Config tunes the relay. Timeouts are injectable so tests run in milliseconds.
type Config struct {
	// MaxMessageBytes caps a single websocket message (default 64 KiB).
	MaxMessageBytes int64
	// HelloTimeout bounds how long a connection has to send its HELLO frame.
	HelloTimeout time.Duration
	// RendezvousTimeout bounds how long a lone peer waits for its partner.
	RendezvousTimeout time.Duration
	// WriteTimeout bounds a single forwarded write to a peer.
	WriteTimeout time.Duration
	// PingInterval is the keepalive ping period once a session is live. Zero
	// disables active pings.
	PingInterval time.Duration
	// PingTimeout bounds how long to wait for a pong before tearing down.
	PingTimeout time.Duration
	// MinPairingIDBytes / MaxPairingIDBytes bound the decoded token length.
	MinPairingIDBytes int
	MaxPairingIDBytes int
	// RateLimit configures the per-IP connection limiter.
	RateLimit ratelimit.Config
	// TrustForwardedFor makes the limiter key on the left-most X-Forwarded-For
	// entry instead of the socket peer. Enable ONLY behind a trusted reverse
	// proxy (e.g. Caddy) that sets the header; otherwise it is client-spoofable.
	TrustForwardedFor bool
	// Logger receives operational logs. Never logs the pairing token or payload.
	Logger *slog.Logger
}

// DefaultConfig returns production-sane defaults.
func DefaultConfig() Config {
	return Config{
		MaxMessageBytes:   64 << 10, // 64 KiB
		HelloTimeout:      10 * time.Second,
		RendezvousTimeout: 30 * time.Second,
		WriteTimeout:      10 * time.Second,
		PingInterval:      45 * time.Second,
		PingTimeout:       10 * time.Second,
		MinPairingIDBytes: 16, // 128-bit rendezvous token
		MaxPairingIDBytes: 64, // up to 512-bit
		RateLimit:         ratelimit.Config{Burst: 60, Rate: 1},
		Logger:            slog.Default(),
	}
}

// Relay is the single stateful object in the process. All shared state (the
// pending-connection map) lives behind r.mu.
type Relay struct {
	cfg     Config
	log     *slog.Logger
	limiter *ratelimit.Limiter

	mu    sync.Mutex
	slots map[string]*slot
}

type slotState int

const (
	slotWaiting slotState = iota // one peer is registered, awaiting a partner
	slotActive                   // two peers matched, session in progress
)

// slot is the rendezvous entry for one pairing id.
type slot struct {
	state slotState
	peer  *wsutil.Conn        // the waiting (first) connection, valid while slotWaiting
	match chan *sessionHandle // buffered(1); the first waiter receives its handle here
}

// sessionHandle lets the matched-second connection signal the first (parked)
// connection that the session has ended and it may close.
type sessionHandle struct {
	done chan struct{}
}

// New builds a Relay from cfg.
func New(cfg Config) *Relay {
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	return &Relay{
		cfg:     cfg,
		log:     cfg.Logger,
		limiter: ratelimit.New(cfg.RateLimit),
		slots:   make(map[string]*slot),
	}
}

// Handler returns the relay's HTTP handler: /ws for the websocket rendezvous
// and /healthz for uptime checks.
func (r *Relay) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", r.handleHealthz)
	mux.HandleFunc("/ws", r.handleWS)
	return mux
}

func (r *Relay) handleHealthz(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok\n"))
}

func (r *Relay) handleWS(w http.ResponseWriter, req *http.Request) {
	if !r.limiter.Allow(r.clientIP(req)) {
		http.Error(w, "too many connections", http.StatusTooManyRequests)
		return
	}

	conn, err := wsutil.Accept(w, req, wsutil.Config{MaxMessageBytes: r.cfg.MaxMessageBytes})
	if err != nil {
		return // Accept already responded to the HTTP client.
	}
	// Safety net: guarantee the socket is closed on every return path. Explicit
	// CloseWith calls set a specific status first, making this a no-op.
	defer func() { _ = conn.Close() }()

	id, err := r.readHello(req.Context(), conn)
	if err != nil {
		_ = conn.CloseWith(websocket.StatusPolicyViolation, "invalid hello")
		return
	}

	r.rendezvous(req.Context(), id, conn)
}

var errInvalidHello = errors.New("invalid hello frame")

// readHello reads and validates the first message: the hex pairing token. The
// token is a random rendezvous identifier, not a key — the relay uses it only
// to match two peers, and never logs it.
func (r *Relay) readHello(ctx context.Context, conn *wsutil.Conn) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, r.cfg.HelloTimeout)
	defer cancel()

	msg, err := conn.Read(ctx)
	if err != nil {
		return "", err
	}

	id := strings.ToLower(strings.TrimSpace(string(msg.Data)))
	raw, err := hex.DecodeString(id)
	if err != nil {
		return "", errInvalidHello
	}
	if len(raw) < r.cfg.MinPairingIDBytes || len(raw) > r.cfg.MaxPairingIDBytes {
		return "", errInvalidHello
	}
	return id, nil
}

// rendezvous registers conn under id and splices it with the second peer that
// presents the same id.
func (r *Relay) rendezvous(ctx context.Context, id string, conn *wsutil.Conn) {
	r.mu.Lock()
	s, ok := r.slots[id]
	switch {
	case !ok:
		// First arrival: register and wait for a partner.
		s = &slot{
			state: slotWaiting,
			peer:  conn,
			match: make(chan *sessionHandle, 1),
		}
		r.slots[id] = s
		r.mu.Unlock()
		r.waitForPartner(ctx, id, s, conn)

	case s.state == slotWaiting:
		// Second arrival: claim the waiter and drive the session.
		partner := s.peer
		s.state = slotActive
		s.peer = nil
		r.mu.Unlock()

		handle := &sessionHandle{done: make(chan struct{})}
		s.match <- handle // buffered send; the first waiter will receive it

		r.runSession(ctx, partner, conn)
		close(handle.done) // release the parked first waiter
		r.removeSlot(id, s)

	default: // slotActive
		// Third arrival on an already-matched id.
		r.mu.Unlock()
		r.log.Warn("third connection rejected: pairing already active")
		_ = conn.CloseWith(websocket.StatusPolicyViolation, "pairing already active")
	}
}

// waitForPartner blocks the first arrival until it is matched, times out, or
// its own connection drops. On a match it parks until the session (driven by
// the second arrival) ends, so its deferred Close does not fire early.
func (r *Relay) waitForPartner(ctx context.Context, id string, s *slot, conn *wsutil.Conn) {
	timer := time.NewTimer(r.cfg.RendezvousTimeout)
	defer timer.Stop()

	select {
	case handle := <-s.match:
		<-handle.done

	case <-timer.C:
		if r.claimUnmatched(id, s) {
			r.log.Info("rendezvous timed out waiting for partner")
			_ = conn.CloseWith(websocket.StatusPolicyViolation, "rendezvous timeout")
			return
		}
		// Raced with a simultaneous match; the handle is buffered. Park on it.
		<-(<-s.match).done

	case <-ctx.Done():
		if r.claimUnmatched(id, s) {
			return
		}
		<-(<-s.match).done
	}
}

// claimUnmatched removes s from the map iff it is still the waiting slot for id.
// It resolves the race between rendezvous timeout / context cancellation and a
// simultaneous second arrival (compare-and-swap on the slot pointer + state).
// It returns true if we removed a still-waiting slot (genuinely no partner),
// false if the slot was already matched (a handle is waiting to be received).
func (r *Relay) claimUnmatched(id string, s *slot) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	if cur, ok := r.slots[id]; ok && cur == s && cur.state == slotWaiting {
		delete(r.slots, id)
		return true
	}
	return false
}

// removeSlot deletes the (active) slot for id once its session has ended.
func (r *Relay) removeSlot(id string, s *slot) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if cur, ok := r.slots[id]; ok && cur == s {
		delete(r.slots, id)
	}
}

// runSession keepalive-pings both peers and runs the blind pump until either
// side drops or a ping goes unanswered. It blocks until the session is fully
// torn down and both keepalive goroutines have exited.
func (r *Relay) runSession(ctx context.Context, a, b *wsutil.Conn) {
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()

	var wg sync.WaitGroup
	wg.Add(2)
	// A failed ping cancels ctx, tearing the whole session down.
	go func() {
		defer wg.Done()
		defer cancel()
		_ = a.Keepalive(ctx, r.cfg.PingInterval, r.cfg.PingTimeout)
	}()
	go func() {
		defer wg.Done()
		defer cancel()
		_ = b.Keepalive(ctx, r.cfg.PingInterval, r.cfg.PingTimeout)
	}()

	err := session.Splice(ctx, a, b, session.Config{WriteTimeout: r.cfg.WriteTimeout})
	cancel()  // stop the keepalives
	wg.Wait() // and make sure they are gone before we return

	if err != nil {
		r.log.Debug("session ended", "reason", err.Error())
	}
}

// clientIP resolves the source IP used for rate limiting.
func (r *Relay) clientIP(req *http.Request) string {
	if r.cfg.TrustForwardedFor {
		if xff := req.Header.Get("X-Forwarded-For"); xff != "" {
			if i := strings.IndexByte(xff, ','); i >= 0 {
				return strings.TrimSpace(xff[:i])
			}
			return strings.TrimSpace(xff)
		}
	}
	if host, _, err := net.SplitHostPort(req.RemoteAddr); err == nil {
		return host
	}
	return req.RemoteAddr
}
