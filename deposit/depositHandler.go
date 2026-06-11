package deposit

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/go-playground/validator/v10"
	"github.com/iancoleman/strcase"
	gonanoid "github.com/matoous/go-nanoid/v2"
	"github.com/patrickmn/go-cache"
)

var validate *validator.Validate

const alphabet = "abcdefghijklmnpqrstuvwyxzABCDEFGHIJKLMNPQRSTUVWXYZ123456789" // Chars used to generate the code
const ttl = 300 * time.Second                                                  // Cache items aka pairing code lifetime
const formMaxMem = 256                                                         // Maximum memory bytes used to load form contents for parsing
const maxBodyBytes = 64 << 10                                                  // Hard cap on the request body; deposits are a handful of short fields

type Handler struct {
	Cache     *cache.Cache
	ServerUrl string
}

func (dh *Handler) ServeHTTP(rw http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(rw, r.Body, maxBodyBytes)
	deposit := &Deposit{}
	if strings.HasPrefix(r.Header.Get("Content-Type"), "application/json") {
		err := json.NewDecoder(r.Body).Decode(&deposit)
		if err != nil {
			http.Error(rw, err.Error(), http.StatusBadRequest)
			return
		}
	} else {
		// #nosec G120 -- r.Body is wrapped with http.MaxBytesReader at the
		// top of ServeHTTP, so the parse is bounded to maxBodyBytes.
		err := r.ParseMultipartForm(formMaxMem)
		if err != nil {
			log.Printf("Error %v\n", err)
			rw.WriteHeader(http.StatusNotAcceptable)
			return
		}
		deposit.ClientId = r.FormValue("client_id")
		deposit.ConnectUrl = r.FormValue("connect_url")
		deposit.Fingerprint = r.FormValue("fingerprint")
		deposit.Password = r.FormValue("password")
	}
	_, err := validateInput(deposit)
	if err != nil {
		rw.WriteHeader(http.StatusBadRequest)
		_, _ = fmt.Fprintln(rw, "input validation failed: ", err)
		return
	}

	response, err := dh.store(deposit)
	if err != nil {
		log.Println("Cache error: ", err)
		return
	}
	if jresponse, err := json.Marshal(response); err != nil {
		log.Println("Json error: ", err)
	} else {
		rw.Header().Set("Access-Control-Allow-Origin", "*")
		rw.Header().Set("Content-Type", "application/json")
		if _, err := rw.Write(jresponse); err != nil {
			log.Println("Error ", err)
		}
	}
}

func validateInput(deposit *Deposit) (bool, error) {
	validate = validator.New()
	err := validate.Struct(deposit)
	if err == nil {
		return true, nil
	}

	// this check is only needed when your code could produce
	// an invalid value for validation such as interface with nil
	// value most including myself do not usually have code like this.
	if _, ok := err.(*validator.InvalidValidationError); ok {
		return false, fmt.Errorf("validation failed: %s", err)
	}
	var msg string
	for _, err := range err.(validator.ValidationErrors) {
		msg += fmt.Sprintf("'%s' does not meet the specification '%s'\n", strcase.ToSnake(err.Field()), err.Tag())
	}
	return false, errors.New(msg)
}

func (dh *Handler) store(deposit *Deposit) (*Response, error) {
	id, err := gonanoid.Generate(alphabet, 7)
	if err != nil {
		return &Response{}, err
	}

	dh.Cache.Set(id, *deposit, ttl)
	response := &Response{
		PairingCode: id,
	}
	response.Expires = time.Now().UTC().Add(ttl)
	response.Installers.Linux = fmt.Sprintf(`curl %s/%s > proxiport-installer.sh
sudo sh proxiport-installer.sh`, dh.ServerUrl, id)
	response.Installers.Windows = fmt.Sprintf(`[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$url="%s/%s"
Invoke-WebRequest -Uri $url -OutFile "proxiport-installer.ps1"
powershell -ExecutionPolicy Bypass -File .\proxiport-installer.ps1`, dh.ServerUrl, id)
	return response, nil
}
