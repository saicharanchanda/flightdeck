package svckit

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/http"
)

// RequestIDHeader carries the request ID from the gateway to downstream services.
const RequestIDHeader = "X-Request-ID"

const maxRequestIDLen = 128

type requestIDKey struct{}

// NewRequestID returns a random 128-bit hex ID.
func NewRequestID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// WithRequestID returns a copy of ctx carrying id.
func WithRequestID(ctx context.Context, id string) context.Context {
	return context.WithValue(ctx, requestIDKey{}, id)
}

// RequestIDFrom returns the request ID stored in ctx, or "".
func RequestIDFrom(ctx context.Context) string {
	id, _ := ctx.Value(requestIDKey{}).(string)
	return id
}

// RequestID returns middleware that stores a request ID in the context and
// echoes it on the response. With trustIncoming, an X-Request-ID from the
// caller is reused (internal services behind the gateway); without it, a
// fresh ID is always minted (the public edge, where clients could spoof it).
func RequestID(trustIncoming bool) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var id string
			if trustIncoming {
				id = r.Header.Get(RequestIDHeader)
			}
			if id == "" || len(id) > maxRequestIDLen {
				id = NewRequestID()
			}
			w.Header().Set(RequestIDHeader, id)
			next.ServeHTTP(w, r.WithContext(WithRequestID(r.Context(), id)))
		})
	}
}
