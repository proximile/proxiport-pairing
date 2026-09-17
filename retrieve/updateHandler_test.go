package retrieve_test

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/proximile/proxiport-pairing/retrieve"
)

type TestUpdateWith struct {
	userAgent string
}
type ExpectedUpdateResults struct {
	httpStatus int
	keyword    string
}

func TestUpdateHandler_ServeHTTP(t *testing.T) {
	var tests = []struct {
		tw TestUpdateWith
		er ExpectedUpdateResults
	}{
		{
			TestUpdateWith{"curl/7.79.1"},
			ExpectedUpdateResults{200, "BEGINNING of templates/linux/update.sh"},
		},
		{
			TestUpdateWith{"Mozilla/5.0 (Windows NT; Windows NT 10.0; en-US) WindowsPowerShell/5.1.20348.1"},
			ExpectedUpdateResults{200, "BEGINNING of templates/windows/update.ps1"},
		},
	}

	// Create the handler to be tested
	updateHandler := &retrieve.UpdateHandler{}

	for _, tc := range tests {
		t.Run(fmt.Sprintf("User-Agent='%s'", tc.tw.userAgent), func(t *testing.T) {
			request, _ := http.NewRequest(http.MethodGet, "/update", nil)
			request.Header.Set("User-Agent", tc.tw.userAgent)
			recorder := httptest.NewRecorder()
			updateHandler.ServeHTTP(recorder, request)
			assert.Equal(t, tc.er.httpStatus, recorder.Result().StatusCode)
			assert.Contains(t, recorder.Header().Get("Content-Disposition"), "attachment; filename=\"proxiport-update", "Content-Disposition Header wrong or missing")
			assert.Contains(t, recorder.Body.String(), tc.er.keyword, fmt.Sprintf("Expexted key word '%s' missing.", tc.er.keyword))
			t.Log("Got HTTP status code", recorder.Result().StatusCode)
		})
	}
}

// TestUpdateHandler_WindowsStagingIsProtected pins the properties that make the
// Windows updater safe, and that make it work at all.
//
// It used to stage the new agent binary in C:\windows\temp\proxiport-update.
// That directory's default DACL grants BUILTIN\Users create-file and
// create-subdirectory with (CI) inheritance, so any unprivileged local user can
// drop a file into it -- and the scheduled task that reads it runs as
// NT AUTHORITY\SYSTEM.
//
// Worse, the script deleted that directory immediately after reading the new
// binary's version, so the slot was guaranteed empty when the SYSTEM task fired
// ten seconds later: no race to win, and the ZIP update path never actually
// installed anything.
//
// There is no Windows runner and no PowerShell linting in CI, so this is the
// guard.
func TestUpdateHandler_WindowsStagingIsProtected(t *testing.T) {
	body := renderWindowsUpdate(t)

	// The staged binary must never live where a local user can create files.
	assert.NotContains(t, body, `C:\windows\temp\proxiport-update\proxiport.exe`,
		"the scheduled task runs as SYSTEM; it must not read a binary out of C:\\Windows\\Temp")
	assert.NotContains(t, body, `C:\Windows\temp\proxiport_windows_x86_64.zip`)
	assert.NotContains(t, body, `C:\Windows\temp\$( $assetName )`)
	assert.NotContains(t, body, `GetEnvironmentVariable('TEMP', 'Machine')`,
		"the scheduled task's own script must not live in the machine TEMP directory either")

	// C:\Windows\Temp may still be named, but only to clean up what older
	// versions left there.
	inBlockComment := false
	for _, line := range strings.Split(body, "\n") {
		l := strings.TrimSpace(line)
		if strings.HasPrefix(l, "<#") {
			inBlockComment = true
		}
		if inBlockComment {
			if strings.Contains(l, "#>") {
				inBlockComment = false
			}
			continue
		}
		if !strings.Contains(strings.ToLower(l), `c:\windows\temp`) || strings.HasPrefix(l, "#") {
			continue
		}
		assert.True(t,
			strings.HasPrefix(l, "if (Test-Path ") || strings.HasPrefix(l, "Remove-Item "),
			"C:\\Windows\\Temp may only be swept, never staged into: %s", l)
	}

	// Exactly one file crosses into the SYSTEM task, at a protected path.
	assert.Contains(t, body, `$newExe = 'C:\Program Files\proxiport\proxiport.new.exe'`)
	assert.NotContains(t, body, "& $migartion",
		"the migration script was a second SYSTEM code-execution sink on an unreachable path")
	assert.NotContains(t, body, "Start-Process msiexec.exe",
		"the msi branch was a third SYSTEM sink and could never be reached")

	// The staged binary must survive until the task swaps it in. The line that
	// deleted the whole staging directory right after reading the version is
	// why the ZIP update path never updated anything.
	assert.NotContains(t, body, "Remove-Item $temp -Recurse -Force",
		"deleting the staging directory before the task runs makes the update a no-op")

	// Staging is chosen by the caller so the download never lands inside the
	// directory it extracts to.
	assert.Contains(t, body, "-StagingDir")
	assert.Contains(t, body, "the archive is inside its own destination",
		"Expand-Zip's PowerShell < 5 fallback empties the destination first")

	// The task-script path now contains a space.
	assert.Contains(t, body, "-File `\"$( $taskFile )`\"",
		"an unquoted -File argument breaks on a path under C:\\Program Files")
}

func renderWindowsUpdate(t *testing.T) string {
	t.Helper()

	req, _ := http.NewRequest(http.MethodGet, "/update", nil)
	req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT; Windows NT 10.0; en-US) WindowsPowerShell/5.1.20348.1")
	rec := httptest.NewRecorder()
	(&retrieve.UpdateHandler{}).ServeHTTP(rec, req)

	return rec.Body.String()
}

// TestUpdateHandler_CacheHeaders pins the two directives the update route needs.
// no-store because /update is how an agent-side security fix reaches an
// already-deployed fleet -- a cached copy delays the fix. Vary because the body
// is picked by User-Agent, so a URL-keyed cache would serve a PowerShell agent
// the shell script.
func TestUpdateHandler_CacheHeaders(t *testing.T) {
	for _, ua := range []string{"curl/7.79.1", "Mozilla/5.0 PowerShell/7.4.0"} {
		req, _ := http.NewRequest(http.MethodGet, "/update", nil)
		req.Header.Set("User-Agent", ua)
		rec := httptest.NewRecorder()
		(&retrieve.UpdateHandler{}).ServeHTTP(rec, req)

		assert.Equal(t, "no-store", rec.Header().Get("Cache-Control"), ua)
		assert.Equal(t, "User-Agent", rec.Header().Get("Vary"), ua)
	}
}
