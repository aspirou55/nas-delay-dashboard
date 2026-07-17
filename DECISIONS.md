# Design Decisions

Several choices in this project had more than one defensible option. This
document records each fork: the alternatives, the tradeoff, why the current
choice was made, and the conditions under which the other option would win.

Recurring theme: most of these are **simplicity vs. scale/robustness**
tradeoffs, resolved toward simplicity *because the current scale doesn't justify
the complexity yet* — while knowing the threshold at which to switch. And note
that the same question can have different right answers in different parts of one
system (see #6).

---

### 1. Fail-loud vs. quarantine on validation failure

- **Chosen:** halt the entire month's load when any validation check fails.
- **Alternative:** route bad rows to a quarantine/dead-letter table, load the rest.

Halting favors **correctness over availability** — a failed check means the data
isn't fully understood, so a human should look before anything trusts it.
Quarantining favors **throughput** — one anomaly shouldn't block hundreds of
thousands of good rows. We halt because this is a low-volume monthly batch where
a stalled pipeline is cheap to fix and data-quality rigor is the point. At
production scale with continuous feeds and SLAs, the mature pattern is a hybrid:
**halt on structural/schema failures, quarantine on row-level anomalies.**

### 2. Full rebuild vs. incremental summary table

- **Chosen:** drop and recompute `daily_summary` from the full fact table each run.
- **Alternative:** incrementally update only the month that changed.

Full rebuild is **stateless and cannot drift** — the summary is a pure function
of the fact table. It costs a few seconds at 1.8M rows, so the consistency
guarantee outweighs the wasted compute. Incremental becomes worth its added
complexity at full-history scale (100M+ rows), where recomputing everything to
add one month is wasteful.

### 3. Pre-aggregated summary vs. querying the fact table directly

- **Chosen:** build `daily_summary`; the dashboard reads it.
- **Alternative:** index `flights_clean` and aggregate on the fly per request.

Precomputing gives predictable low latency under repeated dashboard interaction
and keeps the public app off the raw layer. Direct querying is simpler (no second
table to keep in sync, always fresh) and is fine at smaller scale or when
freshness beats latency. A columnar/OLAP engine (ClickHouse, DuckDB) narrows this
gap by making on-the-fly aggregation fast enough to skip the summary.

### 4. Idempotency: delete-then-append vs. upsert vs. full reload

- **Chosen:** per-month "partition overwrite" — delete the month's rows, append fresh, in a transaction.
- **Alternatives:** `INSERT ... ON CONFLICT` upsert; or truncate-and-reload-everything.

The source *is* monthly files, so replacing data a month at a time is the honest
match — simpler than upsert, less wasteful than a full reload, and atomic inside
the transaction. Upsert wins when corrections arrive at the individual-row level
rather than as whole-month drops. Full reload is fine only when the dataset is
tiny.

### 5. Manual trigger vs. automated scheduling

- **Chosen:** run the ETL by hand / via a documented command.
- **Alternative:** schedule it (cron, GitHub Actions, a Fargate task).

BTS publishes monthly with a ~2-month lag, so a scheduled nightly job buys
nothing — a human running an idempotent, parameterized script on that cadence is
legitimate. The pipeline is nonetheless *automation-ready*. Automation earns its
keep for frequent/operational feeds (daily or hourly), where you'd schedule it
with monitoring and alerting. Principle: **extract cadence should match source
cadence.**

### 6. Single connection vs. connection pool — different answers in one system

- **ETL uses a single connection**; **the dashboard uses a pool** — deliberately.

A batch job opens a connection, does its work, and closes it: short-lived,
single-threaded, so a pool is pointless overhead. The dashboard is long-lived and
serves concurrent users over a serverless database that suspends when idle — a
single connection is fragile (it broke when Neon suspended it) and not
concurrency-safe, so `pool` (which validates and replaces dead connections) is
correct. The right answer depends on **connection lifecycle**, not dogma.

### 7. SMALLINT vs. INTEGER vs. DOUBLE for delay columns

- **Chosen:** `SMALLINT` (2 bytes) for the delay-minute columns.
- **Alternatives:** `INTEGER` (4 bytes) or `DOUBLE PRECISION` (8 bytes).

Delays are whole minutes within ±32,767 (max observed ~52h = 3,134), so
`SMALLINT` is valid and ~20% smaller/faster on a multi-million-row table. This
*couples storage to the range-check assumption* — `INTEGER` trades a little space
for headroom that can't overflow. `DOUBLE` requires no reasoning but wastes space
and implies false precision. The tradeoff: **tight-and-validated vs. loose-and-safe.**

### 8. Read-only role vs. owner credentials for the public app

- **Chosen:** a dedicated read-only database role for the deployed app.
- **Alternative:** reuse the owner credentials.

The app is public, so **least privilege** is cheap insurance — a leaked
credential or injection can only read public data. Owner credentials are simpler
and acceptable for a private/internal app or an early prototype where the small
role-setup cost isn't yet justified.

---

### Other choices, briefly

- **Warehouse vs. read-CSV-in-app:** a database gives one validated source of truth, pre-aggregation, SQL access, and append-without-touching-the-app — worth the extra load step.
- **Summary grain `(date × carrier × origin)`:** fine enough for the three dashboard tabs while staying ~122K rows; finer grain (add `dest`/`dep_hour`) would balloon it, so those live in the fact table for drill-down.
- **Store additive measures (counts, sums) not rates/averages:** additive columns re-aggregate correctly at any rollup; a stored average cannot be averaged back up.
- **PK on `daily_summary` but not `flights_clean`:** the summary's grain is worth enforcing in-DB; the fact table's uniqueness is already guaranteed by the ETL, and its useful indexes are query-pattern (date/carrier/origin), not the natural key.
- **shinyapps.io hosting; `.Renviron`-in-app for secrets:** free public hosting; shinyapps.io doesn't support `envVars`, so a bundled (gitignored) `.Renviron` is the platform-native way to pass credentials.
