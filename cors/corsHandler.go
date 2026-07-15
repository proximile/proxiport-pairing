package cors

import "net/http"

// Handler answers CORS preflight (OPTIONS) requests. The deposit and retrieve
// endpoints are not browser-origin surfaces, so cross-origin access is off by
// default: AllowOrigin is empty and no Access-Control-Allow-Origin header is
// emitted. An operator who genuinely fronts these with a browser app can set a
// specific origin (never "*") via config.
type Handler struct {
	AllowOrigin string
}

func (ch *Handler) ServeHTTP(rw http.ResponseWriter, r *http.Request) {
	if ch.AllowOrigin != "" {
		rw.Header().Set("Access-Control-Allow-Origin", ch.AllowOrigin)
		rw.Header().Set("Access-Control-Allow-Methods", "POST, GET, OPTIONS")
		rw.Header().Set("Access-Control-Max-Age", "3600")
		rw.Header().Set("Access-Control-Allow-Headers", "Content-Type, Access-Control-Allow-Headers, Authorization, X-Requested-With")
	}
	rw.WriteHeader(http.StatusNoContent)
}
