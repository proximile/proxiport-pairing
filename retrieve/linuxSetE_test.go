package retrieve_test

import (
	"net/http"
	"net/http/httptest"
	"regexp"
	"strings"
	"testing"

	"github.com/proximile/proxiport-pairing/retrieve"
)

// The rendered Linux installer and updater both start with "set -e" and call
// their functions bare. Under set -e a function's exit status is that of its
// last command, so a trailing `[ test ] && action` whose test is false makes
// the function return 1 -- and the whole script exits, silently, wherever the
// call happened to be.
//
// enable_lan_monitoring ended exactly that way. On a host whose every
// interface is RFC1918 -- a LAN server, a Pi, a NAT'd VM -- NET_WAN was empty,
// so the install aborted there: after writing a config file holding a live
// agent credential, and before set_file_and_dir_owner or
// create_systemd_service ever ran. It was masked on developer machines,
// where a docker bridge got classified as the WAN interface and kept the
// status zero.
//
// This asserts the general invariant rather than checking that one function:
// no function in a script that runs under set -e may end with a conditional
// AND-OR list.
func TestLinuxScriptFunctionsDoNotEndWithAConditional(t *testing.T) {
	scripts := map[string]string{
		"installer": renderLinuxInstaller(t),
		"update":    renderLinuxUpdate(t),
	}

	funcStart := regexp.MustCompile(`^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{\s*$`)
	conditional := regexp.MustCompile(`^(\[\[?.*\]\]?|test\s.*)\s*&&`)

	for name, body := range scripts {
		t.Run(name, func(t *testing.T) {
			if !strings.Contains(body, "set -e") {
				t.Fatalf("%s no longer runs under set -e; this guard assumed it does", name)
			}

			lines := strings.Split(body, "\n")
			for i, line := range lines {
				m := funcStart.FindStringSubmatch(line)
				if m == nil {
					continue
				}
				end := -1
				for j := i + 1; j < len(lines); j++ {
					if strings.TrimRight(lines[j], " \t") == "}" {
						end = j
						break
					}
				}
				if end == -1 {
					continue
				}
				for k := end - 1; k > i; k-- {
					last := strings.TrimSpace(lines[k])
					if last == "" || strings.HasPrefix(last, "#") {
						continue
					}
					if conditional.MatchString(last) {
						t.Errorf("line %d: %s() ends with a conditional, so a false test "+
							"becomes the function's exit status and set -e aborts the whole "+
							"script here:\n    %s\nEnd it with an explicit `return 0`, or "+
							"write the guard as if/fi.", k+1, m[1], last)
					}
					break
				}
			}
		})
	}
}

func renderLinuxUpdate(t *testing.T) string {
	t.Helper()

	req, _ := http.NewRequest(http.MethodGet, "/update", nil)
	req.Header.Set("User-Agent", "curl/7.79.1")
	rec := httptest.NewRecorder()
	(&retrieve.UpdateHandler{}).ServeHTTP(rec, req)

	return rec.Body.String()
}
