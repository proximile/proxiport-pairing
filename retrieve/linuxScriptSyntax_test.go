package retrieve_test

import (
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"github.com/gorilla/mux"

	"github.com/proximile/proxiport-pairing/retrieve"
)

// A Linux host fetches with curl, and retrieve.go selects the shell templates
// for any User-Agent that does not contain "PowerShell".
const linuxUserAgent = "curl/8.5.0"

// The Windows scripts are rendered and then parsed on a real windows-latest
// runner under Windows PowerShell 5.1, because a script that does not load is
// not a display problem -- it does not run at all. The shell scripts had no
// equivalent: the only check over them was textual
// (TestLinuxScriptFunctionsDoNotEndWithAConditional), so a rendered script that
// bash could not parse would have shipped unnoticed.
//
// This closes that asymmetry at the same place: the rendered output, not the
// template on disk. Templates are assembled per request, so parsing the files
// individually would test a form no host ever receives.
func TestLinuxScriptsParseUnderBash(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash not available; the CI runner for this job has it")
	}

	dir := t.TempDir()
	for name, body := range renderedLinuxScripts(t) {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(dir, name+".sh")
			if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
				t.Fatalf("writing rendered script: %v", err)
			}

			// G204: bash comes from exec.LookPath and path from t.TempDir();
			// neither is caller-supplied.
			out, err := exec.Command(bash, "-n", path).CombinedOutput() //nolint:gosec
			if err != nil {
				t.Errorf("the rendered %s script does not parse under bash -n: %v\n%s", name, err, out)
			}
		})
	}
}

// shellcheck at severity=error over the same rendered output. Advisory: the
// tool is not installed everywhere, and the CI job for this package installs
// it so the check is real there.
func TestLinuxScriptsPassShellcheck(t *testing.T) {
	sc, err := exec.LookPath("shellcheck")
	if err != nil {
		t.Skip("shellcheck not installed")
	}

	dir := t.TempDir()
	for name, body := range renderedLinuxScripts(t) {
		t.Run(name, func(t *testing.T) {
			path := filepath.Join(dir, name+".sh")
			if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
				t.Fatalf("writing rendered script: %v", err)
			}

			// G204: as above -- LookPath binary, TempDir path.
			out, err := exec.Command(sc, "-S", "error", path).CombinedOutput() //nolint:gosec
			if err != nil {
				t.Errorf("the rendered %s script has shellcheck errors: %v\n%s", name, err, out)
			}
		})
	}
}

// renderedLinuxScripts returns every shell script the service serves, keyed by
// name. Guarded against returning an empty map, which would make both tests
// above pass while checking nothing.
func renderedLinuxScripts(t *testing.T) map[string]string {
	t.Helper()

	scripts := map[string]string{
		"installer": renderLinux(t, installerHandlerForTest(), "/cZ1ZhsG", "cZ1ZhsG"),
		"update":    renderLinux(t, &retrieve.UpdateHandler{}, "/update", ""),
		"uninstall": renderLinux(t, &retrieve.UninstallHandler{}, "/uninstall", ""),
	}

	if len(scripts) == 0 {
		t.Fatal("no scripts rendered")
	}
	for name, body := range scripts {
		if body == "" {
			t.Fatalf("the rendered %s script is empty", name)
		}
	}
	return scripts
}

func renderLinux(t *testing.T, h http.Handler, path, pairingCode string) string {
	t.Helper()

	req, _ := http.NewRequest(http.MethodGet, path, nil)
	req.Header.Set("User-Agent", linuxUserAgent)
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
