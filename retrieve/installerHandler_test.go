package retrieve_test

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/mux"
	"github.com/stretchr/testify/assert"

	"github.com/proximile/proxiport-pairing/deposit"
	"github.com/proximile/proxiport-pairing/internal/cache"
	"github.com/proximile/proxiport-pairing/retrieve"
)

type TestInstallerWith struct {
	userAgent   string
	pairingCode string
}
type ExpectedInstallerResults struct {
	httpStatus int
	keyword    string
	variable   string
}

func TestInstallerHandler_ServeHTTP(t *testing.T) {
	c := cache.New()
	demoDeposit := deposit.Deposit{
		ConnectUrl:  "https://proxiport.example.com",
		Fingerprint: "2a:c1:71:09:80:ba:7c:10:05:e5:2c:99:6d:15:56:24",
		ClientId:    "client1\";exit",
		Password:    "foobaz",
		Code:        "cZ1ZhsG",
	}
	var tests = []struct {
		tw TestInstallerWith
		er ExpectedInstallerResults
	}{
		{
			TestInstallerWith{"curl/7.79.1", "cZ1ZhsG"},
			ExpectedInstallerResults{200, "BEGINNING of templates/linux/install.sh", strings.ReplaceAll(demoDeposit.ClientId, "\"", "\\\"")},
		},
		{
			TestInstallerWith{"curl/7.79.1", "C6esANp"},
			ExpectedInstallerResults{200, "/bin/sh -e", strings.ReplaceAll(demoDeposit.ClientId, "\"", "\\\"")},
		},
		{
			TestInstallerWith{"Mozilla/5.0 (Windows NT; Windows NT 10.0; en-US) WindowsPowerShell/5.1.20348.1", "cZ1ZhsG"},
			ExpectedInstallerResults{200, "function Expand-Zip", strings.ReplaceAll(demoDeposit.ClientId, "\"", "`\"")},
		},

		{
			TestInstallerWith{"go-test", "abcdefg"},
			ExpectedInstallerResults{404, "#No pairing found by pairing code abcdefg", ""},
		},
	}
	// Store pairing data in the cache
	c.Set("C6esANp", demoDeposit, 10*time.Second)

	// Create the handler to be tested
	installerHandler := &retrieve.InstallerHandler{
		StaticDeposit: demoDeposit,
		Cache:         c,
	}

	for _, tc := range tests {
		t.Run(fmt.Sprintf("User-Agent='%s' PairingCode=%s", tc.tw.userAgent, tc.tw.pairingCode), func(t *testing.T) {
			request, _ := http.NewRequest(http.MethodGet, "/"+tc.tw.pairingCode, nil)
			// Simulate a URL like /0000000
			vars := map[string]string{
				"pairingCode": tc.tw.pairingCode,
			}
			request.Header.Set("User-Agent", tc.tw.userAgent)
			request = mux.SetURLVars(request, vars)
			recorder := httptest.NewRecorder()
			installerHandler.ServeHTTP(recorder, request)
			assert.Equal(t, tc.er.httpStatus, recorder.Result().StatusCode)
			assert.Contains(t, recorder.Body.String(), tc.er.keyword, fmt.Sprintf("Expexted key word '%s' missing.", tc.er.keyword))
			assert.Contains(t, recorder.Body.String(), tc.er.variable, "Variable not found in body:\n"+recorder.Body.String())
			if recorder.Result().StatusCode == 200 {
				assert.Contains(t, recorder.Header().Get("Content-Disposition"), "attachment; filename=\"proxiport-installer", "Content-Disposition Header wrong or missing")
			}
			t.Log("Got HTTP status code", recorder.Result().StatusCode)
		})
	}
}

// TestInstallerHandler_SedInjectionGuard is a regression guard for the
// unauthenticated-deposit -> root-RCE class of bug. The four deposit fields are
// spliced into `sed -i` replacements the (root) Linux installer runs; if they
// reach sed raw, a value like `x/g;e <cmd>;#` breaks out of the s-command into
// GNU sed's `e`, which runs as root. The installer must therefore route every
// deposit value through sed_rescape before the sed calls. This test fails if
// anyone reverts prepare_config to raw interpolation.
func TestInstallerHandler_SedInjectionGuard(t *testing.T) {
	c := cache.New()
	demoDeposit := deposit.Deposit{
		ConnectUrl:  "https://proxiport.example.com",
		Fingerprint: "2a:c1:71:09:80:ba:7c:10:05:e5:2c:99:6d:15:56:24",
		ClientId:    "client1",
		Password:    "foobaz",
		Code:        "cZ1ZhsG",
	}
	installerHandler := &retrieve.InstallerHandler{StaticDeposit: demoDeposit, Cache: c}

	request, _ := http.NewRequest(http.MethodGet, "/cZ1ZhsG", nil)
	request.Header.Set("User-Agent", "curl/7.79.1")
	request = mux.SetURLVars(request, map[string]string{"pairingCode": "cZ1ZhsG"})
	recorder := httptest.NewRecorder()
	installerHandler.ServeHTTP(recorder, request)
	body := recorder.Body.String()

	// The escaping helper must be present.
	assert.Contains(t, body, "sed_rescape()", "sed_rescape helper missing from installer")

	// Regression guard for the duplicate-key bug: the example config ships more
	// than one commented example for a key (e.g. two #fingerprint lines), and a
	// blind `s/#*fingerprint = .*/.../g` activated every one, leaving a duplicate
	// key that failed the config parse ("key fingerprint is already defined").
	// The installer must anchor the replacement to a real assignment and keep
	// only the first activated server/auth/fingerprint line.
	assert.Contains(t, body, "seen[$1]++",
		"installer no longer collapses duplicate activated config keys (duplicate-key regression)")
	assert.NotContains(t, body, `s/#*fingerprint = .*/`,
		"installer reverted to the greedy, unanchored fingerprint replacement")

	// Each deposit value must be escaped before use in the sed replacements.
	for _, v := range []string{"CONNECT_URL", "CLIENT_ID", "PASSWORD", "FINGERPRINT"} {
		assert.Contains(t, body, "${"+v+"}\" | sed_rescape)",
			"deposit value "+v+" is not routed through sed_rescape before sed")
	}

	// The raw, injectable interpolation forms must be gone.
	for _, raw := range []string{
		`auth = \"${CLIENT_ID}:${PASSWORD}\"`,
		`fingerprint = \"${FINGERPRINT}\"`,
		`server = \"${CONNECT_URL}\"`,
	} {
		assert.NotContains(t, body, raw, "raw un-escaped deposit interpolation still present in installer sed")
	}
}
