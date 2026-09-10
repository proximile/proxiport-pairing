package retrieve

import (
	"crypto/subtle"
	"fmt"
	"net/http"

	"github.com/gorilla/mux"

	"github.com/proximile/proxiport-pairing/deposit"
	"github.com/proximile/proxiport-pairing/internal/cache"
)

type InstallerHandler struct {
	StaticDeposit deposit.Deposit
	Cache         *cache.Cache
}

// pop takes the deposit for a pairing code out of the store, burning the code.
// The store does the burn atomically; see internal/cache for why that matters.
func (rh *InstallerHandler) pop(pairingCode string) (deposit.Deposit, bool) {
	val, ok := rh.Cache.Pop(pairingCode)
	if !ok {
		return deposit.Deposit{}, false
	}

	dep, ok := val.(deposit.Deposit)
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
		// takes and burns it in one operation. (The static/config deposit above
		// is intentionally reusable and is never stored, so it is unaffected.)
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
