# BTS On-Time Performance — EDA Findings

**Dataset:** Reporting-Carrier On-Time Performance (transtats.bts.gov)
**Sample:** March 2026 — one monthly download, **612,102 flights**
**Companion notebook:** [`BTS_EDA.ipynb`](BTS_EDA.ipynb)

This audit does two passes: (1) what the **raw 110-column download** actually delivers — the nuances you inherit from the source — and (2) EDA on the **18 columns we keep** after typing and cleaning.

---

## Part 1 — What the raw download looks like

A single month is **612,102 rows × 110 columns**, and most of those columns are not useful:

| Column completeness | Count (of 110) |
|---|---|
| Fully empty (100% NA) | **25** |
| Mostly empty (>90% NA) | **49** |
| Complete (0% NA) | **38** |

**Key nuances an analyst inherits:**

- **A phantom 110th column.** Every row ends with a trailing comma, so the file technically has an unnamed final column (pandas reads it as `Unnamed: 109`) that is 100% empty. Pure formatting artifact.
- **The diverted-flight "saga."** Columns come in five repeating blocks (`Div1…`–`Div5…`) tracking up to five diversion legs per flight. `Div3`–`Div5` are entirely empty this month, and `Div1`–`Div2` are >99% empty — real diversions are rare (see Part 2: 0.34%).
- **Heavy redundancy.** `Year`, `Quarter`, `Month`, `DayofMonth`, `DayOfWeek` are all recomputable from `FlightDate`. The origin airport alone is encoded **four ways** — `OriginAirportID` (342 values), `OriginCityMarketID` (319), `Origin` (342, the human-readable code), `OriginCityName` (336). We keep only `Origin`.
- **Everything arrives as text.** Times are `hhmm` strings (`"0730"`, `"0005"`) that must stay character to preserve leading zeros; delays carry a `".00"` suffix; empty cells are blank, not `0`.

**Takeaway:** ~65% of raw columns are mostly or entirely empty in any given month. The real work of ingestion is *selecting the ~15% that matter and typing them correctly* — which is exactly what the ETL's typed `read_month` does (drops 92 columns, keeps 18).

---

## Part 2 — EDA on the 18 kept columns

### Missingness is structural, not random

Every NA in the cleaned data *means something* — none of it is noise to impute:

| Column(s) | % NA | Why |
|---|---|---|
| `cancellation_code` | **97.1%** | Only populated for cancelled flights |
| 5 cause-delay columns | **76.5%** | Only populated when a flight is 15+ min late |
| `arr_delay` | 3.24% | NA exactly when a flight was cancelled/diverted |
| `dep_delay` | 2.80% | Same |
| all other columns | 0% | Complete |

This is the single most important EDA insight for downstream metrics: **you must handle these NAs with domain logic (`na.rm`, conditional counts), never with generic imputation.** A cancelled flight has no arrival delay *because it never arrived* — filling it with `0` or a mean would corrupt every metric.

### Delay distributions are heavily right-skewed

| | min | Q1 | median | mean | Q3 | max | sd |
|---|---|---|---|---|---|---|---|
| `dep_delay` | −56 | −6 | **−2** | 17.0 | 15 | 2888 | 64.7 |
| `arr_delay` | −90 | −17 | **−6** | 10.6 | 14 | 2862 | 67.1 |

- **Most flights are early.** Median departure delay is −2 min and median arrival delay is −6 min — the *typical* flight leaves and lands ahead of schedule (padded schedules).
- **The mean is much larger than the median** (dep: 17 vs −2) — a classic right skew. A small tail of severe delays (max ≈ 2,888 min ≈ 48 hours) drags the average up. **Report the median, not the mean**, for "typical" performance; use the mean only when total-minutes matters.
- Standard deviation (~65 min) dwarfs the median — the distribution has heavy tails, not a tidy bell curve.

### Cause of delay: ripple and carrier dominate minutes; weather barely registers

Among flights 15+ min late, share of total delay **minutes** by cause:

| Cause | Share |
|---|---|
| Late aircraft (knock-on from a prior late flight) | **39.3%** |
| Carrier (airline-controlled) | **33.5%** |
| NAS (air-traffic/airport system) | 21.0% |
| Weather | 5.9% |
| Security | 0.2% |

Late-aircraft + carrier ≈ **73%** of delay minutes — most delay is the system rippling and airline operations, not weather.

### But weather *cancels* — it doesn't delay

Of the 2.9% of flights cancelled, the reason breakdown flips the story:

| Code | Reason | Share of cancellations |
|---|---|---|
| B | Weather | **56.4%** |
| A | Carrier | 27.3% |
| C | NAS | 16.2% |
| D | Security | 0.1% |

**The contrast is the insight:** weather is only ~6% of delay *minutes* but ~56% of *cancellations*. Airlines don't delay for weather — they cancel. Delay analysis and cancellation analysis are different questions with different drivers.

### Operational headline metrics (March 2026)

- **On-time rate: 73.2%** (arrived < 15 min late, not cancelled/diverted) — in line with typical DOT figures.
- **Cancelled: 2.9%** · **Diverted: 0.34%**

### Categorical structure

- **Carrier concentration:** Southwest (WN) alone is **20%** of flights; the top 5 (WN, DL, AA, OO, UA) are ~72%. A "by carrier" view is dominated by a handful of majors plus regionals (OO = SkyWest).
- **Departure-hour profile:** a pronounced **morning bank (6–8am, ~7% each)**, steady through the day, tapering after 8pm; overnight (2–4am) is a rounding error (<0.1%). The 840 midnight-hour (`dep_hour = 0`) flights are the red-eyes whose leading-zero times we deliberately preserved.
- **Busiest origins:** ORD (5.1%), DEN, ATL, DFW, PHX, LAX, MCO, CLT, LAS, SEA — the expected hub list, none exceeding ~5%.

---

## Implications for the pipeline

1. **Typed, selective ingestion is non-negotiable** — 92 of 110 columns are dropped; the survivors need explicit types (times as text, delays as numeric).
2. **NAs are signal, handled with domain rules** — the validation's "NA delay only allowed for cancelled/diverted" check encodes exactly this.
3. **Dashboards should default to median** for "typical delay" and reserve the mean for totals, given the skew.
4. **Delay vs. cancellation are separate analyses** — weather barely delays but dominates cancellations.
5. **Extreme-but-real tails exist** (48-hour delays here in March; 52 hours in April) — range validation must admit them, which is why the check's ceiling was widened to catch corruption without rejecting genuine outliers.
