package ratelimit

import (
	"testing"
	"time"
)

func TestLimiter_DisabledAllowsEverything(t *testing.T) {
	l := New(Config{Burst: 0})
	for i := 0; i < 1000; i++ {
		if !l.Allow("10.0.0.1") {
			t.Fatalf("disabled limiter denied call %d", i)
		}
	}
}

func TestLimiter_BurstThenDeny(t *testing.T) {
	now := time.Unix(0, 0)
	l := New(Config{Burst: 3, Rate: 1})
	l.now = func() time.Time { return now }

	// Burst of 3 succeeds.
	for i := 0; i < 3; i++ {
		if !l.Allow("1.2.3.4") {
			t.Fatalf("burst call %d denied", i)
		}
	}
	// 4th is denied — bucket empty.
	if l.Allow("1.2.3.4") {
		t.Fatal("expected 4th call to be denied")
	}
	// A different IP is unaffected.
	if !l.Allow("5.6.7.8") {
		t.Fatal("independent IP should be allowed")
	}
}

func TestLimiter_RefillsOverTime(t *testing.T) {
	now := time.Unix(0, 0)
	l := New(Config{Burst: 1, Rate: 2}) // 2 tokens/sec
	l.now = func() time.Time { return now }

	if !l.Allow("9.9.9.9") {
		t.Fatal("first call should pass")
	}
	if l.Allow("9.9.9.9") {
		t.Fatal("second call should be denied immediately")
	}

	// After 500ms, 2 tokens/sec refills exactly 1 token.
	now = now.Add(500 * time.Millisecond)
	if !l.Allow("9.9.9.9") {
		t.Fatal("call after refill should pass")
	}
}
