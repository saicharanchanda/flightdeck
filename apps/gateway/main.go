// Command gateway is flightdeck's public HTTP API. It proxies flight reads
// to the flights service and queues subscription jobs on Redis.
package main

import (
	"context"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/redis/go-redis/v9"

	"flightdeck/libs/svckit"
)

const service = "gateway"

func main() {
	logger := svckit.NewLogger(service)

	rdb := redis.NewClient(&redis.Options{
		Addr:     svckit.Env("REDIS_ADDR", "localhost:6379"),
		Password: os.Getenv("REDIS_PASSWORD"),
		DB:       svckit.EnvInt("REDIS_DB", 0),
	})
	defer rdb.Close()

	h := &handlers{
		logger:     logger,
		flightsURL: svckit.Env("FLIGHTS_URL", "http://localhost:8081"),
		client:     &http.Client{Timeout: svckit.EnvDuration("UPSTREAM_TIMEOUT", 5*time.Second)},
		rdb:        rdb,
		queue:      svckit.Env("NOTIFICATIONS_QUEUE", svckit.DefaultQueue),
	}

	health := &svckit.Health{}
	health.AddCheck("redis", func(ctx context.Context) error { return rdb.Ping(ctx).Err() })

	chaos := svckit.NewChaos(svckit.EnvBool("CHAOS_ENABLED", false), logger)
	// Public edge: always mint the request ID rather than trusting clients.
	r := svckit.NewRouter(logger, svckit.NewMetrics(service), chaos, health, false)
	r.Get("/api/flights", h.listFlights)
	r.Get("/api/flights/{id}", h.getFlight)
	r.Post("/api/flights/{id}/subscribe", h.subscribe)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	logger.Info("starting", "flights_url", h.flightsURL, "queue", h.queue, "chaos_enabled", chaos.Enabled())
	srv := svckit.NewServer(svckit.Env("HTTP_ADDR", ":8080"), r)
	if err := svckit.Serve(ctx, logger, srv, health); err != nil {
		logger.Error("server failed", "err", err)
		os.Exit(1)
	}
}
