package main

import (
	"crypto/subtle"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"time"

	"github.com/gorilla/mux"

	"github.com/proximile/proxiport-pairing/cors"
	"github.com/proximile/proxiport-pairing/deposit"
	"github.com/proximile/proxiport-pairing/internal/cache"
	"github.com/proximile/proxiport-pairing/internal/config"
	"github.com/proximile/proxiport-pairing/internal/ratelimit"
	"github.com/proximile/proxiport-pairing/retrieve"
)

// Version is filled at link time with -ldflags="-X 'main.Version=N.N.N'".
var Version = "0.0.0-src"

func main() {
	v := false
	flag.BoolVar(&v, "v", false, "version")
	confFile := flag.String("c", "proxiport-pairing.conf", "config file")
	flag.Parse()
	if v {
		fmt.Println("proxiport-pairing", Version)
		os.Exit(0)
	}
	cfg := config.New(*confFile)
	c := cache.New()

	depositHandler := &deposit.Handler{
		Cache:       c,
		ServerUrl:   cfg.Server.Url,
		AllowOrigin: cfg.Server.CorsAllowOrigin,
	}
	installerHandler := &retrieve.InstallerHandler{
		StaticDeposit: cfg.StaticDeposit,
		Cache:         c,
	}
	updateHandler := &retrieve.UpdateHandler{}
	uninstallHandler := &retrieve.UninstallHandler{}
	corsHandler := &cors.Handler{AllowOrigin: cfg.Server.CorsAllowOrigin}

	// Per-IP rate limits for the unauthenticated endpoints. Deposit creates a
	// pairing code, so it is stricter; installer/update retrieval is looser to
	// tolerate legitimate re-fetches. Both are process-local and best-effort.
	depositLimiter := ratelimit.New(1, 10)  // ~1/sec sustained, burst 10
	retrieveLimiter := ratelimit.New(2, 30) // ~2/sec sustained, burst 30

	// Trust X-Forwarded-For / X-Real-IP only from the operator-configured
	// reverse-proxy ranges, so per-IP limits key on the real client rather than
	// collapsing to a single bucket behind a proxy. Empty by default (direct
	// peer address only).
	trustedProxies, err := ratelimit.ParseCIDRs(cfg.Server.TrustedProxies)
	if err != nil {
		log.Fatalf("invalid server.trusted_proxies: %v", err)
	}
	depositLimiter.SetTrustedProxies(trustedProxies)
	retrieveLimiter.SetTrustedProxies(trustedProxies)

	// The deposit endpoint mints a pairing code (and thus a root installer).
	// When a deposit_auth_token is configured, require it as a bearer token so
	// only the ProxiPort server can deposit; empty by default, leaving deposits
	// open exactly as before.
	var depositEndpoint http.Handler = depositHandler
	if cfg.Server.DepositAuthToken != "" {
		depositEndpoint = requireBearer(cfg.Server.DepositAuthToken, depositEndpoint)
	} else if !isLoopbackBind(cfg.Server.Address) {
		log.Printf("WARNING: the deposit endpoint is UNAUTHENTICATED (no deposit_auth_token set) and bound to a non-loopback address %q. Anyone who can reach it can mint credential-bearing installers. Set deposit_auth_token before exposing this service.", cfg.Server.Address)
	}

	r := mux.NewRouter()
	r.PathPrefix("/").Methods("OPTIONS").Handler(corsHandler)
	r.Path("/").Methods("POST").Handler(depositLimiter.Middleware(depositEndpoint))
	r.Path("/update").Methods("GET").Handler(retrieveLimiter.Middleware(updateHandler))
	r.Path("/uninstall").Methods("GET").Handler(retrieveLimiter.Middleware(uninstallHandler))
	r.Path("/{pairingCode:[0-9a-zA-Z]{7}}").Methods("GET").Handler(retrieveLimiter.Middleware(installerHandler))

	log.Println("proxiport-pairing", Version, "listening on", cfg.Server.Address)
	srv := &http.Server{
		Addr:              cfg.Server.Address,
		Handler:           r,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	log.Fatal(srv.ListenAndServe())
}

// isLoopbackBind reports whether addr (host:port) binds only to loopback. An
// empty host or a wildcard (0.0.0.0, ::) is treated as non-loopback (exposed), and
// a hostname that does not resolve to a literal loopback IP is treated as exposed
// so the unauthenticated-deposit warning is not silently suppressed.
func isLoopbackBind(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		host = addr
	}
	switch host {
	case "":
		return false
	case "localhost":
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// requireBearer wraps h so a request must carry the exact bearer token in its
// Authorization header ("Authorization: Bearer <token>"). The comparison is
// constant-time. Used to gate the deposit endpoint when a deposit_auth_token is
// configured; unmatched requests are rejected with 401.
func requireBearer(token string, h http.Handler) http.Handler {
	want := []byte("Bearer " + token)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := []byte(r.Header.Get("Authorization"))
		if subtle.ConstantTimeCompare(got, want) != 1 {
			w.Header().Set("WWW-Authenticate", "Bearer")
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		h.ServeHTTP(w, r)
	})
}
