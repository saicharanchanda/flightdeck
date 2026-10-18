// Package svckit holds the plumbing every flightdeck service shares:
// env config, JSON logging, request IDs, RED metrics, chaos injection,
// health probes and graceful shutdown.
package svckit

import (
	"os"
	"strconv"
	"time"
)

// Env returns the value of key, or def when it is unset or empty.
func Env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// EnvInt returns key parsed as an int, or def when unset or unparsable.
func EnvInt(key string, def int) int {
	if v, err := strconv.Atoi(os.Getenv(key)); err == nil {
		return v
	}
	return def
}

// EnvBool returns key parsed as a bool, or def when unset or unparsable.
func EnvBool(key string, def bool) bool {
	if v, err := strconv.ParseBool(os.Getenv(key)); err == nil {
		return v
	}
	return def
}

// EnvDuration returns key parsed as a time.Duration ("5s", "250ms"),
// or def when unset or unparsable.
func EnvDuration(key string, def time.Duration) time.Duration {
	if v, err := time.ParseDuration(os.Getenv(key)); err == nil {
		return v
	}
	return def
}
