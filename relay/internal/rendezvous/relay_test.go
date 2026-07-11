package rendezvous_test

import (
	"bytes"
	"context"
	"io"
	"log/slog"
	mrand "math/rand/v2"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/innoedge/pocketmac-relay/internal/ratelimit"
	"github.com/innoedge/pocketmac-relay/internal/rendezvous"
)

// testConfig returns a relay config tuned for fast, non-flaky tests: comfortable
// rendezvous/hello windows for the matching tests, keepalive pings off, and the
// per-IP limiter disabled (every test client is 127.0.0.1).
func testConfig() rendezvous.Config {
	cfg := rendezvous.DefaultConfig()
	cfg.HelloTimeout = 2 * time.Second
	cfg.RendezvousTimeout = 2 * time.Second
	cfg.WriteTimeout = 1 * time.Second
	cfg.PingInterval = 0 // disable active pings in tests
	cfg.RateLimit = ratelimit.Config{Burst: 0}
	cfg.Logger = slog.New(slog.NewTextHandler(io.Discard, nil))
	return cfg
}

func startRelay(t *testing.T, cfg rendezvous.Config) string {
	t.Helper()
	srv := httptest.NewServer(rendezvous.New(cfg).Handler())
	t.Cleanup(srv.Close)
	return "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws"
}

// pairID builds a valid 32-hex-char (128-bit) token from a 2-hex-char seed.
func pairID(seed string) string { return strings.Repeat(seed, 16) }

func dial(t *testing.T, wsURL string) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	c, _, err := websocket.Dial(ctx, wsURL, &websocket.DialOptions{
		CompressionMode: websocket.CompressionDisabled,
	})
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	c.SetReadLimit(1 << 20) // accept large test payloads
	return c
}

func hello(t *testing.T, c *websocket.Conn, id string) {
	t.Helper()
	writeMsg(t, c, websocket.MessageText, []byte(id))
}

func writeMsg(t *testing.T, c *websocket.Conn, typ websocket.MessageType, data []byte) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := c.Write(ctx, typ, data); err != nil {
		t.Fatalf("write: %v", err)
	}
}

func readMsg(t *testing.T, c *websocket.Conn) (websocket.MessageType, []byte) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	typ, data, err := c.Read(ctx)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	return typ, data
}

func assertClosed(t *testing.T, err error, want websocket.StatusCode) {
	t.Helper()
	if err == nil {
		t.Fatal("expected connection to be closed, got nil error")
	}
	if got := websocket.CloseStatus(err); got != want {
		t.Fatalf("close status = %v, want %v (err=%v)", got, want, err)
	}
}

func randomBytes(n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(mrand.IntN(256))
	}
	return b
}

// TestRelay_BlindForward_BytesIdentical proves the relay forwards opaque bytes
// verbatim in both directions, including blobs that are NOT valid protocol
// frames (invalid UTF-8, empty messages, and bytes that merely look like a
// HELLO). All are sent as binary frames and must arrive byte-identical.
func TestRelay_BlindForward_BytesIdentical(t *testing.T) {
	wsURL := startRelay(t, testConfig())
	id := pairID("a1")

	a := dial(t, wsURL)
	defer a.CloseNow()
	b := dial(t, wsURL)
	defer b.CloseNow()
	hello(t, a, id)
	hello(t, b, id)

	blobs := [][]byte{
		{},                             // empty message
		{0x00},                         // single NUL
		{0xff, 0xfe, 0xfd, 0x00, 0x7f}, // arbitrary bytes
		{0xc0, 0xc1, 0xf5, 0xff},       // invalid UTF-8 sequence
		[]byte("HELLO" + strings.Repeat("0", 32)), // looks protocol-ish, forwarded anyway
		bytes.Repeat([]byte{0xAB}, 40000),         // large-ish payload
		randomBytes(1234),                         // random blob
		randomBytes(63 * 1024),                    // just under the 64 KiB cap
	}

	// A -> B
	for i, want := range blobs {
		writeMsg(t, a, websocket.MessageBinary, want)
		typ, got := readMsg(t, b)
		if typ != websocket.MessageBinary {
			t.Fatalf("A->B blob %d: type = %v, want binary (type not preserved)", i, typ)
		}
		if !bytes.Equal(got, want) {
			t.Fatalf("A->B blob %d: bytes differ (len got=%d want=%d)", i, len(got), len(want))
		}
	}

	// B -> A
	for i, want := range blobs {
		writeMsg(t, b, websocket.MessageBinary, want)
		typ, got := readMsg(t, a)
		if typ != websocket.MessageBinary {
			t.Fatalf("B->A blob %d: type = %v, want binary (type not preserved)", i, typ)
		}
		if !bytes.Equal(got, want) {
			t.Fatalf("B->A blob %d: bytes differ (len got=%d want=%d)", i, len(got), len(want))
		}
	}

	// A text frame must arrive as a text frame (type fidelity both ways).
	writeMsg(t, a, websocket.MessageText, []byte("plain text"))
	if typ, got := readMsg(t, b); typ != websocket.MessageText || string(got) != "plain text" {
		t.Fatalf("text frame not preserved: type=%v data=%q", typ, got)
	}
}

// TestRelay_MismatchedPairingIDs_DoNotCross ensures two peers with different
// tokens are never spliced: neither receives the other's bytes, and each hits
// the rendezvous timeout.
func TestRelay_MismatchedPairingIDs_DoNotCross(t *testing.T) {
	cfg := testConfig()
	cfg.RendezvousTimeout = 200 * time.Millisecond
	wsURL := startRelay(t, cfg)

	a := dial(t, wsURL)
	defer a.CloseNow()
	b := dial(t, wsURL)
	defer b.CloseNow()
	hello(t, a, pairID("a1"))
	hello(t, b, pairID("b2"))

	// A emits a blob. With no partner it must never reach B.
	writeMsg(t, a, websocket.MessageBinary, []byte("secret-from-A"))

	// B must not receive A's blob; it must be closed on rendezvous timeout.
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if typ, data, err := b.Read(ctx); err == nil {
		t.Fatalf("B received data across mismatched ids: type=%v data=%q", typ, data)
	} else {
		assertClosed(t, err, websocket.StatusPolicyViolation)
	}

	// A likewise times out.
	ctx2, cancel2 := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel2()
	_, _, err := a.Read(ctx2)
	assertClosed(t, err, websocket.StatusPolicyViolation)
}

// TestRelay_ThirdConnection_Rejected verifies a third socket on an
// already-matched id is refused, and that the live session is undisturbed.
func TestRelay_ThirdConnection_Rejected(t *testing.T) {
	wsURL := startRelay(t, testConfig())
	id := pairID("cc")

	a := dial(t, wsURL)
	defer a.CloseNow()
	b := dial(t, wsURL)
	defer b.CloseNow()
	hello(t, a, id)
	hello(t, b, id)

	// Confirm the pair is actually spliced with a round trip.
	writeMsg(t, a, websocket.MessageBinary, []byte("ping"))
	if _, got := readMsg(t, b); string(got) != "ping" {
		t.Fatalf("session not established, got %q", got)
	}

	// Third connection on the same id is rejected.
	c := dial(t, wsURL)
	defer c.CloseNow()
	hello(t, c, id)

	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_, _, err := c.Read(ctx)
	assertClosed(t, err, websocket.StatusPolicyViolation)

	// The original A<->B session still works.
	writeMsg(t, b, websocket.MessageBinary, []byte("pong"))
	if _, got := readMsg(t, a); string(got) != "pong" {
		t.Fatalf("A<->B disturbed after third rejected, got %q", got)
	}
}

// TestRelay_PeerTimeout checks that a lone connection with no partner is closed
// after the (short, injected) rendezvous deadline.
func TestRelay_PeerTimeout(t *testing.T) {
	cfg := testConfig()
	cfg.RendezvousTimeout = 150 * time.Millisecond
	wsURL := startRelay(t, cfg)

	a := dial(t, wsURL)
	defer a.CloseNow()
	hello(t, a, pairID("d0"))

	start := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_, _, err := a.Read(ctx)
	elapsed := time.Since(start)

	assertClosed(t, err, websocket.StatusPolicyViolation)
	if elapsed < 100*time.Millisecond {
		t.Fatalf("closed too early (%v): deadline was not respected", elapsed)
	}
	if elapsed > 1500*time.Millisecond {
		t.Fatalf("closed too late (%v)", elapsed)
	}
}

// TestRelay_SlowConsumer_Dropped verifies that a peer which stops reading past
// the write deadline causes the session to be torn down, rather than the relay
// buffering without bound. The still-writing peer observes its own connection
// fail within a bounded time.
func TestRelay_SlowConsumer_Dropped(t *testing.T) {
	cfg := testConfig()
	cfg.WriteTimeout = 150 * time.Millisecond
	wsURL := startRelay(t, cfg)

	a := dial(t, wsURL)
	defer a.CloseNow()
	b := dial(t, wsURL)
	defer b.CloseNow()
	hello(t, a, pairID("50"))
	hello(t, b, pairID("50"))

	// Establish the splice.
	writeMsg(t, a, websocket.MessageBinary, []byte("go"))
	if _, got := readMsg(t, b); string(got) != "go" {
		t.Fatalf("session not established, got %q", got)
	}

	// B stops reading entirely; A floods. The relay's write to B stalls past
	// WriteTimeout, tears the session down, and A then sees a write failure.
	payload := bytes.Repeat([]byte{0xAB}, 60000)
	deadline := time.Now().Add(5 * time.Second)
	var writeErr error
	for time.Now().Before(deadline) {
		ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
		writeErr = a.Write(ctx, websocket.MessageBinary, payload)
		cancel()
		if writeErr != nil {
			break
		}
	}
	if writeErr == nil {
		t.Fatal("slow-consumer session was not torn down: relay kept accepting writes")
	}
}

// TestRelay_Healthz checks the uptime endpoint.
func TestRelay_Healthz(t *testing.T) {
	srv := httptest.NewServer(rendezvous.New(testConfig()).Handler())
	t.Cleanup(srv.Close)

	resp, err := http.Get(srv.URL + "/healthz")
	if err != nil {
		t.Fatalf("GET /healthz: %v", err)
	}
	defer func() { _ = resp.Body.Close() }()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	body, _ := io.ReadAll(resp.Body)
	if !strings.Contains(string(body), "ok") {
		t.Fatalf("body = %q, want it to contain \"ok\"", body)
	}
}
