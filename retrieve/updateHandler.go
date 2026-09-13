package retrieve

import (
	"net/http"
)

// UpdateHandler serves the credential-free update script. It carries no deposit
// data: the update path renders static templates only.
type UpdateHandler struct{}

// Handle the request for a client update.
// No client data is needed
func (rh *UpdateHandler) ServeHTTP(rw http.ResponseWriter, r *http.Request) {
	renderUpdate(rw, clientOs(r))
}

func renderUpdate(rw http.ResponseWriter, os string) {
	// The update script is how an agent-side security fix actually reaches an
	// already-deployed fleet, so a cache holding a stale copy delays the fix
	// rather than merely serving old bytes. It carries no credential, but it is
	// small and fetched rarely, so no-store costs nothing worth having.
	//
	// Vary because the body is chosen by User-Agent: a cache keyed on the URL
	// alone would hand a PowerShell agent the shell script.
	rw.Header().Set("Cache-Control", "no-store")
	rw.Header().Set("Vary", "User-Agent")

	switch os {
	case "windows":
		rw.Header().Add("Content-Disposition", "attachment; filename=\"proxiport-update.ps1\"")
		includeFileRaw(rw, "templates/windows/update_init.ps1")
		includeFile(rw, "templates/header.txt")
		includeFile(rw, "templates/windows/functions.ps1")
		includeFile(rw, "templates/windows/update.ps1")
	default:
		rw.Header().Add("Content-Disposition", "attachment; filename=\"proxiport-update.sh\"")
		includeFileRaw(rw, "templates/linux/init.sh")
		includeFile(rw, "templates/header.txt")
		includeFile(rw, "templates/linux/vars.sh")
		includeFile(rw, "templates/linux/functions.sh")
		includeFile(rw, "templates/linux/update.sh")
	}
}
