package retrieve_test

import (
	"fmt"
	"net/http"
	"net/http/httptest"
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
