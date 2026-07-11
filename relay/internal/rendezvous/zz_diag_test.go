package rendezvous_test

import (
	"bytes"
	"context"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/innoedge/pocketmac-relay/internal/ratelimit"
	"github.com/innoedge/pocketmac-relay/internal/rendezvous"
)

func TestDiagSlow(t *testing.T) {
	cfg := rendezvous.DefaultConfig()
	cfg.HelloTimeout = 2 * time.Second
	cfg.RendezvousTimeout = 2 * time.Second
	cfg.WriteTimeout = 150 * time.Millisecond
	cfg.PingInterval = 0
	cfg.RateLimit = ratelimit.Config{Burst: 0}
	cfg.Logger = slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelDebug}))
	wsURL := startRelay(t, cfg)

	a := dial(t, wsURL)
	defer a.CloseNow()
	b := dial(t, wsURL)
	defer b.CloseNow()
	hello(t, a, pairID("50"))
	hello(t, b, pairID("50"))

	writeMsg(t, a, websocket.MessageBinary, []byte("go"))
	if _, got := readMsg(t, b); string(got) != "go" {
		t.Fatalf("not established: %q", got)
	}

	payload := bytes.Repeat([]byte{0xAB}, 60000)
	deadline := time.Now().Add(5 * time.Second)
	n := 0
	start := time.Now()
	var writeErr error
	for time.Now().Before(deadline) {
		ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
		writeErr = a.Write(ctx, websocket.MessageBinary, payload)
		cancel()
		if writeErr != nil {
			break
		}
		n++
	}
	t.Logf("writes completed=%d bytes=%d elapsed=%v err=%v", n, n*len(payload), time.Since(start), writeErr)
	_ = strings.TrimSpace
}
