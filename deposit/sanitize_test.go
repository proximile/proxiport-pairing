package deposit_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/proximile/proxiport-pairing/deposit"
	"github.com/proximile/proxiport-pairing/internal/cache"
)

// The value is interpolated inside a double-quoted shell assignment, where
// bash still runs command substitution for backticks and $(...) — both must be
// escaped, not just $.
func TestSanitizeForBashNeutralizesCommandSubstitution(t *testing.T) {
	in := deposit.Deposit{
		ClientId: "id`whoami`",
		Password: `p$(id)a"b\c`,
	}
	out := deposit.SanitizeForBash(in)

	// Every backtick and dollar is backslash-escaped, so neither command
	// substitution (`...` / $(...)) nor parameter expansion can fire inside the
	// double-quoted assignment.
	assert.Equal(t, "id\\`whoami\\`", out.ClientId)
	assert.Equal(t, `p\$(id)a\"b\\c`, out.Password)
}

// A control character (here a newline) in any interpolated field is rejected at
// deposit time — it is the vector for multi-line injection into the generated
// installer and never appears in a real credential.
func TestDepositRejectsControlCharacters(t *testing.T) {
	for _, field := range []string{"password", "client_id", "fingerprint", "connect_url"} {
		fields := map[string]string{
			"password":    "foobaz",
			"connect_url": "https://proxiport.example.com",
			"fingerprint": "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU",
			"client_id":   "client1",
		}
		fields[field] = fields[field] + "\ninjected line"
		payload, _ := json.Marshal(fields)
		req, _ := http.NewRequest(http.MethodPost, "/", bytes.NewReader(payload))
		req.Header.Set("Content-Type", "application/json")

		rec := httptest.NewRecorder()
		(&deposit.Handler{Cache: cache.New()}).ServeHTTP(rec, req)

		assert.Equalf(t, http.StatusBadRequest, rec.Result().StatusCode,
			"a newline in %q must be rejected; body=%s", field, rec.Body.String())
	}
}

// A SHA-256 fingerprint (longer than the old MD5 47-char form) is accepted.
func TestDepositAcceptsSHA256Fingerprint(t *testing.T) {
	fields := map[string]string{
		"password":    "foobaz",
		"connect_url": "https://proxiport.example.com",
		"fingerprint": "SHA256:47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU",
		"client_id":   "client1",
	}
	payload, _ := json.Marshal(fields)
	req, _ := http.NewRequest(http.MethodPost, "/", bytes.NewReader(payload))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	(&deposit.Handler{Cache: cache.New()}).ServeHTTP(rec, req)

	assert.Equal(t, http.StatusOK, rec.Result().StatusCode, strings.TrimSpace(rec.Body.String()))
}
