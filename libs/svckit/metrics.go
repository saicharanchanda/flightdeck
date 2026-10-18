package svckit

import (
	"log/slog"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// DurationBuckets are the http_request_duration_seconds buckets, in seconds.
var DurationBuckets = []float64{.005, .01, .025, .05, .1, .25, .5, 1, 2.5, 5}

// Metrics owns a service's Prometheus registry and its RED collectors.
type Metrics struct {
	Registry *prometheus.Registry
	service  string
	requests *prometheus.CounterVec
	duration *prometheus.HistogramVec
}

// NewMetrics builds a registry with Go runtime, process and HTTP RED metrics.
func NewMetrics(service string) *Metrics {
	m := &Metrics{
		Registry: prometheus.NewRegistry(),
		service:  service,
		requests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "HTTP requests handled, by route and status code.",
		}, []string{"service", "method", "route", "status"}),
		duration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request latency in seconds, by route.",
			Buckets: DurationBuckets,
		}, []string{"service", "method", "route"}),
	}
	m.Registry.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
		m.requests,
		m.duration,
	)
	return m
}

// Handler serves the registry in the Prometheus exposition format.
func (m *Metrics) Handler() http.Handler {
	return promhttp.HandlerFor(m.Registry, promhttp.HandlerOpts{Registry: m.Registry})
}

// Instrument is middleware that records RED metrics and writes one access
// log line per request. It labels by chi route pattern ("/flights/{id}"),
// not raw path, to keep label cardinality bounded.
func Instrument(logger *slog.Logger, m *Metrics) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)
			next.ServeHTTP(ww, r)
			elapsed := time.Since(start)

			status := ww.Status()
			if status == 0 {
				status = http.StatusOK
			}
			route := "unmatched"
			if rctx := chi.RouteContext(r.Context()); rctx != nil {
				if p := rctx.RoutePattern(); p != "" {
					route = p
				}
			}

			m.requests.WithLabelValues(m.service, r.Method, route, strconv.Itoa(status)).Inc()
			m.duration.WithLabelValues(m.service, r.Method, route).Observe(elapsed.Seconds())

			level := slog.LevelInfo
			switch {
			case status >= 500:
				level = slog.LevelError
			case status >= 400:
				level = slog.LevelWarn
			case isProbePath(r.URL.Path):
				level = slog.LevelDebug // probes and scrapes would drown the logs
			}
			logger.LogAttrs(r.Context(), level, "request",
				slog.String("method", r.Method),
				slog.String("route", route),
				slog.String("path", r.URL.Path),
				slog.Int("status", status),
				slog.Float64("duration_ms", DurationMs(elapsed)),
			)
		})
	}
}

// DurationMs converts d to fractional milliseconds for log fields.
func DurationMs(d time.Duration) float64 {
	return float64(d.Microseconds()) / 1000
}

func isProbePath(p string) bool {
	return p == "/healthz" || p == "/readyz" || p == "/metrics"
}
