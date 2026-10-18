package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/redis/go-redis/v9"

	"flightdeck/libs/svckit"
)

const maxSubscribeBody = 4 << 10

var validChannels = map[string]bool{"email": true, "sms": true, "push": true}

type handlers struct {
	logger     *slog.Logger
	flightsURL string
	client     *http.Client
	rdb        *redis.Client
	queue      string
}

type subscribeRequest struct {
	Channel   string `json:"channel"`
	Recipient string `json:"recipient"`
}

func (h *handlers) listFlights(w http.ResponseWriter, r *http.Request) {
	h.proxy(w, r, "/flights")
}

func (h *handlers) getFlight(w http.ResponseWriter, r *http.Request) {
	id, ok := flightID(w, r)
	if !ok {
		return
	}
	h.proxy(w, r, "/flights/"+strconv.FormatInt(id, 10))
}

// subscribe checks the flight exists, then RPUSHes a job for the notifier.
func (h *handlers) subscribe(w http.ResponseWriter, r *http.Request) {
	id, ok := flightID(w, r)
	if !ok {
		return
	}

	req := subscribeRequest{Channel: "email"}
	if r.ContentLength != 0 {
		dec := json.NewDecoder(io.LimitReader(r.Body, maxSubscribeBody))
		if err := dec.Decode(&req); err != nil && !errors.Is(err, io.EOF) {
			svckit.WriteError(w, http.StatusBadRequest, "body must be JSON: {\"channel\": \"email|sms|push\", \"recipient\": \"...\"}")
			return
		}
	}
	if !validChannels[req.Channel] {
		svckit.WriteError(w, http.StatusBadRequest, "channel must be one of email, sms, push")
		return
	}

	resp, err := h.upstream(r, "/flights/"+strconv.FormatInt(id, 10))
	if err != nil {
		h.upstreamFailed(w, r, err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		svckit.WriteError(w, http.StatusNotFound, "flight not found")
		return
	}
	if resp.StatusCode != http.StatusOK {
		h.logger.ErrorContext(r.Context(), "flights lookup failed", "upstream_status", resp.StatusCode)
		svckit.WriteError(w, http.StatusBadGateway, "flights service error")
		return
	}
	var flight struct {
		FlightNo string `json:"flight_no"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&flight); err != nil {
		h.logger.ErrorContext(r.Context(), "flights response undecodable", "err", err)
		svckit.WriteError(w, http.StatusBadGateway, "flights service error")
		return
	}

	job := svckit.NotificationJob{
		FlightID:   id,
		FlightNo:   flight.FlightNo,
		Channel:    req.Channel,
		Recipient:  req.Recipient,
		RequestID:  svckit.RequestIDFrom(r.Context()),
		EnqueuedAt: time.Now().UTC(),
	}
	payload, err := json.Marshal(job)
	if err != nil {
		svckit.WriteError(w, http.StatusInternalServerError, "encode job")
		return
	}
	if err := h.rdb.RPush(r.Context(), h.queue, payload).Err(); err != nil {
		h.logger.ErrorContext(r.Context(), "enqueue failed", "queue", h.queue, "err", err)
		svckit.WriteError(w, http.StatusServiceUnavailable, "notification queue unavailable")
		return
	}
	h.logger.InfoContext(r.Context(), "subscription queued", "flight_id", id, "flight_no", job.FlightNo, "channel", job.Channel)
	svckit.WriteJSON(w, http.StatusAccepted, map[string]any{
		"status":     "queued",
		"flight_id":  id,
		"flight_no":  job.FlightNo,
		"channel":    job.Channel,
		"request_id": job.RequestID,
	})
}

// proxy relays a GET to the flights service and copies back status and body.
func (h *handlers) proxy(w http.ResponseWriter, r *http.Request, path string) {
	resp, err := h.upstream(r, path)
	if err != nil {
		h.upstreamFailed(w, r, err)
		return
	}
	defer resp.Body.Close()
	if ct := resp.Header.Get("Content-Type"); ct != "" {
		w.Header().Set("Content-Type", ct)
	}
	w.WriteHeader(resp.StatusCode)
	if _, err := io.Copy(w, resp.Body); err != nil {
		h.logger.WarnContext(r.Context(), "proxy copy interrupted", "err", err)
	}
}

// upstream issues a GET to the flights service, forwarding the query
// string and the request ID.
func (h *handlers) upstream(r *http.Request, path string) (*http.Response, error) {
	u := h.flightsURL + path
	if r.URL.RawQuery != "" {
		u += "?" + r.URL.RawQuery
	}
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, u, nil)
	if err != nil {
		return nil, fmt.Errorf("build upstream request: %w", err)
	}
	req.Header.Set(svckit.RequestIDHeader, svckit.RequestIDFrom(r.Context()))
	req.Header.Set("Accept", "application/json")
	return h.client.Do(req)
}

func (h *handlers) upstreamFailed(w http.ResponseWriter, r *http.Request, err error) {
	status := http.StatusBadGateway
	var uerr *url.Error
	if errors.As(err, &uerr) && uerr.Timeout() || errors.Is(err, os.ErrDeadlineExceeded) {
		status = http.StatusGatewayTimeout
	}
	h.logger.ErrorContext(r.Context(), "flights service unreachable", "err", err, "status", status)
	svckit.WriteError(w, status, "flights service unavailable")
}

// flightID parses the {id} URL param, writing a 400 when it is not a positive integer.
func flightID(w http.ResponseWriter, r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(chi.URLParam(r, "id"), 10, 64)
	if err != nil || id <= 0 {
		svckit.WriteError(w, http.StatusBadRequest, "flight id must be a positive integer")
		return 0, false
	}
	return id, true
}
