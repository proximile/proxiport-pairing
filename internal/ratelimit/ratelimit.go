// Package ratelimit provides a small, dependency-free per-client-IP token-bucket
// rate limiter for fronting unauthenticated HTTP endpoints. It is process-local
// (no shared state across replicas) and best-effort: it bounds abuse from a
// single source without pretending to be a distributed quota system.
package ratelimit

import (
	"container/list"
	"fmt"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// maxVisitors is the hard cap on tracked client buckets. When it is exceeded the
// least-recently-seen bucket is evicted immediately — regardless of idle age —
// so the map cannot grow without bound under a churn of distinct source IPs.
const maxVisitors = 4096

type bucket struct {
	key    string
	tokens float64
	last   time.Time
}

// Limiter hands out tokens per key (client IP) at a steady rate up to a burst.
// Buckets are held in an LRU ordered by last-seen time: the set is hard-capped
// at maxVisitors, and a background timer additionally sweeps out idle buckets.
type Limiter struct {
	mu       sync.Mutex
	visitors map[string]*list.Element // key -> element holding *bucket
	order    *list.List               // front = most recently seen, back = oldest
	rate     float64                  // tokens added per second
	burst    float64                  // maximum tokens held
	ttl      time.Duration            // idle age after which a bucket may be swept
	now      func() time.Time         // injectable for tests

	// trustedProxies are CIDR ranges whose peer address is a reverse proxy we
	// trust to set X-Forwarded-For / X-Real-IP. Empty by default: the headers
	// are never consulted and the key is always the direct peer address.
	trustedProxies []*net.IPNet
}

// New returns a limiter allowing ratePerSec sustained requests per key with the
// given burst.
func New(ratePerSec, burst float64) *Limiter {
	l := &Limiter{
		visitors: make(map[string]*list.Element),
		order:    list.New(),
		rate:     ratePerSec,
		burst:    burst,
		ttl:      10 * time.Minute,
		now:      time.Now,
	}
	go l.sweeper()
	return l
}

// SetTrustedProxies configures the reverse-proxy CIDR ranges whose forwarded
// headers may be trusted. Call it during setup, before the limiter serves
// traffic; a nil or empty list disables header trust (the default).
func (l *Limiter) SetTrustedProxies(cidrs []*net.IPNet) {
	l.trustedProxies = cidrs
}

// ParseCIDRs parses trusted-proxy entries. Each entry is a CIDR (e.g.
// "10.0.0.0/8") or a bare IP address (treated as a single host). It returns an
// error on the first malformed entry.
func ParseCIDRs(entries []string) ([]*net.IPNet, error) {
	var out []*net.IPNet
	for _, e := range entries {
		e = strings.TrimSpace(e)
		if e == "" {
			continue
		}
		if !strings.Contains(e, "/") {
			ip := net.ParseIP(e)
			if ip == nil {
				return nil, fmt.Errorf("invalid trusted proxy address %q", e)
			}
			if ip.To4() != nil {
				e += "/32"
			} else {
				e += "/128"
			}
		}
		_, n, err := net.ParseCIDR(e)
		if err != nil {
			return nil, fmt.Errorf("invalid trusted proxy CIDR %q: %w", e, err)
		}
		out = append(out, n)
	}
	return out, nil
}

// Allow reports whether a request from key may proceed, consuming a token.
func (l *Limiter) Allow(key string) bool {
	l.mu.Lock()
	defer l.mu.Unlock()

	now := l.now()
	if el, ok := l.visitors[key]; ok {
		b := el.Value.(*bucket)
		b.tokens = min(l.burst, b.tokens+now.Sub(b.last).Seconds()*l.rate)
		b.last = now
		l.order.MoveToFront(el)
		return take(b)
	}

	b := &bucket{key: key, tokens: l.burst, last: now}
	l.visitors[key] = l.order.PushFront(b)

	// Hard cap: evict the least-recently-seen buckets beyond the bound,
	// regardless of idle age, so the tracked set is strictly bounded.
	for l.order.Len() > maxVisitors {
		oldest := l.order.Back()
		l.order.Remove(oldest)
		delete(l.visitors, oldest.Value.(*bucket).key)
	}

	return take(b)
}

func take(b *bucket) bool {
	if b.tokens >= 1 {
		b.tokens--
		return true
	}
	return false
}

// sweeper periodically removes buckets idle for longer than ttl. It runs on its
// own timer so idle reclamation does not depend on request volume.
func (l *Limiter) sweeper() {
	ticker := time.NewTicker(l.ttl)
	defer ticker.Stop()
	for range ticker.C {
		l.sweep()
	}
}

func (l *Limiter) sweep() {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	// The list is ordered by recency (back = oldest), so once a non-idle bucket
	// is reached every bucket toward the front is newer and also not idle.
	for el := l.order.Back(); el != nil; {
		b := el.Value.(*bucket)
		if now.Sub(b.last) <= l.ttl {
			break
		}
		prev := el.Prev()
		l.order.Remove(el)
		delete(l.visitors, b.key)
		el = prev
	}
}

// clientKey derives the rate-limit key for r. When the direct peer is one of the
// configured trusted proxies, the key is taken from the rightmost untrusted hop
// of X-Forwarded-For (falling back to X-Real-IP); otherwise — and whenever no
// trusted proxies are configured — the direct peer address is used. Forwarded
// headers are never trusted from an untrusted peer.
func (l *Limiter) clientKey(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	ip := net.ParseIP(host)
	if ip == nil || !l.isTrustedProxy(ip) {
		return host
	}
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		if key := l.rightmostUntrusted(xff); key != "" {
			return key
		}
	}
	if xrip := strings.TrimSpace(r.Header.Get("X-Real-IP")); xrip != "" {
		return xrip
	}
	return host
}

func (l *Limiter) isTrustedProxy(ip net.IP) bool {
	for _, n := range l.trustedProxies {
		if n.Contains(ip) {
			return true
		}
	}
	return false
}

// rightmostUntrusted returns the rightmost X-Forwarded-For entry that is not
// itself a trusted proxy — the closest hop we cannot vouch for, i.e. the real
// client as far as the trusted proxies can attest. It returns "" when every hop
// is a trusted proxy.
func (l *Limiter) rightmostUntrusted(xff string) string {
	parts := strings.Split(xff, ",")
	for i := len(parts) - 1; i >= 0; i-- {
		h := strings.TrimSpace(parts[i])
		if h == "" {
			continue
		}
		ip := net.ParseIP(h)
		if ip == nil {
			return h
		}
		if !l.isTrustedProxy(ip) {
			return ip.String()
		}
	}
	return ""
}

// Middleware wraps h and rejects requests that exceed the per-IP rate with 429.
func (l *Limiter) Middleware(h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !l.Allow(l.clientKey(r)) {
			w.Header().Set("Retry-After", "1")
			http.Error(w, "Too Many Requests", http.StatusTooManyRequests)
			return
		}
		h.ServeHTTP(w, r)
	})
}
