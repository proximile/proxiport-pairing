package retrieve_test

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// verify_checksums_signature is the only thing between a substituted release
// and a root-run install. These run it under bash, lifted out of the rendered
// installer, with stub curl and cosign executables:
//
//   - an installed cosign is used, with the release signer pinned;
//   - without one, a cosign is downloaded, accepted only if it matches the
//     pinned hash, run, and deleted;
//   - when none can be had the check fails unless -k (ALLOW_NO_COSIGN=1)
//     was given;
//   - a download that doesn't match the pinned hash fails even with -k.
func TestLinuxReleaseSignatureCheck(t *testing.T) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash not available; the CI runner for this job has it")
	}
	installer := renderLinuxInstaller(t)

	prelude := "throw_warning() { echo \"WARNING: $1\"; }\nEGRESS_PROXY=\"\"\nEGRESS_PROXY_ENV=\"\"\n"
	for _, v := range []string{"COSIGN_VERSION", "RELEASE_SIGNER"} {
		m := regexp.MustCompile(`(?m)^` + v + `=.*$`).FindString(installer)
		if m == "" {
			t.Fatalf("%s is not set in the rendered installer", v)
		}
		prelude += m + "\n"
	}
	for _, fn := range []string{"is_available", "egress_curl", "cosign_release_asset", "sha256_of", "fetch_cosign", "verify_checksums_signature"} {
		prelude += shellFunction(t, installer, fn)
	}

	// The stand-in for cosign records its arguments and exits with
	// $COSIGN_EXIT. Its bytes are what the stub curl "downloads".
	fakeCosign := "#!/bin/sh\necho \"$@\" > \"$ARGS_FILE\"\nexit \"${COSIGN_EXIT:-0}\"\n"
	sum := sha256.Sum256([]byte(fakeCosign))
	fakeSum := hex.EncodeToString(sum[:])

	type env struct {
		installed bool   // a cosign on PATH
		download  string // "ok", "fail" or "wrong"
		arch      string // "known" or "unknown"
		allowNo   bool   // -k
		cosignBad bool   // cosign reports a bad signature
	}
	run := func(t *testing.T, e env) (out string, code int, args string, leftovers []string) {
		t.Helper()
		dir := t.TempDir()
		bin := filepath.Join(dir, "bin")
		tmp := filepath.Join(dir, "tmp")
		for _, d := range []string{bin, tmp} {
			if err := os.Mkdir(d, 0o750); err != nil {
				t.Fatal(err)
			}
		}
		write := func(name, body string) {
			if err := os.WriteFile(filepath.Join(bin, name), []byte(body), 0o755); err != nil { //nolint:gosec // test stubs must be executable
				t.Fatal(err)
			}
		}
		if e.installed {
			write("cosign", fakeCosign)
		}
		// curl -fLSs URL -o FILE
		body := map[string]string{"ok": fakeCosign, "wrong": "not cosign\n"}[e.download]
		if e.download == "fail" {
			write("curl", "#!/bin/sh\nexit 22\n")
		} else {
			if err := os.WriteFile(filepath.Join(dir, "payload"), []byte(body), 0o600); err != nil {
				t.Fatal(err)
			}
			write("curl", "#!/bin/sh\nwhile [ $# -gt 1 ]; do [ \"$1\" = -o ] && cp \""+filepath.Join(dir, "payload")+"\" \"$2\"; shift; done\n")
		}
		script := prelude
		if e.arch == "known" {
			script += "cosign_release_asset() { echo \"cosign-linux-test " + fakeSum + "\"; }\n"
		} else {
			script += "cosign_release_asset() { return 1; }\n"
		}
		allow := "0"
		if e.allowNo {
			allow = "1"
		}
		cosignExit := "0"
		if e.cosignBad {
			cosignExit = "1"
		}
		script += "set -e\nverify_checksums_signature sums sig pem\n"
		argsFile := filepath.Join(dir, "args")
		cmd := exec.Command(bash, "-c", script) //nolint:gosec // bash from LookPath; script is test-authored
		cmd.Env = []string{
			"PATH=" + bin + ":/usr/bin:/bin",
			"PROXIPORT_COSIGN_TMPDIR=" + tmp,
			"ALLOW_NO_COSIGN=" + allow,
			"COSIGN_EXIT=" + cosignExit,
			"ARGS_FILE=" + argsFile,
		}
		b, err := cmd.CombinedOutput()
		if ee, ok := err.(*exec.ExitError); ok {
			code = ee.ExitCode()
		} else if err != nil {
			t.Fatalf("running bash: %v\n%s", err, b)
		}
		a, _ := os.ReadFile(argsFile) //nolint:gosec // a path under t.TempDir()
		entries, _ := os.ReadDir(tmp)
		for _, en := range entries {
			leftovers = append(leftovers, en.Name())
		}
		return string(b), code, string(a), leftovers
	}

	t.Run("an installed cosign checks the pinned signer", func(t *testing.T) {
		out, code, args, _ := run(t, env{installed: true, download: "fail", arch: "known"})
		if code != 0 {
			t.Fatalf("exit %d: %s", code, out)
		}
		if !strings.Contains(args, "--certificate-identity-regexp "+wantProxiportIdentity+" ") {
			t.Errorf("cosign called with %q", args)
		}
	})

	t.Run("a bad signature fails, with -k too", func(t *testing.T) {
		out, code, _, _ := run(t, env{installed: true, download: "fail", arch: "known", allowNo: true, cosignBad: true})
		if code == 0 {
			t.Fatalf("accepted: %s", out)
		}
	})

	t.Run("without cosign, a pinned download is used and deleted", func(t *testing.T) {
		out, code, args, left := run(t, env{download: "ok", arch: "known"})
		if code != 0 {
			t.Fatalf("exit %d: %s", code, out)
		}
		if !strings.Contains(args, wantProxiportIdentity) {
			t.Errorf("the downloaded cosign was not run with the signer: %q", args)
		}
		if len(left) != 0 {
			t.Errorf("left behind in the temp dir: %v", left)
		}
	})

	t.Run("a bad signature from a downloaded cosign fails and cleans up", func(t *testing.T) {
		out, code, _, left := run(t, env{download: "ok", arch: "known", cosignBad: true})
		if code == 0 {
			t.Fatalf("accepted: %s", out)
		}
		if len(left) != 0 {
			t.Errorf("left behind in the temp dir: %v", left)
		}
	})

	t.Run("a download that doesn't match the pinned hash fails, with -k too", func(t *testing.T) {
		out, code, args, left := run(t, env{download: "wrong", arch: "known", allowNo: true})
		if code == 0 {
			t.Fatalf("accepted: %s", out)
		}
		if args != "" {
			t.Errorf("ran the mismatched download: %q", args)
		}
		if !strings.Contains(out, "does not match its pinned SHA-256") {
			t.Errorf("unexpected message: %s", out)
		}
		if len(left) != 0 {
			t.Errorf("left behind in the temp dir: %v", left)
		}
	})

	for _, tc := range []struct {
		name string
		e    env
	}{
		{"no build for this CPU", env{download: "ok", arch: "unknown"}},
		{"the download fails", env{download: "fail", arch: "known"}},
	} {
		t.Run(tc.name+": stops without -k", func(t *testing.T) {
			out, code, _, _ := run(t, tc.e)
			if code == 0 {
				t.Fatalf("accepted: %s", out)
			}
			if !strings.Contains(out, "rerun with -k") {
				t.Errorf("doesn't say how to go on: %s", out)
			}
		})
		t.Run(tc.name+": goes on with -k, with a warning", func(t *testing.T) {
			e := tc.e
			e.allowNo = true
			out, code, _, _ := run(t, e)
			if code != 0 {
				t.Fatalf("exit %d: %s", code, out)
			}
			if !strings.Contains(out, "NOT verified") {
				t.Errorf("no warning: %s", out)
			}
		})
	}
}

// The pinned hashes must be the published ones for the pinned version. They
// were copied from that release's cosign_checksums.txt; this guards against a
// later edit changing one hash or the version without the others.
func TestPinnedCosignTable(t *testing.T) {
	installer := renderLinuxInstaller(t)
	if !strings.Contains(installer, `COSIGN_VERSION="v3.1.4"`) {
		t.Fatal("cosign version changed: update the pinned hashes from that release's cosign_checksums.txt, then this test")
	}
	want := map[string]string{
		"cosign-linux-amd64":   "424e2c97d0b45fd7a6b608a87f090f35633f4c23ece5f092d48bba11aaf4bbfa",
		"cosign-linux-arm64":   "ade83b7aac62e131cacfe96d958948b2150cc9efec46a570a2649b8e27dedad2",
		"cosign-linux-arm":     "09e77a313910cf5c4774508d85d017d9c60983f41bf657f83ecbd3892f7952cb",
		"cosign-linux-ppc64le": "0887fca23319ea017cc827e6a845ba83722a36bf9e932f35c747ca83c14cec49",
		"cosign-linux-riscv64": "24f3865df0fd9b055827b888d56e13583112ac7d4c87b45967af1f0febf35455",
		"cosign-linux-s390x":   "777978d576af893a3daf1fcf3b0e9178cebcbc083a669f6125b6c97b8e1fe433",
	}
	for asset, sum := range want {
		if !strings.Contains(installer, `"`+asset+` `+sum+`"`) {
			t.Errorf("%s: pinned hash missing or changed", asset)
		}
	}
	ps, err := os.ReadFile("templates/windows/functions.ps1")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(ps), "cbe953787074611f1334cbf37dc1cf953995bb8c45398eb4fc7bb781d29c1f2a") ||
		!strings.Contains(string(ps), "'v3.1.4'") {
		t.Error("Windows cosign pin missing or out of step with the Linux one")
	}
}
