package svckit

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"sync/atomic"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
)

// ShutdownTimeout is how long in-flight work gets to drain after SIGTERM.
const ShutdownTimeout = 10 * time.Second

const readyCheckTimeout = 2 * time.Second

// Health serves the liveness and readiness probes.
type Health struct {
	draining atomic.Bool
	checks   []namedCheck
}

type namedCheck struct {
	name string
	fn   func(context.Context) error
}

// AddCheck registers a dependency check that /readyz must pass.
func (h *Health) AddCheck(name string, fn func(context.Context) error) {
	h.checks = append(h.checks, namedCheck{name, fn})
}

// Live always answers 200 while the process is serving.
func (h *Health) Live(w http.ResponseWriter, _ *http.Request) {
	WriteJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

// Ready answers 503 while draining or when any dependency check fails.
func (h *Health) Ready(w http.ResponseWriter, r *http.Request) {
	if h.draining.Load() {
		WriteJSON(w, http.StatusServiceUnavailable, map[string]string{"status": "draining"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), readyCheckTimeout)
	defer cancel()
	failed := map[string]string{}
	for _, c := range h.checks {
		if err := c.fn(ctx); err != nil {
			failed[c.name] = err.Error()
		}
	}
	if len(failed) > 0 {
		WriteJSON(w, http.StatusServiceUnavailable, map[string]any{"status": "unavailable", "failed": failed})
		return
	}
	WriteJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

// NewRouter returns a chi router with the shared middleware stack and the
// /healthz, /readyz, /metrics and (if enabled) /chaos/* routes mounted.
// trustRequestID selects whether an incoming X-Request-ID is reused.
func NewRouter(logger *slog.Logger, m *Metrics, chaos *Chaos, health *Health, trustRequestID bool) chi.Router {
	r := chi.NewRouter()
	r.Use(RequestID(trustRequestID), Instrument(logger, m), middleware.Recoverer, chaos.Middleware)
	r.Get("/healthz", health.Live)
	r.Get("/readyz", health.Ready)
	r.Method(http.MethodGet, "/metrics", m.Handler())
	chaos.Mount(r)
	return r
}

// NewServer returns an http.Server with defensive timeouts. WriteTimeout
// leaves room for the 30s maximum chaos latency.
func NewServer(addr string, h http.Handler) *http.Server {
	return &http.Server{
		Addr:              addr,
		Handler:           h,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      45 * time.Second,
		IdleTimeout:       120 * time.Second,
	}
}

// Serve runs srv until ctx is cancelled, then marks the service not-ready
// and drains in-flight requests for up to ShutdownTimeout.
func Serve(ctx context.Context, logger *slog.Logger, srv *http.Server, health *Health) error {
	errCh := make(chan error, 1)
	go func() {
		logger.Info("http server listening", "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			errCh <- err
		}
	}()

	select {
	case err := <-errCh:
		return fmt.Errorf("http server: %w", err)
	case <-ctx.Done():
	}

	health.draining.Store(true)
	logger.Info("shutdown started", "drain_timeout", ShutdownTimeout.String())
	sctx, cancel := context.WithTimeout(context.Background(), ShutdownTimeout)
	defer cancel()
	if err := srv.Shutdown(sctx); err != nil {
		return fmt.Errorf("http shutdown: %w", err)
	}
	logger.Info("http server stopped")
	return nil
}

// WriteJSON writes v as a JSON response with the given status.
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// WriteError writes {"error": msg} with the given status.
func WriteError(w http.ResponseWriter, status int, msg string) {
	WriteJSON(w, status, map[string]string{"error": msg})
}
