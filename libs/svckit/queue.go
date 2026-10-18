package svckit

import "time"

// DefaultQueue is the Redis list the gateway pushes to and the notifier pops.
const DefaultQueue = "notifications"

// NotificationJob is the JSON payload on the notifications list. It is the
// contract between gateway (producer) and notifier (consumer).
type NotificationJob struct {
	FlightID   int64     `json:"flight_id"`
	FlightNo   string    `json:"flight_no"`
	Channel    string    `json:"channel"`
	Recipient  string    `json:"recipient,omitempty"`
	RequestID  string    `json:"request_id"`
	EnqueuedAt time.Time `json:"enqueued_at"`
}
