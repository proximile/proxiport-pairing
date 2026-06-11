package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/gorilla/mux"

	"github.com/proximile/proxiport-pairing/cors"
	"github.com/proximile/proxiport-pairing/deposit"
	"github.com/proximile/proxiport-pairing/internal/cache"
	"github.com/proximile/proxiport-pairing/internal/config"
	"github.com/proximile/proxiport-pairing/retrieve"
)

// Version is filled at link time with -ldflags="-X 'main.Version=N.N.N'".
var Version = "0.0.0-src"

func main() {
	v := false
	flag.BoolVar(&v, "v", false, "version")
	confFile := flag.String("c", "proxiport-pairing.conf", "config file")
	flag.Parse()
	if v {
		fmt.Println("proxiport-pairing", Version)
		os.Exit(0)
	}
	cfg := config.New(*confFile)
	c := cache.New()

	depositHandler := &deposit.Handler{
		Cache:     c,
		ServerUrl: cfg.Server.Url,
	}
	installerHandler := &retrieve.InstallerHandler{
		StaticDeposit: cfg.StaticDeposit,
		Cache:         c,
	}
	updateHandler := &retrieve.UpdateHandler{
		StaticDeposit: cfg.StaticDeposit,
	}
	corsHandler := &cors.Handler{}

	r := mux.NewRouter()
	r.PathPrefix("/").Methods("OPTIONS").Handler(corsHandler)
	r.Path("/").Methods("POST").Handler(depositHandler)
	r.Path("/update").Methods("GET").Handler(updateHandler)
	r.Path("/{pairingCode:[0-9 a-z A-Z]{7}}").Methods("GET").Handler(installerHandler)

	log.Println("proxiport-pairing", Version, "listening on", cfg.Server.Address)
	srv := &http.Server{
		Addr:              cfg.Server.Address,
		Handler:           r,
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
	log.Fatal(srv.ListenAndServe())
}
