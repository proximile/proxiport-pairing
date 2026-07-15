package cors_test

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/assert"

	"github.com/proximile/proxiport-pairing/cors"
)

func TestHandler_DefaultNoCORS(t *testing.T) {
	request, _ := http.NewRequest(http.MethodOptions, "/", nil)
	corsHandler := cors.Handler{} // AllowOrigin unset

	recorder := httptest.NewRecorder()
	corsHandler.ServeHTTP(recorder, request)
	assert.Equal(t, 204, recorder.Result().StatusCode)
	// No wildcard (or any) Access-Control-Allow-Origin by default.
	assert.Empty(t, recorder.Result().Header.Get("Access-Control-Allow-Origin"))
}

func TestHandler_ConfiguredOrigin(t *testing.T) {
	request, _ := http.NewRequest(http.MethodOptions, "/", nil)
	corsHandler := cors.Handler{AllowOrigin: "https://app.example.com"}

	recorder := httptest.NewRecorder()
	corsHandler.ServeHTTP(recorder, request)
	assert.Equal(t, 204, recorder.Result().StatusCode)
	assert.Equal(t, "https://app.example.com", recorder.Result().Header.Get("Access-Control-Allow-Origin"))
	assert.Contains(t, recorder.Result().Header.Get("Access-Control-Allow-Methods"), "POST, GET, OPTIONS")
	assert.Contains(t,
		recorder.Result().Header.Get("Access-Control-Allow-Headers"),
		"Content-Type, Access-Control-Allow-Headers, Authorization, X-Requested-With",
	)
}
