package retrieve_test

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/proximile/proxiport-pairing/retrieve"
)

// GET /uninstall serves a runnable client uninstaller. No pairing code / deposit
// data is involved -- the uninstaller is generic.
func TestUninstallHandler_Linux(t *testing.T) {
	h := &retrieve.UninstallHandler{}
	req, _ := http.NewRequest(http.MethodGet, "/uninstall", nil)
	req.Header.Set("User-Agent", "curl/8.5.0")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	assert.Equal(t, http.StatusOK, rec.Result().StatusCode)
	body := rec.Body.String()

	// functions.sh (which defines uninstall()) must be assembled in, and the
	// uninstall.sh fragment must call it.
	assert.Contains(t, body, "uninstall() {", "functions.sh (uninstall) not assembled")
	assert.Contains(t, body, "--service uninstall", "service-uninstall step missing")
	assert.Contains(t, body, "You are running the proxiportd server",
		"proxiportd coexistence guard missing from the uninstaller")

	// uninstall.sh must now be a fragment, not the old standalone script.
	assert.NotContains(t, body, "# INCLUDE functions.sh",
		"uninstall.sh still carries the vestigial INCLUDE marker")

	// Regression guard: the client binary must be listed once in the removal set.
	assert.NotContains(t, body, "/usr/local/bin/proxiport\n    /usr/local/bin/proxiport",
		"client binary listed twice in the uninstall FILES list")

	assert.Contains(t, rec.Header().Get("Content-Disposition"), "proxiport-uninstaller.sh")
}

func TestUninstallHandler_Windows(t *testing.T) {
	h := &retrieve.UninstallHandler{}
	req, _ := http.NewRequest(http.MethodGet, "/uninstall", nil)
	req.Header.Set("User-Agent", "Mozilla/5.0 PowerShell/7.4.0")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	assert.Equal(t, http.StatusOK, rec.Result().StatusCode)
	body := rec.Body.String()
	assert.Contains(t, body, "--service uninstall", "windows service-uninstall missing")
	assert.NotContains(t, body, "# Coming soon", "windows uninstaller is still a stub")
	assert.Contains(t, rec.Header().Get("Content-Disposition"), "proxiport-uninstaller.ps1")
}
