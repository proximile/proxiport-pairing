package retrieve_test

import (
	"os/exec"
	"strings"
	"testing"
)

// The -o / -e switches put an operator-typed string into two places that
// cannot be escaped after the fact: the agent's TOML config and a curl
// command line. add_egress is the one gate in front of both, so it is driven
// here with the inputs it must refuse, under the shell that runs it.
//
// The functions are lifted out of the rendered installer, not the template,
// and executed under bash with abort() replaced by a stub that reports and
// exits -- the real one deletes the temp folder and exits the installer.
func TestLinuxInstallerEgressParsing(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash not available; the CI runner for this job has it")
	}

	installer := renderLinuxInstaller(t)
	prelude := "abort() { echo \"ABORT: $1\"; exit 1; }\nEGRESS=\"\"\n"
	for _, fn := range []string{"add_egress", "egress_toml_list", "curl_proxy_url", "go_proxy_url", "is_onion_url"} {
		prelude += shellFunction(t, installer, fn)
	}

	run := func(t *testing.T, script string) (string, int) {
		t.Helper()
		// G204: bash comes from exec.LookPath; the script is test-authored.
		out, err := exec.Command(bash, "-c", prelude+script).CombinedOutput() //nolint:gosec
		code := 0
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		} else if err != nil {
			t.Fatalf("running bash: %v\n%s", err, out)
		}
		return strings.TrimSpace(string(out)), code
	}

	t.Run("accepts the documented shapes, in the order given", func(t *testing.T) {
		out, code := run(t, `add_egress socks5h://gluetun:1080; add_egress socks://127.0.0.1:9050; add_egress http://proxy.example:3128; add_egress direct; echo "$EGRESS"; egress_toml_list`)
		if code != 0 {
			t.Fatalf("exit %d: %s", code, out)
		}
		want := "socks5h://gluetun:1080 socks://127.0.0.1:9050 http://proxy.example:3128 direct\n" +
			`["socks5h://gluetun:1080", "socks://127.0.0.1:9050", "http://proxy.example:3128", "direct"]`
		if out != want {
			t.Errorf("got\n%s\nwant\n%s", out, want)
		}
	})

	refused := []struct{ name, script, reason string }{
		{"direct before a proxy", `add_egress direct; add_egress socks5h://h:1`, "must be the last"},
		{"https proxy", `add_egress https://h:1`, "https:// proxies are not supported"},
		{"unknown scheme", `add_egress ftp://h:1`, "neither 'direct' nor"},
		{"bare word", `add_egress tor`, "neither 'direct' nor"},
		{"whitespace", `add_egress 'socks5h://h:1 direct'`, "whitespace, a quote or a backslash"},
		{"double quote", `add_egress 'socks5h://h:1"'`, "whitespace, a quote or a backslash"},
		{"backslash", `add_egress 'socks5h://h\1'`, "whitespace, a quote or a backslash"},
		{"no host", `add_egress socks5h://`, "has no host"},
		{"duplicate", `add_egress socks5h://h:1; add_egress socks5h://h:1`, "listed twice"},
	}
	for _, tc := range refused {
		t.Run("refuses "+tc.name, func(t *testing.T) {
			out, code := run(t, tc.script+`; echo "EGRESS=$EGRESS"`)
			if code == 0 {
				t.Fatalf("accepted; EGRESS now %q", out)
			}
			if !strings.Contains(out, "ABORT: ") || !strings.Contains(out, tc.reason) {
				t.Errorf("refused for the wrong reason: %s", out)
			}
		})
	}

	t.Run("curl and Go get the spelling that hands the hostname to the proxy", func(t *testing.T) {
		out, code := run(t, `for e in socks://h:1 socks5://h:1 socks5h://h:1 http://h:1; do echo "$(curl_proxy_url "$e") $(go_proxy_url "$e")"; done`)
		if code != 0 {
			t.Fatalf("exit %d: %s", code, out)
		}
		want := "socks5h://h:1 socks5://h:1\nsocks5h://h:1 socks5://h:1\nsocks5h://h:1 socks5://h:1\nhttp://h:1 http://h:1"
		if out != want {
			t.Errorf("got\n%s\nwant\n%s", out, want)
		}
	})

	t.Run("recognizes an onion service by its host alone", func(t *testing.T) {
		cases := map[string]bool{
			"http://pairingtest2b7xq3uvabcdefghijklmnopqrstuvwxyz234567abcdefghijk.onion:80": true,
			"https://example.onion":             true,
			"http://example.onion/path:80":      true,
			"http://onion.example.com:80":       false,
			"http://example.com/x.onion":        false,
			"http://[::1]:80":                   false,
			"https://proxiport.example.com:443": false,
		}
		for url, want := range cases {
			out, code := run(t, `if is_onion_url "`+url+`"; then echo yes; else echo no; fi`)
			got := out == "yes"
			if code != 0 || got != want {
				t.Errorf("%s: got %q (exit %d), want onion=%v", url, out, code, want)
			}
		}
	})
}

// shellFunction returns the lines of `name() {` through the first line that is
// exactly `}` after it, as they appear in the rendered script.
func shellFunction(t *testing.T, script, name string) string {
	t.Helper()
	lines := strings.Split(script, "\n")
	for i, line := range lines {
		if strings.TrimRight(line, " \t") != name+"() {" {
			continue
		}
		for j := i + 1; j < len(lines); j++ {
			if strings.TrimRight(lines[j], " \t") == "}" {
				return strings.Join(lines[i:j+1], "\n") + "\n"
			}
		}
	}
	t.Fatalf("function %s not found in the rendered installer", name)
	return ""
}
