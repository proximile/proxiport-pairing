// Package cache holds the short-lived pairing deposits: a deposit is stored
// under a freshly minted pairing code, and the installer handler takes it back
// out exactly once when that code is redeemed.
package cache

import (
	"sync"
	"time"

	gocache "github.com/patrickmn/go-cache"
)

// Cache stores pairing deposits with a default expiration of 5 minutes, purging
// expired items every 2 minutes.
//
// It wraps patrickmn/go-cache to add an atomic Pop, and deliberately exposes no
// Get and no Delete. go-cache has Get and Delete but no get-and-delete
// primitive, so a "single use" burn written as Get-then-Delete is two lock
// acquisitions with a gap in between: two concurrent requests for one pairing
// code both observe the entry and both receive an installer carrying the live
// agent credential, while the legitimate install still succeeds -- so the
// theft leaves no trace. Keeping Get and Delete off this type means that
// sequence cannot be written again.
type Cache struct {
	mu sync.Mutex
	c  *gocache.Cache
}

// New creates the pairing-code store.
func New() *Cache {
	return &Cache{c: gocache.New(5*time.Minute, 2*time.Minute)}
}

// Set stores a deposit under a pairing code for d.
func (c *Cache) Set(pairingCode string, deposit any, d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.c.Set(pairingCode, deposit, d)
}

// Pop returns the deposit stored under a pairing code and removes it in the
// same critical section, so a code is redeemable exactly once even when several
// requests for it arrive together.
func (c *Cache) Pop(pairingCode string) (any, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()

	deposit, ok := c.c.Get(pairingCode)
	if !ok {
		return nil, false
	}
	c.c.Delete(pairingCode)

	return deposit, true
}
