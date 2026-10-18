package main

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"math/rand/v2"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/redis/go-redis/v9"

	"flightdeck/libs/svckit"
)

const (
	resultDelivered = "delivered"
	resultFailed    = "failed"
	resultInvalid   = "invalid"

	redisRetryDelay = time.Second
)

type worker struct {
	logger      *slog.Logger
	rdb         *redis.Client
	chaos       *svckit.Chaos
	queue       string
	popTimeout  time.Duration
	minDelivery time.Duration
	maxDelivery time.Duration
	processed   *prometheus.CounterVec
	queueDepth  prometheus.Gauge
}

// run BLPOPs until ctx is cancelled. BLPOP itself uses a background
// context with a short server-side timeout: cancelling a blocked pop
// client-side can drop a job Redis already handed over, so shutdown is
// noticed between pops instead, and the job in hand is always finished.
func (w *worker) run(ctx context.Context) {
	w.logger.Info("worker started", "queue", w.queue)
	for ctx.Err() == nil {
		res, err := w.rdb.BLPop(context.Background(), w.popTimeout, w.queue).Result()
		if errors.Is(err, redis.Nil) {
			continue // timed out with an empty queue
		}
		if err != nil {
			w.logger.Warn("blpop failed", "err", err)
			select {
			case <-ctx.Done():
			case <-time.After(redisRetryDelay):
			}
			continue
		}
		w.process(res[1]) // res is [key, value]
	}
	w.logger.Info("worker draining complete")
}

// process simulates delivery with a 200-500ms sleep plus any injected
// chaos latency; chaos error rate turns deliveries into failures.
func (w *worker) process(raw string) {
	start := time.Now()
	var job svckit.NotificationJob
	if err := json.Unmarshal([]byte(raw), &job); err != nil {
		w.processed.WithLabelValues(resultInvalid).Inc()
		w.logger.Error("invalid job payload", "err", err, "payload_bytes", len(raw))
		return
	}
	ctx := svckit.WithRequestID(context.Background(), job.RequestID)

	time.Sleep(w.deliveryDelay() + w.chaos.Latency())

	attrs := []any{
		"flight_id", job.FlightID,
		"flight_no", job.FlightNo,
		"channel", job.Channel,
		"duration_ms", svckit.DurationMs(time.Since(start)),
		"queue_wait_ms", svckit.DurationMs(start.Sub(job.EnqueuedAt)),
	}
	if w.chaos.ShouldFail() {
		w.processed.WithLabelValues(resultFailed).Inc()
		w.logger.WarnContext(ctx, "notification delivery failed", append(attrs, "reason", "chaos: injected failure")...)
		return
	}
	w.processed.WithLabelValues(resultDelivered).Inc()
	w.logger.InfoContext(ctx, "notification delivered", attrs...)
}

func (w *worker) deliveryDelay() time.Duration {
	if w.maxDelivery <= w.minDelivery {
		return w.minDelivery
	}
	return w.minDelivery + rand.N(w.maxDelivery-w.minDelivery)
}

// sampleDepth periodically sets the queue depth gauge from LLEN.
func (w *worker) sampleDepth(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		n, err := w.rdb.LLen(ctx, w.queue).Result()
		if err == nil {
			w.queueDepth.Set(float64(n))
		} else if ctx.Err() == nil {
			w.logger.Warn("llen failed", "err", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}
