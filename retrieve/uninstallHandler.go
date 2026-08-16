package retrieve

import "net/http"

type UninstallHandler struct{}

// Handle the request for the client uninstaller. No client data is needed: the
// uninstaller is generic (it removes whatever ProxiPort client is on the host),
// so it is served from a static /uninstall route rather than a pairing code --
// the counterpart to the install one-liner, run as
// `curl <pairing-service>/uninstall | sudo sh`.
func (rh *UninstallHandler) ServeHTTP(rw http.ResponseWriter, r *http.Request) {
	renderUninstall(rw, clientOs(r))
}

func renderUninstall(rw http.ResponseWriter, os string) {
	switch os {
	case "windows":
		rw.Header().Add("Content-Disposition", "attachment; filename=\"proxiport-uninstaller.ps1\"")
		includeFile(rw, "templates/header.txt")
		includeFile(rw, "templates/windows/uninstall.ps1")
	default:
		rw.Header().Add("Content-Disposition", "attachment; filename=\"proxiport-uninstaller.sh\"")
		includeFileRaw(rw, "templates/linux/init.sh")
		includeFile(rw, "templates/header.txt")
		includeFile(rw, "templates/linux/vars.sh")
		includeFile(rw, "templates/linux/functions.sh")
		includeFile(rw, "templates/linux/uninstall.sh")
	}
}
