package config

import (
	"fmt"
	"log"
	"path/filepath"

	"github.com/proximile/proxiport-pairing/deposit"
	"github.com/spf13/viper"
)

type Config struct {
	Server struct {
		Address string `mapstructure:"address"`
		Url     string `mapstructure:"url"`
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
		panic(fmt.Errorf("Fatal error: %w \n", err))
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
