// Command notifier consumes subscription jobs from a Redis list and
// simulates delivering them. Its only HTTP surface is an admin port for
// probes, metrics and chaos controls.
package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/redis/go-redis/v9"

	"flightdeck/libs/svckit"
)

const service = "notifier"

func main() {
	logger := svckit.NewLogger(service)

	rdb := redis.NewClient(&redis.Options{
		Addr:     svckit.Env("REDIS_ADDR", "localhost:6379"),
		Password: os.Getenv("REDIS_PASSWORD"),
		DB:       svckit.EnvInt("REDIS_DB", 0),
	})
	defer rdb.Close()

	metrics := svckit.NewMetrics(service)
	processed := prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "notifications_processed_total",
		Help: "Notification jobs processed, by result.",
	}, []string{"result"})
	queueDepth := prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "notification_queue_depth",
		Help: "Jobs waiting on the notifications list, sampled periodically.",
	})
	metrics.Registry.MustRegister(processed, queueDepth)
	for _, res := range []string{resultDelivered, resultFailed, resultInvalid} {
		processed.WithLabelValues(res) // export zeroes before the first job
	}

	chaos := svckit.NewChaos(svckit.EnvBool("CHAOS_ENABLED", false), logger)
	w := &worker{
		logger:      logger,
		rdb:         rdb,
		chaos:       chaos,
		queue:       svckit.Env("NOTIFICATIONS_QUEUE", svckit.DefaultQueue),
		popTimeout:  svckit.EnvDuration("BLPOP_TIMEOUT", 2*time.Second),
		minDelivery: time.Duration(svckit.EnvInt("DELIVERY_MIN_MS", 200)) * time.Millisecond,
		maxDelivery: time.Duration(svckit.EnvInt("DELIVERY_MAX_MS", 500)) * time.Millisecond,
		processed:   processed,
		queueDepth:  queueDepth,
	}

	health := &svckit.Health{}
	health.AddCheck("redis", func(ctx context.Context) error { return rdb.Ping(ctx).Err() })
	r := svckit.NewRouter(logger, metrics, chaos, health, true)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	workerDone := make(chan struct{})
	go func() {
		defer close(workerDone)
		w.run(ctx)
	}()
	go w.sampleDepth(ctx, svckit.EnvDuration("QUEUE_DEPTH_INTERVAL", 5*time.Second))

	logger.Info("starting", "queue", w.queue, "chaos_enabled", chaos.Enabled())
	srv := svckit.NewServer(svckit.Env("HTTP_ADDR", ":8082"), r)
	exitCode := 0
	if err := svckit.Serve(ctx, logger, srv, health); err != nil {
		logger.Error("server failed", "err", err)
		exitCode = 1
		stop() // also stop the worker
	}

	select {
	case <-workerDone:
		logger.Info("worker stopped")
	case <-time.After(svckit.ShutdownTimeout):
		logger.Warn("worker did not finish within drain timeout")
	}
	if exitCode != 0 {
		os.Exit(exitCode)
	}
}
