package svckit

import (
	"context"
	"log/slog"
	"os"
	"strings"
)

// NewLogger returns a JSON logger on stdout that tags every record with
// the service name and, when the context carries one, the request_id.
// LOG_LEVEL selects the minimum level (debug, info, warn, error).
func NewLogger(service string) *slog.Logger {
	var level slog.Level
	if err := level.UnmarshalText([]byte(strings.ToUpper(Env("LOG_LEVEL", "info")))); err != nil {
		level = slog.LevelInfo
	}
	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level})
	return slog.New(requestIDHandler{h}).With("service", service)
}

// requestIDHandler adds request_id from the context to every record, so
// handlers only need to log with the *Context variants.
type requestIDHandler struct{ slog.Handler }

func (h requestIDHandler) Handle(ctx context.Context, r slog.Record) error {
	if id := RequestIDFrom(ctx); id != "" {
		r.AddAttrs(slog.String("request_id", id))
	}
	return h.Handler.Handle(ctx, r)
}

func (h requestIDHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	return requestIDHandler{h.Handler.WithAttrs(attrs)}
}

func (h requestIDHandler) WithGroup(name string) slog.Handler {
	return requestIDHandler{h.Handler.WithGroup(name)}
}
