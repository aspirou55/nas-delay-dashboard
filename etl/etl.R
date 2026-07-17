# =============================================================================
# etl.R — BTS On-Time Performance: Extract -> Validate -> Transform -> Load
#
# Idempotent batch job. Rerunning for a month already in the database
# replaces that month's rows (no duplicates).
#
# =============================================================================

library(readr)
library(dplyr)
library(DBI)

# --- Config ------------------------------------------------------------------

# Months to load, as year/month pairs. BTS publishes with ~2-month lag.
MONTHS <- list(
  c(2026L, 3L),
  c(2026L, 4L),
  c(2026L, 5L)
)

RAW_DIR <- "data/raw"

# BTS prezipped monthly files follow a predictable URL pattern:
bts_url <- function(year, month) {
  paste0(
    "https://transtats.bts.gov/PREZIP/",
    "On_Time_Reporting_Carrier_On_Time_Performance_1987_present_",
    year, "_", month, ".zip"
  )
}

# --- 1. EXTRACT ---------------------------------------------------------------

extract_month <- function(year, month) {
  zip_path <- file.path(RAW_DIR, paste0("ontime_", year, "_", month, ".zip"))

  if (!file.exists(zip_path)) {
    message("Downloading ", year, "-", month, " ...")
    download.file(bts_url(year, month), zip_path, mode = "wb")
  }

  # The zip contains one CSV; unzip to RAW_DIR and return the CSV path
  csv_name <- unzip(zip_path, list = TRUE)$Name[1]
  unzip(zip_path, files = csv_name, exdir = RAW_DIR, overwrite = TRUE)
  file.path(RAW_DIR, csv_name)
}

read_month <- function(csv_path) {
  # Read the CSV with readr, with EXPLICIT types for the columns to keep.
  # Columns kept:
  #   FlightDate (date), Reporting_Airline (chr), Origin (chr), Dest (chr),
  #   CRSDepTime (chr), DepDelay (dbl), ArrDelay (dbl),
  #   Cancelled (dbl), CancellationCode (chr), Diverted (dbl),
  #   CarrierDelay, WeatherDelay, NASDelay, SecurityDelay, LateAircraftDelay (dbl)
  read_csv(csv_path, col_types = cols_only(FlightDate = col_date(),
                                           Flight_Number_Reporting_Airline = col_character(),
                                           Reporting_Airline = col_character(),
                                           Origin = col_character(), Dest = col_character(),
                                           CRSDepTime = col_character(),
                                           DepDelay = col_double(), ArrDelay = col_double(),
                                           Cancelled = col_double(), CancellationCode = col_character(),
                                           Diverted = col_double(),
                                           CarrierDelay = col_double(), WeatherDelay = col_double(),
                                           NASDelay = col_double(), SecurityDelay = col_double(),
                                           LateAircraftDelay = col_double(),
                                           ))
}

# --- 2. VALIDATE --------------------------------------------------------------

validate_month <- function(df, year, month) {
  # Each check either passes silently or stop()s with a clear message.

  # Sanity Check — at least 100,000 rows (a real month has ~500k).
  if (nrow(df) < 100000){
    stop(paste0("Sanity Failure: ", year, "-", month,
                " has only ", nrow(df), " rows (expected >= 100000)."))
  }

  # Every FlightDate falls inside the expected year/month.
  row_years  <- as.integer(format(df$FlightDate, "%Y"))   # e.g. 2026, 2026, ...
  row_months <- as.integer(format(df$FlightDate, "%m"))   # e.g. 3, 3, 3, ...
  if (any(row_years!=year) | any(row_months!=month)){
    stop(paste0("Date Failure: At least one FlightDate falls outside of ", month, ", ", year))
  }

  # No duplicate flights. Key: FlightDate + Reporting_Airline + Flight_Number_Reporting_Airline
  #                            + Origin + Dest + CRSDepTime 
  prior_row_count <- nrow(df)
  after_row_count <- df |> distinct(FlightDate, Reporting_Airline, Flight_Number_Reporting_Airline,
                                      Origin, Dest, CRSDepTime) |> nrow()
  if (after_row_count != prior_row_count){
    stop(paste0("Duplicate Check Failure: Returned ", prior_row_count - after_row_count, " duplicated natural keys"))
  }

  # NA audit — DepDelay/ArrDelay may be NA ONLY for cancelled or
  # diverted flights. A non-cancelled, non-diverted flight with NA
  # delay is a data-quality failure.
  n_bad_NA <- sum((is.na(df$ArrDelay) | is.na(df$DepDelay)) & df$Cancelled == 0 & df$Diverted == 0)
  if (n_bad_NA > 0) {
    stop(paste0("Failed NA Audit: ", n_bad_NA, " failed rows had NA delay despite being non-cancelled and non-diverted"))
  }

  # Range check — ArrDelay within a plausible window, such as -500..10080 minutes (1 week).
  n_bad_range <- sum(df$ArrDelay < -500 | df$ArrDelay > 10080, na.rm = TRUE)
  if (n_bad_range > 0){
    stop(paste0("Failed Range Check: ", n_bad_range, " rows have ArrDelay less than -120 min or greater than 3000 min"))
  }
  
  invisible(df)
}

# --- 3. TRANSFORM -------------------------------------------------------------

transform_month <- function(df) {
  # Build the analysis-ready frame from the raw columns:
  #   - rename to snake_case: flight_date, carrier, origin, dest, ...
  #   - dep_hour: first 1-2 digits of CRSDepTime
  #   - on_time flag: arr_delay < 15 & !cancelled & !diverted  (DOT definition)
  #   - cancelled/diverted: 0/1 doubles -> logical
  #   - keep NA arr_delay rows (they're cancelled/diverted; metrics will
  #     handle NA explicitly)
  
  df |> rename(flight_date = FlightDate, carrier = Reporting_Airline, dep_delay = DepDelay,
               flight_number = Flight_Number_Reporting_Airline, origin = Origin, dest = Dest,
               crs_dep_time = CRSDepTime, arr_delay = ArrDelay, cancelled = Cancelled,
               diverted = Diverted, cancellation_code = CancellationCode, carrier_delay = CarrierDelay,
               weather_delay = WeatherDelay, nas_delay = NASDelay, security_delay = SecurityDelay,
               late_aircraft_delay = LateAircraftDelay) |> mutate(dep_hour = as.integer(substr(crs_dep_time, 1, 2)), 
                                                                  cancelled = as.logical(cancelled),
                                                                  diverted  = as.logical(diverted),
                                                                  on_time   = arr_delay < 15 & !cancelled & !diverted)

}

# --- 4. LOAD ------------------------------------------------------------------

db_connect <- function() {
  # Reads credentials from .Renviron (see .Renviron.example)
  dbConnect(
    RPostgres::Postgres(),
    host     = Sys.getenv("PGHOST"),
    dbname   = Sys.getenv("PGDATABASE"),
    user     = Sys.getenv("PGUSER"),
    password = Sys.getenv("PGPASSWORD"),
    port     = as.integer(Sys.getenv("PGPORT", "5432")),
    sslmode  = "require"
  )
}

load_month <- function(con, df, year, month) {
  # Idempotency: delete this month's rows, then append the fresh ones,
  # inside a transaction so a failed run can't leave a half-loaded month.
  dbBegin(con)
  tryCatch({
    dbExecute(con, "
      DELETE FROM flights_clean
      WHERE date_part('year', flight_date) = $1
        AND date_part('month', flight_date) = $2",
      params = list(year, month)
    )
    dbWriteTable(con, "flights_clean", df, append = TRUE)
    dbCommit(con)
    message("Loaded ", nrow(df), " rows for ", year, "-", month)
  }, error = function(e) {
    dbRollback(con)
    stop(e)
  })
}

# --- Initialize DB ----------------------------------------------------------------------
init_db <- function(con){
  dbExecute(con, "
           CREATE TABLE IF NOT EXISTS flights_clean (
      flight_date         DATE,
      flight_number       VARCHAR(10),
      carrier             VARCHAR(10),
      origin              VARCHAR(10),
      crs_dep_time        VARCHAR(10),
      cancellation_code   VARCHAR(10),
      dest                VARCHAR(10),
      dep_delay           SMALLINT,
      arr_delay           SMALLINT,
      carrier_delay       SMALLINT,
      weather_delay       SMALLINT,
      nas_delay           SMALLINT,
      security_delay      SMALLINT,
      late_aircraft_delay SMALLINT,
      dep_hour            INTEGER,
      cancelled           BOOLEAN,
      diverted            BOOLEAN,
      on_time             BOOLEAN
             )")
}


# --- 5. SUMMARIZE ---------------------------------------------------

build_summary <- function(con) {
  # daily_summary is fully DERIVED from flights_clean, so rebuild it from
  # scratch each run (idempotent). The GROUP BY runs inside Postgres — the
  # 600k+ raw rows never travel to R; only the small result is stored.
  #
  # Grain: one row per (flight_date, carrier, origin).
  # Store ADDITIVE primitives (counts AND sums), never rates/averages: sums and
  # counts re-aggregate correctly when the dashboard rolls up, so the app derives
  # rates (n_on_time/n_flights) and WEIGHTED averages (sum_arr_delay/n_arr_delay)
  # at query time. A stored average could not be averaged back up without lying.
  # n_arr_delay = count of NON-NULL arr_delay (cancelled/diverted excluded).
  dbExecute(con, "DROP TABLE IF EXISTS daily_summary")
  dbExecute(con, "
    CREATE TABLE daily_summary AS
    SELECT
      flight_date,
      carrier,
      origin,
      count(*)                                   AS n_flights,
      count(*) FILTER (WHERE on_time)            AS n_on_time,
      count(*) FILTER (WHERE cancelled)          AS n_cancelled,
      count(*) FILTER (WHERE diverted)           AS n_diverted,
      coalesce(sum(arr_delay), 0)                AS sum_arr_delay,
      count(arr_delay)                           AS n_arr_delay,
      coalesce(sum(dep_delay), 0)                AS sum_dep_delay,
      count(dep_delay)                           AS n_dep_delay,
      coalesce(sum(carrier_delay), 0)            AS carrier_delay_min,
      coalesce(sum(weather_delay), 0)            AS weather_delay_min,
      coalesce(sum(nas_delay), 0)                AS nas_delay_min,
      coalesce(sum(security_delay), 0)           AS security_delay_min,
      coalesce(sum(late_aircraft_delay), 0)      AS late_aircraft_delay_min
    FROM flights_clean
    GROUP BY flight_date, carrier, origin")
  # CREATE TABLE AS makes no constraints/indexes — declare the grain as the PK
  # (enforces uniqueness + NOT NULL, and builds the index). Re-added every run
  # because the DROP above removes it.
  dbExecute(con, "ALTER TABLE daily_summary ADD PRIMARY KEY (flight_date, carrier, origin)")
  n <- dbGetQuery(con, "SELECT count(*)::int AS n FROM daily_summary")$n
  message("Built daily_summary: ", n, " rows")
}

# --- Run ----------------------------------------------------------------------

# Load one or more months into flights_clean, then rebuild daily_summary.
# `months` is a list of c(year, month) pairs; defaults to the config set.
# Loading is idempotent per month (delete-then-append), so rerunning is safe.
main <- function(months = MONTHS) {
  con <- db_connect()
  on.exit(dbDisconnect(con))

  init_db(con)
  for (ym in months) {
    year <- ym[1]; month <- ym[2]
    csv <- extract_month(year, month)
    df  <- read_month(csv)
    validate_month(df, year, month)
    df  <- transform_month(df)
    load_month(con, df, year, month)
  }
  build_summary(con)                 # rebuild daily_summary from all loaded months
}

# Remove one month from flights_clean and rebuild the summary. The teardown
# for the demo: `delete_month(2026, 2)` puts the warehouse back to 3 months.
delete_month <- function(year, month) {
  con <- db_connect()
  on.exit(dbDisconnect(con))
  n <- dbExecute(con, "
    DELETE FROM flights_clean
    WHERE date_part('year', flight_date) = $1
      AND date_part('month', flight_date) = $2",
    params = list(year, month))
  message("Deleted ", n, " rows for ", year, "-", month)
  build_summary(con)                 # rebuild so daily_summary reflects the removal
}

# --- CLI: `Rscript etl/etl.R [...]` (skipped when the file is source()d) ------
# Run from the project root so .Renviron and data/raw resolve.
#   Rscript etl/etl.R                  -> load the default config months
#   Rscript etl/etl.R 2026 2           -> load Feb 2026 (add a month)
#   Rscript etl/etl.R delete 2026 2    -> delete Feb 2026 (teardown)
if (sys.nframe() == 0) {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) == 0) {
    main()
  } else if (args[1] == "delete" && length(args) == 3) {
    delete_month(as.integer(args[2]), as.integer(args[3]))
  } else if (length(args) == 2) {
    main(list(c(as.integer(args[1]), as.integer(args[2]))))
  } else {
    stop("Usage:\n",
         "  Rscript etl/etl.R                 # load default months\n",
         "  Rscript etl/etl.R <year> <month>  # load one month\n",
         "  Rscript etl/etl.R delete <year> <month>")
  }
}
