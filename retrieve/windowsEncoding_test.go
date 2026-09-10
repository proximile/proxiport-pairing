package retrieve_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"unicode/utf8"

	"github.com/gorilla/mux"

	"github.com/proximile/proxiport-pairing/deposit"
	"github.com/proximile/proxiport-pairing/internal/cache"
	"github.com/proximile/proxiport-pairing/retrieve"
)

const windowsUserAgent = "Mozilla/5.0 (Windows NT; Windows NT 10.0; en-US) WindowsPowerShell/5.1.20348.1"

// TestWindowsScriptsAreASCII asserts every byte of every rendered PowerShell
// script is ASCII.
//
// The documented Windows flow saves the script with Invoke-WebRequest -OutFile
// and runs it with `powershell -File`. Windows PowerShell decodes a file that
// carries no byte order mark using the system ANSI codepage, not UTF-8, and we
// serve no byte order mark. On the Western codepage that most Windows installs
// use, the three bytes of a UTF-8 em dash decode to three separate characters,
// the last of which is a right curly quote -- and PowerShell accepts curly
// quotes as string delimiters.
//
// So an em dash inside a double-quoted string closes that string early, the
// remaining words become bare tokens, and the file no longer parses. It is not
// a display problem: the script does not run at all. Six em dashes in the
// verification messages were enough to stop the installer and the updater from
// loading on any host that received them.
//
// Serving a byte order mark would also work, but ASCII is the narrower promise
// and it does not depend on how the file is written to disk.
func TestWindowsScriptsAreASCII(t *testing.T) {
	scripts := map[string]string{
		"installer": renderWindows(t, installerHandlerForTest(), "/cZ1ZhsG", "cZ1ZhsG"),
		"update":    renderWindows(t, &retrieve.UpdateHandler{}, "/update", ""),
		"uninstall": renderWindows(t, &retrieve.UninstallHandler{}, "/uninstall", ""),
	}

	for name, body := range scripts {
		t.Run(name, func(t *testing.T) {
			for _, line := range findNonASCII(body) {
				t.Errorf("line %d contains %q (%U), which Windows PowerShell does not decode as UTF-8 from a file without a byte order mark:\n    %s",
					line.number, line.offender, line.offender, line.text)
			}
		})
	}
}

type nonASCIILine struct {
	number   int
	offender rune
	text     string
}

func findNonASCII(body string) []nonASCIILine {
	var found []nonASCIILine
	for i, line := range strings.Split(body, "\n") {
		for _, r := range line {
			if r > utf8.RuneSelf-1 {
				found = append(found, nonASCIILine{number: i + 1, offender: r, text: strings.TrimSpace(line)})
				break
			}
		}
	}
	return found
}

func installerHandlerForTest() http.Handler {
	return &retrieve.InstallerHandler{
		StaticDeposit: deposit.Deposit{
			ConnectUrl:  "https://proxiport.example.com",
			Fingerprint: "2a:c1:71:09:80:ba:7c:10:05:e5:2c:99:6d:15:56:24",
			ClientId:    "client1",
			Password:    "foobaz",
			Code:        "cZ1ZhsG",
		},
		Cache: cache.New(),
	}
}

func renderWindows(t *testing.T, h http.Handler, path, pairingCode string) string {
	t.Helper()

	req, _ := http.NewRequest(http.MethodGet, path, nil)
	req.Header.Set("User-Agent", windowsUserAgent)
	if pairingCode != "" {
		req = mux.SetURLVars(req, map[string]string{"pairingCode": pairingCode})
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("rendering %s returned %d, want 200", path, rec.Code)
	}
	return rec.Body.String()
}
