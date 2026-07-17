# =============================================================================
# queries.R — dashboard query functions for the NAS Delay Dashboard.
#
# Each function takes a live DBI connection (+ parameters) and returns a
# data frame. Written and tested here in isolation, then called by app.R.
# Most read the pre-aggregated daily_summary; delay_distribution() hits
# flights_clean for row-level detail.
#
# daily_summary columns (grain = flight_date x carrier x origin):
#   n_flights, n_on_time, n_cancelled, n_diverted,
#   sum_arr_delay, n_arr_delay, sum_dep_delay, n_dep_delay,
#   carrier_delay_min, weather_delay_min, nas_delay_min,
#   security_delay_min, late_aircraft_delay_min
# Rates/averages are DERIVED from these additive columns at query time.
# Note: every ratio casts one side ::float (Postgres integer / integer
# truncates), and wraps the denominator in NULLIF(x, 0) for empty ranges.
# =============================================================================

library(DBI)

# --- Helpers: populate UI controls -------------------------------------------

# Min/max flight_date in the warehouse — sets the date-picker bounds.
date_bounds <- function(con) {
  dbGetQuery(con, "SELECT min(flight_date) AS min_date, max(flight_date) AS max_date
                   FROM daily_summary")
}

# Origin airports with their flight volume, busiest first — for the dropdown.
airport_list <- function(con) {
  dbGetQuery(con, "SELECT origin, sum(n_flights)::int AS n_flights
                   FROM daily_summary GROUP BY origin ORDER BY n_flights DESC")
}

# --- Tab 1: Overview ---------------------------------------------------------

# One-row headline KPIs for a date range.
overview_kpis <- function(con, date_from, date_to) {
  dbGetQuery(con, "
    SELECT sum(n_flights)::int                                    AS total_flights,
           sum(n_on_time)::float    / NULLIF(sum(n_flights), 0)   AS on_time_rate,
           sum(n_cancelled)::float  / NULLIF(sum(n_flights), 0)   AS cancel_rate,
           sum(sum_arr_delay)::float / NULLIF(sum(n_arr_delay), 0) AS avg_arr_delay
    FROM daily_summary
    WHERE flight_date BETWEEN $1 AND $2",
    params = list(date_from, date_to))
}

# Daily trend: one row per day (on-time rate, avg arrival delay, volume).
daily_trend <- function(con, date_from, date_to) {
  dbGetQuery(con, "
    SELECT flight_date,
           sum(n_flights)::int                                    AS n_flights,
           sum(n_on_time)::float    / NULLIF(sum(n_flights), 0)   AS on_time_rate,
           sum(n_cancelled)::float  / NULLIF(sum(n_flights), 0)   AS cancel_rate,
           sum(sum_arr_delay)::float / NULLIF(sum(n_arr_delay), 0) AS avg_arr_delay
    FROM daily_summary
    WHERE flight_date BETWEEN $1 AND $2
    GROUP BY flight_date
    ORDER BY flight_date",
    params = list(date_from, date_to))
}

# --- Tab 2: By airport -------------------------------------------------------

# One-row KPIs for a single origin airport over a date range.
airport_kpis <- function(con, origin, date_from, date_to) {
  dbGetQuery(con, "
    SELECT sum(n_flights)::int                                    AS total_flights,
           sum(n_on_time)::float    / NULLIF(sum(n_flights), 0)   AS on_time_rate,
           sum(n_cancelled)::float  / NULLIF(sum(n_flights), 0)   AS cancel_rate,
           sum(sum_arr_delay)::float / NULLIF(sum(n_arr_delay), 0) AS avg_arr_delay
    FROM daily_summary
    WHERE origin = $1 AND flight_date BETWEEN $2 AND $3",
    params = list(origin, date_from, date_to))
}

# Cause-of-delay breakdown for one airport, LONG format (one row per cause,
# ready to plot). Uses a LATERAL VALUES unpivot to turn the five cause
# columns into rows in a single table scan.
cause_breakdown <- function(con, origin, date_from, date_to) {
  dbGetQuery(con, "
    SELECT v.cause, sum(v.minutes)::bigint AS minutes
    FROM daily_summary d
    CROSS JOIN LATERAL (VALUES
      ('Carrier',        d.carrier_delay_min),
      ('Weather',        d.weather_delay_min),
      ('NAS',            d.nas_delay_min),
      ('Security',       d.security_delay_min),
      ('Late aircraft',  d.late_aircraft_delay_min)
    ) AS v(cause, minutes)
    WHERE d.origin = $1 AND d.flight_date BETWEEN $2 AND $3
    GROUP BY v.cause
    ORDER BY minutes DESC",
    params = list(origin, date_from, date_to))
}

# Arrival-delay distribution in 15-minute bins for one airport.
# Hits flights_clean (row-level) — the summary can't reconstruct a spread.
delay_distribution <- function(con, origin, date_from, date_to) {
  dbGetQuery(con, "
    SELECT (floor(arr_delay / 15.0) * 15)::int AS bucket_min,
           count(*)::int                       AS n
    FROM flights_clean
    WHERE origin = $1 AND flight_date BETWEEN $2 AND $3
      AND arr_delay IS NOT NULL
    GROUP BY bucket_min
    ORDER BY bucket_min",
    params = list(origin, date_from, date_to))
}

# --- Tab 3: Carrier comparison -----------------------------------------------

# Per-carrier KPIs over a date range, ranked by on-time rate.
# HAVING drops tiny carriers whose rates would be noise.
carrier_comparison <- function(con, date_from, date_to) {
  dbGetQuery(con, "
    SELECT carrier,
           sum(n_flights)::int                                    AS n_flights,
           sum(n_on_time)::float    / NULLIF(sum(n_flights), 0)   AS on_time_rate,
           sum(n_cancelled)::float  / NULLIF(sum(n_flights), 0)   AS cancel_rate,
           sum(sum_arr_delay)::float / NULLIF(sum(n_arr_delay), 0) AS avg_arr_delay
    FROM daily_summary
    WHERE flight_date BETWEEN $1 AND $2
    GROUP BY carrier
    HAVING sum(n_flights) >= 500
    ORDER BY on_time_rate DESC",
    params = list(date_from, date_to))
}
