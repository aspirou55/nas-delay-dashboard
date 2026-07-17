# NAS Delay Dashboard

**End-to-end R data pipeline and interactive dashboard for U.S. flight on-time performance.**
Extracts Bureau of Transportation Statistics (BTS) data, validates and transforms it, loads it
into a cloud PostgreSQL warehouse, and serves live metrics through an R Shiny app.

🔗 **Live demo:** https://aspirou55.shinyapps.io/nas-delay-dashboard/

Built with R · dplyr · DBI/RPostgres · PostgreSQL (Neon) · R Shiny · ggplot2 · pool · Python (pandas, EDA)

---

## What it does

- Ingests every U.S. domestic flight for a set of months (~1.8M flights across March–May 2026)
  from the BTS Reporting-Carrier On-Time Performance dataset.
- Runs a validated, idempotent ETL that lands clean data in a cloud Postgres warehouse.
- Serves three interactive tabs — **Overview**, **By airport**, **Carrier comparison** — reading a
  pre-aggregated summary table for speed, with drill-down to the raw fact table for distributions.

## Architecture

```
BTS TranStats (monthly zipped CSVs)
        │  extract → validate → transform → load  (etl/etl.R, idempotent, run monthly)
        ▼
Neon cloud PostgreSQL
  flights_clean   — fact table, 1 row per flight (~1.8M rows)
  daily_summary   — pre-aggregated (date × carrier × origin), additive measures
        │  read-only role, connection pool
        ▼
R Shiny dashboard on shinyapps.io   (app/app.R + app/queries.R)
  Overview │ By airport │ Carrier comparison
```

## Pipeline highlights

- **Typed, selective ingestion** — 18 of the source's 110 columns kept, each explicitly typed
  (e.g. scheduled times read as text to preserve leading zeros like `0005`).
- **Five validation checks** — row-count sanity, dates-in-month, duplicate natural key, an NA audit
  (delay may be null *only* for cancelled/diverted flights), and a plausible-range check. The
  pipeline **fails loudly** rather than loading suspect data.
- **Idempotent loads** — each month is a delete-then-append "partition overwrite" inside a
  transaction, so reruns never duplicate and a failed run never half-loads.
- **Additive summary table** — the aggregate stores counts and sums (not rates/averages), so every
  rate and *weighted* average re-aggregates correctly at query time.
- **Read-only DB role** for the public app; **connection pooling** (`pool`) so the dashboard is
  resilient to the serverless database suspending and resuming.

## Repository layout

| Path | What |
|---|---|
| `etl/etl.R` | The full ETL: extract → validate → transform → load → summarize, plus a CLI |
| `app/app.R` | Shiny UI + server (reactivity, ggplot2 charts) |
| `app/queries.R` | Parameterized SQL query functions (tested in isolation) |
| `eda/` | Exploratory data audit — Jupyter notebook + findings report |
| `.Renviron.example` | Template for the database credentials (real `.Renviron` is gitignored) |

## Running it locally

1. R ≥ 4.4 with: `readr`, `dplyr`, `DBI`, `RPostgres`, `shiny`, `pool`, `ggplot2`, `scales`.
2. A PostgreSQL database (this project uses a free [Neon](https://neon.tech) instance).
3. Copy `.Renviron.example` → `.Renviron` and fill in your connection details.

```bash
# from the project root — load the default 3 months, then build the summary
Rscript etl/etl.R
```

Then open `app/app.R` in RStudio and click **Run App**.

### Live-demo commands

The ETL is parameterized, so you can add or remove a month on the fly and watch the dashboard change:

```bash
Rscript etl/etl.R 2026 2          # add February 2026
Rscript etl/etl.R delete 2026 2   # remove it again
```

Load a month, refresh the dashboard, and February appears in the date picker with the metrics updated.

## Data source

[BTS Reporting-Carrier On-Time Performance](https://www.transtats.bts.gov/Tables.asp?DB_ID=120) —
every U.S. domestic flight by reporting carriers: scheduled vs. actual times, delay minutes by cause
(carrier / weather / NAS / security / late-aircraft), cancellations, and diversions. Published
monthly; no public API, so the ETL downloads the prezipped monthly files directly.
