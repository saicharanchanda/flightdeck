-- flightdeck schema. Idempotent: safe to run on every deploy.

CREATE TABLE IF NOT EXISTS flights (
    id            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    flight_no     TEXT        NOT NULL,
    origin_iata   TEXT        NOT NULL CHECK (origin_iata ~ '^[A-Z]{3}$'),
    dest_iata     TEXT        NOT NULL CHECK (dest_iata ~ '^[A-Z]{3}$'),
    scheduled_dep TIMESTAMPTZ NOT NULL,
    status        TEXT        NOT NULL DEFAULT 'scheduled'
                  CHECK (status IN ('scheduled', 'boarding', 'departed', 'delayed', 'cancelled', 'landed')),
    aircraft      TEXT        NOT NULL,
    CHECK (origin_iata <> dest_iata),
    UNIQUE (flight_no, scheduled_dep)
);

CREATE INDEX IF NOT EXISTS flights_scheduled_dep_idx ON flights (scheduled_dep);
CREATE INDEX IF NOT EXISTS flights_origin_idx        ON flights (origin_iata);
