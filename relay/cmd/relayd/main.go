// Command relayd is the Pocket Mac zero-knowledge rendezvous relay.
//
// It is a blind WSS byte-pump: two peers each open an outbound websocket, send
// a cleartext HELLO pairing token, and are spliced into a bidirectional copy of
// opaque bytes. The relay never terminates the end-to-end encryption between the
// peers — it only matches tokens and forwards ciphertext.
//
// TLS is optional: in production, terminate TLS at a reverse proxy (Caddy) and
// run this behind it on plain HTTP. For direct exposure, pass -cert and -key.
package main

import (
	"context"
	"errors"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/innoedge/pocketmac-relay/internal/rendezvous"
)

func main() {
	var (
		addr         = flag.String("addr", ":8080", "listen address")
		certFile     = flag.String("cert", "", "TLS certificate file (enables TLS when set with -key)")
		keyFile      = flag.String("key", "", "TLS private key file")
		helloTO      = flag.Duration("hello-timeout", 10*time.Second, "deadline to receive the HELLO frame")
		rendezvousTO = flag.Duration("rendezvous-timeout", 30*time.Second, "how long a lone peer waits for its partner")
		writeTO      = flag.Duration("write-timeout", 10*time.Second, "per-message write deadline to a peer")
		pingInterval = flag.Duration("ping-interval", 45*time.Second, "keepalive ping interval (0 disables)")
		pingTO       = flag.Duration("ping-timeout", 10*time.Second, "deadline to receive a pong")
		maxMsg       = flag.Int64("max-message-bytes", 64<<10, "maximum websocket message size in bytes")
		rlBurst      = flag.Int("ratelimit-burst", 60, "per-IP connection burst (0 disables limiting)")
		rlRate       = flag.Float64("ratelimit-rate", 1, "per-IP connection refill rate per second")
		trustXFF     = flag.Bool("trust-forwarded-for", false, "key rate limiting on X-Forwarded-For (enable ONLY behind a trusted proxy)")
	)
	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}))

	cfg := rendezvous.DefaultConfig()
	cfg.HelloTimeout = *helloTO
	cfg.RendezvousTimeout = *rendezvousTO
	cfg.WriteTimeout = *writeTO
	cfg.PingInterval = *pingInterval
	cfg.PingTimeout = *pingTO
	cfg.MaxMessageBytes = *maxMsg
	cfg.RateLimit.Burst = *rlBurst
	cfg.RateLimit.Rate = *rlRate
	cfg.TrustForwardedFor = *trustXFF
	cfg.Logger = logger

	srv := &http.Server{
		Addr:              *addr,
		Handler:           rendezvous.New(cfg).Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	// Graceful shutdown on SIGINT/SIGTERM.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdownCtx)
	}()

	useTLS := *certFile != "" && *keyFile != ""
	logger.Info("relay starting", "addr", *addr, "tls", useTLS)

	var err error
	if useTLS {
		err = srv.ListenAndServeTLS(*certFile, *keyFile)
	} else {
		err = srv.ListenAndServe()
	}
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		logger.Error("server stopped", "err", err)
		os.Exit(1)
	}
	logger.Info("relay stopped")
}
