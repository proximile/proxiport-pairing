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

// TestInstallerHandler_CacheIsSingleUse asserts a cached pairing code is consumed
// on first retrieval: the rendered installer carries live credentials, so the code
// must 404 on replay rather than stay fetchable for the rest of its TTL. The
// static/config deposit is intentionally reusable and must keep serving.
func TestInstallerHandler_CacheIsSingleUse(t *testing.T) {
	c := cache.New()
	dep := deposit.Deposit{
		ConnectUrl:  "https://proxiport.example.com",
		Fingerprint: "2a:c1:71:09:80:ba:7c:10:05:e5:2c:99:6d:15:56:24",
		ClientId:    "client1",
		Password:    "foobaz",
		Code:        "STATIC7",
	}
	c.Set("CACHED1", dep, 10*time.Second)
	h := &retrieve.InstallerHandler{StaticDeposit: dep, Cache: c}

	get := func(code string) int {
		req, _ := http.NewRequest(http.MethodGet, "/"+code, nil)
		req = mux.SetURLVars(req, map[string]string{"pairingCode": code})
		req.Header.Set("User-Agent", "curl/7.79.1")
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec.Result().StatusCode
	}

	assert.Equal(t, 200, get("CACHED1"), "first fetch of a cached code should succeed")
	assert.Equal(t, 404, get("CACHED1"), "cached pairing code must be single-use (deleted after first fetch)")

	// The static/config deposit is not cached and must remain reusable.
	assert.Equal(t, 200, get("STATIC7"), "static deposit should serve")
	assert.Equal(t, 200, get("STATIC7"), "static deposit must stay reusable")
}

// TestInstallerHandler_ConfigKeysSetSafely guards two classes of bug in how the
// (root) Linux installer writes the deposit fields into proxiport.conf:
//
//   - unauthenticated-deposit -> root RCE: the four deposit fields must never be
//     spliced into a shell/sed command. set_toml_key passes the value through
//     the ENVIRONMENT into awk, where it is only ever printed as data, so a
//     crafted URL/id/password/fingerprint cannot inject a root command.
//   - duplicate-key parse failure: the installer must set each key idempotently
//     (replace-first-or-insert, drop dups within the section), never blindly
//     append after a section header -- otherwise a re-install over an existing
//     config, or a template shipping several commented examples for one key,
//     leaves a duplicate key that fails proxiport's TOML parse.
//
// This test fails if anyone reintroduces raw sed interpolation or a blind append.
func TestInstallerHandler_ConfigKeysSetSafely(t *testing.T) {
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

	// The section-scoped setter must be present and pass the value via the
	// environment into awk, never spliced into the program text or a shell/sed
	// command.
	assert.Contains(t, body, "set_toml_key()", "set_toml_key helper missing from installer")
	assert.Contains(t, body, `STK_VAL="$3" awk`, "set_toml_key must pass the value via the environment")
	assert.Contains(t, body, `ENVIRON["STK_VAL"]`, "set_toml_key must read the value from the environment, not the program text")

	// Each deposit value is written with set_toml_key.
	for _, call := range []string{
		"set_toml_key client server ",
		"set_toml_key client auth ",
		"set_toml_key client fingerprint ",
	} {
		assert.Contains(t, body, call, "deposit value not set via set_toml_key: "+call)
	}

	// No deposit value is spliced into a sed s-command any more.
	for _, sed := range []string{
		`#\{0,1\}fingerprint = .*`, // the anchored sed
		`s/#*fingerprint = .*/`,    // the older greedy sed
	} {
		assert.NotContains(t, body, sed, "installer reverted to sed-based key replacement")
	}

	// No config value is appended after a section header anywhere -- enabled,
	// net_wan/net_lan and the interpreter aliases all go through the idempotent
	// set_toml_key, so re-running the installer never duplicates a key.
	assert.NotContains(t, body, "]/a ", "installer still uses a blind `sed .../a` append after a section header")
	assert.Contains(t, body, "set_toml_key remote-commands enabled", "remote-commands.enabled not set via set_toml_key")
	assert.Contains(t, body, "set_toml_key remote-scripts enabled", "remote-scripts.enabled not set via set_toml_key")
	assert.Contains(t, body, "set_toml_key monitoring net_", "net interface not set via set_toml_key")
	assert.Contains(t, body, "set_toml_key interpreter-aliases", "interpreter alias not set via set_toml_key")
}

// TestInstallerHandler_VerificationIsFresh guards the post-install verify step:
// it must scan only THIS run's log (a good install must not report failure just
// because a stale /var/log/proxiport/proxiport.log holds old errors from a
// previous config/server), and it must recognize the server's current
// "already connected" rejection so the duplicate-machine-id auto-recovery fires.
func TestInstallerHandler_VerificationIsFresh(t *testing.T) {
	c := cache.New()
	demoDeposit := deposit.Deposit{
		ConnectUrl: "https://proxiport.example.com", Fingerprint: "2a:c1", ClientId: "client1", Password: "foobaz", Code: "cZ1ZhsG",
	}
	installerHandler := &retrieve.InstallerHandler{StaticDeposit: demoDeposit, Cache: c}
	request, _ := http.NewRequest(http.MethodGet, "/cZ1ZhsG", nil)
	request.Header.Set("User-Agent", "curl/7.79.1")
	request = mux.SetURLVars(request, map[string]string{"pairingCode": "cZ1ZhsG"})
	recorder := httptest.NewRecorder()
	installerHandler.ServeHTTP(recorder, request)
	body := recorder.Body.String()

	// The client log is cleared before the first start, so verify scans only this run.
	assert.Contains(t, body, `rm -f "$LOG_FILE"`, "installer no longer clears the stale log before the first start")
	// check_log recognizes the current server rejection so the machine-id auto-recovery fires.
	assert.Contains(t, body, "client is already connected", "check_log no longer matches the current 'already connected' server message")
}
