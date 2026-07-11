// Package ratelimit provides a small per-IP token-bucket connection limiter.
// It is a lightweight guard against a single source opening connections in a
// tight loop; it is not a substitute for edge/CDN rate limiting.
package ratelimit

import (
	"sync"
	"time"
)

// Config configures the per-IP limiter.
type Config struct {
	// Burst is the maximum number of connections allowed back-to-back from one
	// IP. Burst <= 0 disables limiting entirely (every call is allowed).
	Burst int
	// Rate is the steady-state refill in tokens (connections) per second.
	Rate float64
}

// Limiter is a per-IP token-bucket connection limiter. Construct it with New;
// the zero value is not usable. All methods are safe for concurrent use.
type Limiter struct {
	burst float64
	rate  float64
	now   func() time.Time // injectable for tests

	mu      sync.Mutex
	buckets map[string]*bucket
	lastGC  time.Time
}

type bucket struct {
	tokens float64
	last   time.Time
}

// New returns a Limiter for the given config.
func New(cfg Config) *Limiter {
	return &Limiter{
		burst:   float64(cfg.Burst),
		rate:    cfg.Rate,
		now:     time.Now,
		buckets: make(map[string]*bucket),
	}
}

// Allow reports whether a new connection from ip may proceed, consuming one
// token if so. When limiting is disabled (Burst <= 0) it always returns true.
func (l *Limiter) Allow(ip string) bool {
	if l.burst <= 0 {
		return true
	}

	now := l.now()
	l.mu.Lock()
	defer l.mu.Unlock()

	l.gc(now)

	b := l.buckets[ip]
	if b == nil {
		// New source starts with a full bucket, then spends one token.
		l.buckets[ip] = &bucket{tokens: l.burst - 1, last: now}
		return true
	}

	b.tokens += now.Sub(b.last).Seconds() * l.rate
	if b.tokens > l.burst {
		b.tokens = l.burst
	}
	b.last = now

	if b.tokens < 1 {
		return false
	}
	b.tokens--
	return true
}

// gc periodically drops idle, refilled buckets so the map cannot grow without
// bound under churn from many distinct IPs. The caller must hold l.mu.
func (l *Limiter) gc(now time.Time) {
	const (
		interval = 5 * time.Minute
		idleTTL  = 10 * time.Minute
	)
	if now.Sub(l.lastGC) < interval {
		return
	}
	l.lastGC = now
	for ip, b := range l.buckets {
		if now.Sub(b.last) > idleTTL {
			delete(l.buckets, ip)
		}
	}
}
