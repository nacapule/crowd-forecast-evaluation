# Data notes — Good Judgment Project ACE surveys

Build-level reference for the data layer: source schemas, file-format quirks,
exclusion rules, and the DuckDB tables each `make` target produces. The
write-up in `analysis/manuscript.pdf` is the canonical statement of the
scoring protocols and the results; this file is what you read when you need
to know how a table was built. Counts below are produced by the pipeline
(`make data && make fb && make qa`) and reconciled against
`qa/qa_report.md`.

## Source

Good Judgment Project, 2016, "GJP Data", Harvard Dataverse, V1,
[doi:10.7910/DVN/BPCDH5](https://doi.org/10.7910/DVN/BPCDH5). License: CC0 1.0.

The dataset covers the Good Judgment Project's four seasons (2011–2015) in
IARPA's ACE geopolitical forecasting tournament. This project uses the survey
forecast files and the question file; the dataset's prediction-market files
(`pm_*`) record a different elicitation mechanism (market orders and
transactions, not probability surveys) and are out of scope.

Files used (verified against `data/manifest.csv` by size and MD5 before any
build):

| file | contents |
|---|---|
| `ifps.csv` | 617 questions (IFPs) with type, status, dates, resolution |
| `survey_fcasts.yr1.csv` … `yr4.csv` | individual survey forecasts, one row per answer option |

Two dataset readmes (`readme-2917338.txt`, `readme-2917350.txt`) document the
market data and the shared field codes respectively; the second is the
codebook for the condition and forecast-type codes summarized below.

Format quirks handled at ingest: `ifps.csv` uses classic-Mac CR line endings
and Latin-1 text (converted at the byte level, then to UTF-8); its dates are
`m/d/y`. The survey files are quoted CSV with `NA` strings and ISO dates, and
are loaded with explicit column types.

## Question structure

Each IFP carries `q_type`, and its `ifp_id` suffix encodes the same
information (verified: the suffix distribution equals the `q_type`
distribution):

- `q_type 0` — regular binomial or multinomial (355 of 617)
- `q_type 1–5` — conditional-IFP branches (172: 84 + 84 + 2 + 2)
- `q_type 6` — ordered multinomial (90)

`q_status` is `closed` (498) or `voided` (119); voided questions have no
outcome and were never scored. Outcomes are option letters `a`–`e`. All 119
missing outcomes and missing `date_closed` values belong to voided questions
(verified). 35 closed questions lack `date_suspend`; the forecast window
check falls back to `date_closed` for them.

## Analysis question set

The analysis set is **closed, non-voided, regular binary questions**
(`q_type = 0`, `n_opts = 2`): **303 of 617 IFPs**. Exclusions, one stated
reason per question (first matching rule wins): voided 119, ordered
multinomial 84, conditional branch 79, multinomial 32. The same counts are
written to `qa_accounting` and `qa/qa_report.md` by every build.

Rationale: binary questions make proper-score comparisons across aggregation
methods clean (a single probability per forecast); conditional branches score
only under the realized condition and ordered questions need distance-aware
scores. Both exclusions are counted in `qa_accounting`.

## Forecast structure

Survey files share one 16-column layout across all four years:
`ifp_id, ctt, cond, training, team, user_id, forecast_id, fcast_type,
answer_option, value, fcast_date, expertise, q_status, viewtime, year,
timestamp`. One row per answer option per forecast event; a forecast event is
identified by (`year`, `forecast_id`, `ifp_id`, `user_id`).

`fcast_type` codes: 0 new, 1 update, 2 affirm (no value change), 4 withdraw
(values show the last standing forecast; individual scoring stops at the
withdrawal date). Withdrawals are preserved and flagged; the scoring
protocol (not the data layer) decides carry-forward treatment.

Verified against the full build (2026-08-15): 3,143,460 source rows across
the four files; zero exact duplicates; zero probabilities outside [0, 1];
zero events whose option probabilities do not sum to 1; every forecast
`ifp_id` present in `ifps.csv`. Rows on questions outside the analysis set
account for 1,739,566 rows; the accepted set is 1,403,894 rows forming
701,947 forecast events, every one an exact a/b pair. In the binary event
view: 182,531 new forecasts, 396,010 updates, 115,242 affirms, 8,164
withdrawals. Events by year: 131,882 / 95,039 / 96,388 / 378,638
(years 1–4). Out-of-window events: 13,728 (flagged, kept; mostly years 1
and 4).

## Experimental conditions

ACE assigned participants to elicitation conditions (`ctt`, with `cond` as
its leading digit). Summarized from the dataset codebook:

- `1*` — independent individuals on survey platforms (variants: no training,
  probability training, scenario training; year-4 adds MOOF-platform and
  accountability variants)
- `2*` — individuals who could see crowd information (year 1)
- `3*` — prediction-market participants
- `4*` — teams (interacting; team id embedded in the code)
- `5*` — superforecaster teams (top performers promoted after year 1)

Consequences for analysis: team and superteam members are not independent
crowd members (they interact and share information), market participants are
elicited through prices rather than surveys, and the population shifts across
years (supers extracted after year 1; conditions added and dropped). The
**primary analysis population is condition group 1** (independent survey
individuals), with condition-group sensitivity checks and the population
shift stated as a limitation. Within group 1, training subconditions are
retained as covariates rather than filtered.

Verified composition of the accepted set: condition groups present in the
survey files are 1 (671,484 rows, 6,484 users), 2 (94,374 rows, 657 users,
year 1 only), 4 (417,254 rows, 2,592 users), and 5 (220,782 rows, 181
users). Group 3 does not appear — market participation is recorded only in
the `pm_*` files, as documented. The primary population contributes
**335,742 binary forecast events from 6,484 forecasters covering all 303
analysis questions**.

## Data layer

`make data` builds DuckDB tables from the verified raw files:

- `questions` — all 617 IFPs with parsed dates and derived type/status flags
- `questions_accepted` / `questions_rejected(reason)` — the analysis split
- `forecasts` — full forecast history, all years, exact duplicate rows
  dropped and counted
- `forecasts_accepted(in_window)` / `forecasts_rejected(reason)` — row-level
  split; rejection reasons are `question_not_in_analysis_set`,
  `probability_out_of_domain`, `option_sum_not_one`
- `binary_forecasts` — one row per accepted forecast event: `p` is the
  probability on option `a`; `resolved_to` is 1 when the question resolved
  `a`
- `qa_accounting` — the exact raw = accepted + rejected accounting

Out-of-window forecasts (before `date_start` or after
`coalesce(date_suspend, date_closed)`) are flagged (`in_window`), not
dropped: whether to score them is a protocol decision, and it is recorded in
the methods.

The QA gate (`make qa`) hard-fails the build on: probabilities outside
[0, 1] in the accepted set, accepted forecasts that do not join an accepted
question, accepted questions without an `a`/`b` outcome, accounting-identity
violations at either level, and binary-view row counts that do not match
accepted event counts. Soft checks (reported, not fatal): out-of-window
counts and unrecognized condition codes.

Two later layers build on this schema. `make fb` ingests the ForecastBench
2024-07-21 human round (fetched at a pinned upstream commit by
`scripts/fetch_forecastbench.sh`) into `fb_questions` / `fb_resolutions` /
`fb_forecasts` / `fb_binary` with its own accounting table. There, a forecast
is keyed by forecaster, question, **and resolution horizon**: the round sets
eight horizon dates (2024-07-28 through 2034-07-19) and each forecaster
answers every dataset question once per horizon.

The exclusions are a closed ledger. A hard QA rule checks it at both stages,
recounting the kept and scored tables instead of trusting the stored counts:

| stage | reason | entries |
|---|---|---:|
| source | all human-round entries | 55,372 |
| | no resolution date — market-sourced questions | 5,096 |
| | probability outside [0, 1] (values such as −0.05, 1.02) | 281 |
| | duplicate (forecaster, question, horizon) keys collapsed | 0 |
| kept | horizon entries carried forward | 49,995 |
| | question never resolved upstream | 2,368 |
| | horizon not covered by the round's resolution set | 18,028 |
| scored | `fb_binary` | 29,599 |

The second block is what makes this corpus a single snapshot rather than a
history: the round's resolution set covers 521 of the possible
question-horizons, so forecasts aimed at 2027, 2029 and 2034 have nothing to
score against yet. At the question level, 110 of the 200 human-round
questions are dataset-sourced; 105 of those carry a resolution and are
scored, and 5 carry none at all (four DBnomics temperature series and one
Wikipedia question). `make scores`
applies the GJP scoring protocol (segment-based daily carry-forward,
withdrawal handling, year-1-defined top decile) producing
`gjp_daily_events`, `gjp_segments`, `gjp_user_question_scores`, and the
cohort-labeled `gjp_events`. Both layers add hard QA checks. The protocol
definitions and all results live in `analysis/scoring-calibration.qmd`.

The scoring cell is (question, forecaster, condition code, tournament year)
rather than (question, forecaster). Participants were re-randomized between
seasons, so on the 31 questions that straddle a year boundary a forecaster
can appear under two experimental conditions on the same question — 3,729
such cases. Keying on the condition code keeps each cohort's days its own.

`make experiments` adds the aggregation layer: `gjp_panel` expands the
scoring segments of the primary population into one row per (question,
forecaster, day) — 12,933,059 rows over 33,204 question-days — and attaches
each forecaster's trailing accuracy as of that day via an as-of join on
questions that finished scoring strictly before it. A QA check requires the
panel's day counts to equal the protocol's, forecaster by forecaster, which
is what makes the crowd and the average-member baseline the same population.
Results land in `agg_results`, `agg_settings`, `agg_sweep`,
`agg_gjp_questions`, `agg_fb_questions`, and `agg_crowd_size`, and are
written to `analysis/results/` as CSV.
