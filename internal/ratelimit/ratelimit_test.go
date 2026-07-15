package ratelimit

import (
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

func TestLimiterBurstThenRefill(t *testing.T) {
	now := time.Unix(0, 0)
	l := New(1, 3) // 1 token/sec, burst 3
	l.now = func() time.Time { return now }

	// Burst of 3 is allowed, the 4th is denied.
	assert.True(t, l.Allow("1.2.3.4"))
	assert.True(t, l.Allow("1.2.3.4"))
	assert.True(t, l.Allow("1.2.3.4"))
	assert.False(t, l.Allow("1.2.3.4"), "burst should be exhausted")

	// A different IP has its own bucket.
	assert.True(t, l.Allow("5.6.7.8"))

	// After 2 seconds, ~2 tokens have refilled.
	now = now.Add(2 * time.Second)
	assert.True(t, l.Allow("1.2.3.4"))
	assert.True(t, l.Allow("1.2.3.4"))
	assert.False(t, l.Allow("1.2.3.4"))
}

func TestMiddleware429(t *testing.T) {
	l := New(1, 1)
	h := l.Middleware(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))

	rec1 := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = "9.9.9.9:1111"
	h.ServeHTTP(rec1, req)
	assert.Equal(t, http.StatusOK, rec1.Code)

	rec2 := httptest.NewRecorder()
	h.ServeHTTP(rec2, req)
	assert.Equal(t, http.StatusTooManyRequests, rec2.Code)
	assert.Equal(t, "1", rec2.Header().Get("Retry-After"))
}
