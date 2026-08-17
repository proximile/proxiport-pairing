package config

import (
	"fmt"
	"log"
	"path/filepath"

	"github.com/spf13/viper"

	"github.com/proximile/proxiport-pairing/deposit"
)

type Config struct {
	Server struct {
		Address string `mapstructure:"address"`
		Url     string `mapstructure:"url"`
		// CorsAllowOrigin, when set, is the single origin allowed to make
		// cross-origin requests to the deposit/retrieve endpoints. Empty by
		// default (no CORS). Never set this to "*".
		CorsAllowOrigin string `mapstructure:"cors_allow_origin"`
		// DepositAuthToken, when non-empty, is a shared secret the depositor
		// (the ProxiPort server) must present on POST / as an
		// "Authorization: Bearer <token>" header. Empty by default: deposits
		// are unauthenticated, preserving existing behavior.
		DepositAuthToken string `mapstructure:"deposit_auth_token"`
		// TrustedProxies lists reverse-proxy CIDRs (or bare IPs) whose
		// X-Forwarded-For / X-Real-IP headers may be trusted when deriving the
		// per-client rate-limit key. Empty by default: only the direct peer
		// address is used.
		TrustedProxies []string `mapstructure:"trusted_proxies"`
	} `mapstructure:"server"`
	StaticDeposit deposit.Deposit `mapstructure:"static-deposit"`
}

func New(confFile string) *Config {
	viper.SetConfigType("toml")
	if filepath.IsAbs(confFile) {
		viper.SetConfigFile(confFile)
	} else {
		viper.SetConfigName(confFile)
		viper.AddConfigPath("/etc/proxiport/")
		viper.AddConfigPath("$HOME/.proxiport")
		viper.AddConfigPath(".")
	}
	err := viper.ReadInConfig()
	if err != nil {
		panic(fmt.Errorf("fatal error reading config: %w", err))
	}
	viper.SetDefault("server.address", "127.0.0.1:8080")
	viper.SetDefault("server.url", "https://pairing.example.com")
	var config Config
	err = viper.Unmarshal(&config)
	if err != nil {
		log.Fatalf("unable to decode into struct, %v", err)
	}
	//config := Config{}
	//config.Server.Address = viper.GetString("server.address")
	//config.Server.Url = viper.GetString("server.url")
	//config.StaticDeposit.ConnectUrl = viper.GetString("static-deposit.connect_url")
	//config.StaticDeposit.Fingerprint = viper.GetString("static-deposit.fingerprint")
	//config.StaticDeposit.ClientId = viper.GetString("static-deposit.client_id")
	//config.StaticDeposit.Password = viper.GetString("static-deposit.password")
	//config.DummyCode = viper.GetString("static-deposit.code")
	return &config
}
