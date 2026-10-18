// Command flights serves flight status read from Postgres.
package main

import (
	"context"
	"net"
	"net/url"
	"os"
	"os/signal"
	"syscall"

	"github.com/jackc/pgx/v5/pgxpool"

	"flightdeck/libs/svckit"
)

const service = "flights"

func main() {
	logger := svckit.NewLogger(service)

	poolCfg, err := pgxpool.ParseConfig(postgresURL())
	if err != nil {
		logger.Error("invalid postgres config", "err", err)
		os.Exit(1)
	}
	poolCfg.MaxConns = int32(svckit.EnvInt("DB_MAX_CONNS", 5))

	// The pool connects lazily, so the service starts (and reports not-ready)
	// even while Postgres is still coming up.
	pool, err := pgxpool.NewWithConfig(context.Background(), poolCfg)
	if err != nil {
		logger.Error("create postgres pool", "err", err)
		os.Exit(1)
	}
	defer pool.Close()

	health := &svckit.Health{}
	health.AddCheck("postgres", pool.Ping)

	h := &handlers{logger: logger, db: pool}
	chaos := svckit.NewChaos(svckit.EnvBool("CHAOS_ENABLED", false), logger)
	r := svckit.NewRouter(logger, svckit.NewMetrics(service), chaos, health, true)
	r.Get("/flights", h.listFlights)
	r.Get("/flights/{id}", h.getFlight)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	logger.Info("starting", "postgres_host", poolCfg.ConnConfig.Host, "postgres_db", poolCfg.ConnConfig.Database, "chaos_enabled", chaos.Enabled())
	srv := svckit.NewServer(svckit.Env("HTTP_ADDR", ":8081"), r)
	if err := svckit.Serve(ctx, logger, srv, health); err != nil {
		logger.Error("server failed", "err", err)
		os.Exit(1)
	}
}

// postgresURL assembles a connection URL from POSTGRES_* env vars. The
// password comes only from the environment (a k8s Secret in-cluster).
func postgresURL() string {
	u := url.URL{
		Scheme:   "postgres",
		User:     url.UserPassword(svckit.Env("POSTGRES_USER", "flightdeck"), os.Getenv("POSTGRES_PASSWORD")),
		Host:     net.JoinHostPort(svckit.Env("POSTGRES_HOST", "localhost"), svckit.Env("POSTGRES_PORT", "5432")),
		Path:     "/" + svckit.Env("POSTGRES_DB", "flightdeck"),
		RawQuery: url.Values{"sslmode": {svckit.Env("POSTGRES_SSLMODE", "disable")}}.Encode(),
	}
	return u.String()
}
