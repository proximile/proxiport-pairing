package retrieve_test

import (
	"io/fs"
	"os"
	"regexp"
	"strings"
	"testing"
)

// The installer and updater verify the release's checksums.txt with
// `cosign verify-blob --certificate-identity-regexp <re>`. cosign matches that
// expression against the certificate's subject without anchoring it, so an
// expression like 'https://github.com/proximile/proxiport' also accepts a
// certificate issued to any workflow in any repository whose identity merely
// contains that text: a sibling repository with a longer name, or a branch
// build of the right repository. Only the tagged release workflow may sign.
//
// The expected identity is the one the release pipeline actually produces,
// so this pins it exactly rather than checking for "some anchoring".
const wantProxiportIdentity = `^https://github\.com/proximile/proxiport/\.github/workflows/release\.yml@refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$`

var identityFlag = regexp.MustCompile(`--certificate-identity-regexp\s+'([^']*)'`)

func TestCosignIdentityIsAnchoredToTheReleaseWorkflow(t *testing.T) {
	found := 0
	templates := os.DirFS("templates")
	err := fs.WalkDir(templates, ".", func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		b, err := fs.ReadFile(templates, path)
		if err != nil {
			return err
		}
		if strings.Contains(string(b), "--certificate-identity ") {
			t.Errorf("%s: uses --certificate-identity; use the anchored regexp form so every release tag verifies", path)
		}
		for _, m := range identityFlag.FindAllStringSubmatch(string(b), -1) {
			found++
			if m[1] != wantProxiportIdentity {
				t.Errorf("%s: cosign identity %q, want %q", path, m[1], wantProxiportIdentity)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	// install.sh, update.sh and functions.ps1 each verify once.
	if found < 3 {
		t.Fatalf("found %d cosign identity checks in templates, want at least 3", found)
	}
}

// The anchored expression must accept every real release identity and reject
// the near misses an unanchored one lets through.
func TestCosignIdentityExpressionMatchesOnlyTaggedReleases(t *testing.T) {
	re := regexp.MustCompile(wantProxiportIdentity)
	accept := []string{
		"https://github.com/proximile/proxiport/.github/workflows/release.yml@refs/tags/v0.3.0",
		"https://github.com/proximile/proxiport/.github/workflows/release.yml@refs/tags/v12.34.56",
	}
	reject := []string{
		"https://github.com/proximile/proxiport-pairing/.github/workflows/release.yml@refs/tags/v0.7.0",
		"https://github.com/proximile/proxiport/.github/workflows/release.yml@refs/heads/main",
		"https://github.com/proximile/proxiport/.github/workflows/other.yml@refs/tags/v1.0.0",
		"https://github.com/proximile/proxiport/.github/workflows/release.yml@refs/tags/v1.0.0-rc1",
		"https://github.com/someone/fork/.github/workflows/x.yml@refs/heads/https://github.com/proximile/proxiport",
		"https://github.com/proximile/proxiportx/.github/workflows/release.yml@refs/tags/v1.0.0",
	}
	for _, s := range accept {
		if !re.MatchString(s) {
			t.Errorf("rejected a real release identity: %s", s)
		}
	}
	for _, s := range reject {
		if re.MatchString(s) {
			t.Errorf("accepted %s", s)
		}
	}
}
