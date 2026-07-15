package deposit

import (
	"strings"
	"time"
)

type Deposit struct {
	Code string `mapstructure:"code"`
	// Every field below is interpolated into the generated installer script, so
	// each carries `nocontrol`: no control characters (newlines, CR, NUL, ...),
	// which have no legitimate place in a URL / fingerprint / credential and are
	// the vector for multi-line injection into the shell and sed the installer
	// builds. Shell metacharacters within a single line are additionally
	// neutralized by SanitizeForBash / SanitizeForPowerShell.
	ConnectUrl  string `validate:"required,url,nocontrol" json:"connect_url" mapstructure:"connect_url"`
	Fingerprint string `validate:"required,nocontrol" json:"fingerprint" mapstructure:"fingerprint"`
	ClientId    string `validate:"required,nocontrol" json:"client_id" mapstructure:"client_id"`
	Password    string `validate:"required,nocontrol" json:"password" mapstructure:"password"`
}

type Response struct {
	PairingCode string    `json:"pairing_code"`
	Expires     time.Time `json:"expires"`
	Installers  struct {
		Linux   string `json:"linux"`
		Windows string `json:"windows"`
	} `json:"installers"`
}

func rplForBash(in string) (out string) {
	// Order matters: the backslash must be escaped FIRST, otherwise the
	// backslash inserted while escaping the other metacharacters would itself
	// get doubled. Go's map iteration is unordered, so this list is an explicit
	// slice. The value is interpolated inside a double-quoted assignment, where
	// bash still performs command substitution for backticks and $(...) and
	// parameter expansion for $ — all three must be neutralized, not just $.
	rpl := [][2]string{
		{"\\", "\\\\"},
		{"`", "\\`"},
		{"\"", "\\\""},
		{"$", "\\$"},
	}
	for _, pair := range rpl {
		in = strings.ReplaceAll(in, pair[0], pair[1])
	}
	return in
}
func SanitizeForBash(in Deposit) (out Deposit) {
	return Deposit{
		Code:        rplForBash(in.Code),
		ConnectUrl:  rplForBash(in.ConnectUrl),
		Fingerprint: rplForBash(in.Fingerprint),
		ClientId:    rplForBash(in.ClientId),
		Password:    rplForBash(in.Password),
	}
}

func rplForPowerShell(in string) (out string) {
	// Order matters for the same reason as rplForBash above: the backtick
	// (PowerShell's escape character) must be doubled FIRST so that the
	// backticks inserted while escaping `"` and `$` are not themselves doubled.
	rpl := [][2]string{
		{"`", "``"},
		{"\"", "`\""},
		{"$", "`$"},
	}
	for _, pair := range rpl {
		in = strings.ReplaceAll(in, pair[0], pair[1])
	}
	return in
}
func SanitizeForPowerShell(in Deposit) (out Deposit) {
	return Deposit{
		Code:        rplForPowerShell(in.Code),
		ConnectUrl:  rplForPowerShell(in.ConnectUrl),
		Fingerprint: rplForPowerShell(in.Fingerprint),
		ClientId:    rplForPowerShell(in.ClientId),
		Password:    rplForPowerShell(in.Password),
	}
}
