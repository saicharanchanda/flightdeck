package svckit

import (
	"log/slog"
	"math"
	"math/rand/v2"
	"net/http"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/go-chi/chi/v5"
)

const maxChaosLatencyMs = 30_000

// Chaos holds injected latency and error rate. When disabled, its
// middleware is a no-op and no /chaos routes are mounted.
type Chaos struct {
	enabled   bool
	logger    *slog.Logger
	latencyMs atomic.Int64
	errorRate atomic.Uint64 // float64 bits
}

// NewChaos returns chaos state; enabled normally comes from CHAOS_ENABLED.
func NewChaos(enabled bool, logger *slog.Logger) *Chaos {
	return &Chaos{enabled: enabled, logger: logger}
}

// Enabled reports whether chaos injection is switched on.
func (c *Chaos) Enabled() bool { return c.enabled }

// Latency returns the currently injected delay.
func (c *Chaos) Latency() time.Duration {
	return time.Duration(c.latencyMs.Load()) * time.Millisecond
}

// ErrorRate returns the fraction of requests that should fail.
func (c *Chaos) ErrorRate() float64 {
	return math.Float64frombits(c.errorRate.Load())
}

// ShouldFail rolls the dice against the current error rate.
func (c *Chaos) ShouldFail() bool {
	rate := c.ErrorRate()
	return rate > 0 && rand.Float64() < rate
}

// Middleware applies injected latency and errors to every request except
// the chaos controls themselves and the probe/scrape endpoints, so a chaos
// experiment degrades the API without making Kubernetes kill the pod.
func (c *Chaos) Middleware(next http.Handler) http.Handler {
	if !c.enabled {
		return next
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if isProbePath(r.URL.Path) || strings.HasPrefix(r.URL.Path, "/chaos/") {
			next.ServeHTTP(w, r)
			return
		}
		if d := c.Latency(); d > 0 {
			t := time.NewTimer(d)
			select {
			case <-t.C:
			case <-r.Context().Done():
				t.Stop()
				return
			}
		}
		if c.ShouldFail() {
			WriteError(w, http.StatusInternalServerError, "chaos: injected failure")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// Mount registers GET /chaos/latency, /chaos/errors and /chaos/reset
// when chaos is enabled.
func (c *Chaos) Mount(r chi.Router) {
	if !c.enabled {
		return
	}
	r.Get("/chaos/latency", func(w http.ResponseWriter, r *http.Request) {
		ms, err := strconv.ParseInt(r.URL.Query().Get("ms"), 10, 64)
		if err != nil || ms < 0 || ms > maxChaosLatencyMs {
			WriteError(w, http.StatusBadRequest, "ms must be an integer between 0 and 30000")
			return
		}
		c.latencyMs.Store(ms)
		c.logger.WarnContext(r.Context(), "chaos latency set", "latency_ms", ms)
		c.writeState(w)
	})
	r.Get("/chaos/errors", func(w http.ResponseWriter, r *http.Request) {
		rate, err := strconv.ParseFloat(r.URL.Query().Get("rate"), 64)
		if err != nil || math.IsNaN(rate) || rate < 0 || rate > 1 {
			WriteError(w, http.StatusBadRequest, "rate must be a number between 0 and 1")
			return
		}
		c.errorRate.Store(math.Float64bits(rate))
		c.logger.WarnContext(r.Context(), "chaos error rate set", "error_rate", rate)
		c.writeState(w)
	})
	r.Get("/chaos/reset", func(w http.ResponseWriter, r *http.Request) {
		c.latencyMs.Store(0)
		c.errorRate.Store(0)
		c.logger.InfoContext(r.Context(), "chaos reset")
		c.writeState(w)
	})
}

func (c *Chaos) writeState(w http.ResponseWriter) {
	WriteJSON(w, http.StatusOK, map[string]any{
		"latency_ms": c.latencyMs.Load(),
		"error_rate": c.ErrorRate(),
	})
}
