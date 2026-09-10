package retrieve

import (
	"crypto/subtle"
	"fmt"
	"net/http"
	"sync"

	"github.com/gorilla/mux"
	"github.com/patrickmn/go-cache"

	"github.com/proximile/proxiport-pairing/deposit"
)

type InstallerHandler struct {
	StaticDeposit deposit.Deposit
	Cache         *cache.Cache

	// popMu makes the single-use burn atomic. go-cache has no
	// compare-and-delete, so Get-then-Delete is two operations: N concurrent
	// requests for one code each observe the entry and each receive a rendered
	// installer carrying the live agent credential. That matters because the
	// burn is the only thing that makes a stolen code visible -- a pairing code
	// travels in a URL path, so it lands in proxy logs, shell history and chat
	// pastes, and "No pairing found" on the real install is the operator's one
	// signal that someone else got there first. Redeeming alongside the
	// legitimate install leaves no trace at all.
	//
	// Serializing the pair costs nothing here: this is a provisioning endpoint
	// fetched once per agent.
	popMu sync.Mutex
}

// pop returns the deposit stored under a pairing code and removes it in the
// same critical section, so a code is redeemable exactly once even when
// several requests for it arrive at once.
func (rh *InstallerHandler) pop(pairingCode string) (dep deposit.Deposit, found bool) {
	rh.popMu.Lock()
	defer rh.popMu.Unlock()

	val, ok := rh.Cache.Get(pairingCode)
	if !ok {
		return deposit.Deposit{}, false
	}
	rh.Cache.Delete(pairingCode)

	dep, ok = val.(deposit.Deposit)
	return dep, ok
}

// Handle the request for previously pairing data aka client credentials identified by the pairing code.
// If pairing code exists, render an installer script with client credentials as variables dynamically inserted.
func (rh *InstallerHandler) ServeHTTP(rw http.ResponseWriter, r *http.Request) {
	// The rendered installer carries a live agent credential and the pairing
	// code is single-use, so nothing on the path may retain or re-serve this
	// response -- not a CDN, not the operator's own reverse proxy, not the
	// requesting client. Set before anything is written, and on the 404 too:
	// that response still tells a cache which codes exist. Vary is belt and
	// braces for a cache that ignores no-store; the body differs by User-Agent
	// (Linux shell vs PowerShell), so a URL-keyed cache would otherwise serve
	// the wrong installer.
	rw.Header().Set("Cache-Control", "no-store, no-cache, max-age=0, must-revalidate")
	rw.Header().Set("Pragma", "no-cache")
	rw.Header().Set("Expires", "0")
	rw.Header().Set("Vary", "User-Agent")

	vars := mux.Vars(r)
	pairingCode := vars["pairingCode"]
	os := clientOs(r)
	var data deposit.Deposit
	// Constant-time match against the static pairing code, guarded so an empty
	// (unconfigured) static code never matches a request.
	if rh.StaticDeposit.Code != "" && subtle.ConstantTimeCompare([]byte(pairingCode), []byte(rh.StaticDeposit.Code)) == 1 {
		data = rh.StaticDeposit
	} else {
		// Single-use: a rendered installer carries live credentials, so a
		// pairing code must not stay replayable for the rest of its TTL. pop
		// takes and burns it in one critical section. (The static/config
		// deposit above is intentionally reusable and is never cached, so it is
		// unaffected.)
		found := false
		data, found = rh.pop(pairingCode)
		if !found {
			rw.WriteHeader(http.StatusNotFound)
			// #nosec G705 -- pairingCode is constrained to [0-9a-zA-Z]{7}
			// by the mux route pattern, and the response is a plain-text
			// script download, not HTML.
			_, _ = fmt.Fprintf(rw, "#No pairing found by pairing code %s\n", pairingCode)
			return
		}
	}
	renderInstaller(rw, os, data)
}

func renderInstaller(rw http.ResponseWriter, os string, data deposit.Deposit) {
	switch os {
	case "windows":
		rw.Header().Add("Content-Disposition", "attachment; filename=\"proxiport-installer.ps1\"")
		includeFileRaw(rw, "templates/windows/installer_init.ps1")
		includeFile(rw, "templates/header.txt")
		renderTemplate(rw, "templates/windows/vars.ps1", deposit.SanitizeForPowerShell(data))
		includeFile(rw, "templates/windows/functions.ps1")
		includeFile(rw, "templates/windows/install.ps1")
	default:
		rw.Header().Add("Content-Disposition", "attachment; filename=\"proxiport-installer.sh\"")
		includeFileRaw(rw, "templates/linux/init.sh")
		includeFile(rw, "templates/header.txt")
		renderTemplate(rw, "templates/linux/installer_vars.sh", deposit.SanitizeForBash(data))
		includeFile(rw, "templates/linux/vars.sh")
		includeFile(rw, "templates/linux/functions.sh")
		includeFile(rw, "templates/linux/install.sh")
	}
}
