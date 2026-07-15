// Package ratelimit provides a small, dependency-free per-client-IP token-bucket
// rate limiter for fronting unauthenticated HTTP endpoints. It is process-local
// (no shared state across replicas) and best-effort: it bounds abuse from a
// single source without pretending to be a distributed quota system.
package ratelimit

import (
	"net"
	"net/http"
	"sync"
	"time"
)

type bucket struct {
	tokens float64
	last   time.Time
}

// Limiter hands out tokens per key (client IP) at a steady rate up to a burst.
type Limiter struct {
	mu       sync.Mutex
	visitors map[string]*bucket
	rate     float64 // tokens added per second
	burst    float64 // maximum tokens held
	ttl      time.Duration
	now      func() time.Time // injectable for tests
}

// New returns a limiter allowing ratePerSec sustained requests per key with the
// given burst.
func New(ratePerSec, burst float64) *Limiter {
	return &Limiter{
		visitors: make(map[string]*bucket),
		rate:     ratePerSec,
		burst:    burst,
		ttl:      10 * time.Minute,
		now:      time.Now,
	}
}

// Allow reports whether a request from key may proceed, consuming a token.
func (l *Limiter) Allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	now := l.now()
	b, ok := l.visitors[key]
	if !ok {
		b = &bucket{tokens: l.burst, last: now}
		l.visitors[key] = b
	} else {
		b.tokens = min(l.burst, b.tokens+now.Sub(b.last).Seconds()*l.rate)
		b.last = now
	}

	// Opportunistically evict idle visitors so the map cannot grow without
	// bound under a churn of distinct source IPs.
	if len(l.visitors) > 4096 {
		for k, v := range l.visitors {
			if now.Sub(v.last) > l.ttl {
				delete(l.visitors, k)
			}
		}
	}

	if b.tokens >= 1 {
		b.tokens--
		return true
	}
	return false
}

// Middleware wraps h and rejects requests that exceed the per-IP rate with 429.
func (l *Limiter) Middleware(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ip, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			ip = r.RemoteAddr
		}
		if !l.Allow(ip) {
			w.Header().Set("Retry-After", "1")
			http.Error(w, "Too Many Requests", http.StatusTooManyRequests)
			return
		}
		h.ServeHTTP(w, r)
	})
}
