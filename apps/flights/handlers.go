package main

import (
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"flightdeck/libs/svckit"
)

const maxFlights = 200

// Flight is one row of the flights table.
type Flight struct {
	ID           int64     `db:"id"            json:"id"`
	FlightNo     string    `db:"flight_no"     json:"flight_no"`
	OriginIATA   string    `db:"origin_iata"   json:"origin_iata"`
	DestIATA     string    `db:"dest_iata"     json:"dest_iata"`
	ScheduledDep time.Time `db:"scheduled_dep" json:"scheduled_dep"`
	Status       string    `db:"status"        json:"status"`
	Aircraft     string    `db:"aircraft"      json:"aircraft"`
}

const flightColumns = `id, flight_no, origin_iata, dest_iata, scheduled_dep, status, aircraft`

type handlers struct {
	logger *slog.Logger
	db     *pgxpool.Pool
}

// listFlights returns flights ordered by departure, optionally filtered
// with ?origin=HYD and/or ?status=delayed.
func (h *handlers) listFlights(w http.ResponseWriter, r *http.Request) {
	origin := strings.ToUpper(r.URL.Query().Get("origin"))
	status := strings.ToLower(r.URL.Query().Get("status"))

	rows, err := h.db.Query(r.Context(),
		`SELECT `+flightColumns+` FROM flights
		 WHERE ($1 = '' OR origin_iata = $1) AND ($2 = '' OR status = $2)
		 ORDER BY scheduled_dep, id
		 LIMIT $3`,
		origin, status, maxFlights)
	if err != nil {
		h.dbFailed(w, r, err)
		return
	}
	flights, err := pgx.CollectRows(rows, pgx.RowToStructByName[Flight])
	if err != nil {
		h.dbFailed(w, r, err)
		return
	}
	svckit.WriteJSON(w, http.StatusOK, map[string]any{"flights": flights, "count": len(flights)})
}

func (h *handlers) getFlight(w http.ResponseWriter, r *http.Request) {
	id, err := strconv.ParseInt(chi.URLParam(r, "id"), 10, 64)
	if err != nil || id <= 0 {
		svckit.WriteError(w, http.StatusBadRequest, "flight id must be a positive integer")
		return
	}
	rows, err := h.db.Query(r.Context(), `SELECT `+flightColumns+` FROM flights WHERE id = $1`, id)
	if err != nil {
		h.dbFailed(w, r, err)
		return
	}
	flight, err := pgx.CollectExactlyOneRow(rows, pgx.RowToStructByName[Flight])
	if errors.Is(err, pgx.ErrNoRows) {
		svckit.WriteError(w, http.StatusNotFound, "flight not found")
		return
	}
	if err != nil {
		h.dbFailed(w, r, err)
		return
	}
	svckit.WriteJSON(w, http.StatusOK, flight)
}

func (h *handlers) dbFailed(w http.ResponseWriter, r *http.Request, err error) {
	h.logger.ErrorContext(r.Context(), "postgres query failed", "err", err)
	svckit.WriteError(w, http.StatusServiceUnavailable, "flight data unavailable")
}
