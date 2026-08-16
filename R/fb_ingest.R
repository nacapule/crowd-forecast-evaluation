# ForecastBench ingest: 2024-07-21 human round -> DuckDB.
#
# A forecaster answers each dataset question once per resolution horizon: the
# round sets eight horizon dates and the forecast files carry one entry per
# (forecaster, question, resolution_date). Entries with no resolution date
# belong to the market-sourced questions, which resolve on their own schedule.
# Horizon is therefore part of the forecast key, not a fan-out of one value.
#
# Market-sourced questions that have not resolved by a horizon are scored
# upstream against the market price at that date — a continuous proxy, not
# an outcome — so the analysis here keeps only dataset-source questions
# (acled, dbnomics, fred, wikipedia, yfinance) with genuine 0/1 resolutions.
# Exclusions are counted, never silent.

fb_dir <- function() file.path("data", "raw", "forecastbench")

fb_dataset_sources <- function() {
  c("acled", "dbnomics", "fred", "wikipedia", "yfinance")
}

read_fb_questions <- function(path) {
  q <- jsonlite::fromJSON(path, simplifyDataFrame = TRUE)$questions
  data.frame(
    question_id = q$id,
    source = q$source,
    source_type = ifelse(
      q$source %in% fb_dataset_sources(), "dataset", "market"
    ),
    question = q$question,
    stringsAsFactors = FALSE
  )
}

# Combo entries (paired questions, LLM set only) have list-valued ids and are
# dropped with a count; the human set contains no combos. Returns the kept
# data frame plus total/combo entry counts for the accounting table.
read_fb_resolutions <- function(path) {
  r <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  entries <- r$resolutions
  is_combo <- vapply(entries, function(x) length(x$id) != 1, logical(1))
  keep <- entries[!is_combo]
  df <- data.frame(
    question_id = vapply(keep, function(x) x$id[[1]], character(1)),
    source = vapply(keep, function(x) x$source, character(1)),
    resolution_date = as.Date(
      vapply(keep, function(x) x$resolution_date, character(1))
    ),
    resolved_to = vapply(keep, function(x) as.numeric(x$resolved_to),
                         numeric(1)),
    resolved = vapply(keep, function(x) isTRUE(x$resolved), logical(1)),
    stringsAsFactors = FALSE
  )
  list(resolutions = df, n_total = length(entries), n_combo = sum(is_combo))
}

read_fb_forecasts <- function(path, cohort) {
  f <- jsonlite::fromJSON(path, simplifyDataFrame = TRUE)
  due_date <- as.Date(f$forecast_due_date)
  fc <- f$forecasts
  data.frame(
    cohort = cohort,
    user_id = fc$user_id,
    question_id = fc$id,
    source = fc$source,
    p = as.numeric(fc$forecast),
    due_date = due_date,
    resolution_date = as.Date(fc$resolution_date),
    stringsAsFactors = FALSE
  )
}

# Builds fb_questions, fb_resolutions, fb_forecasts, fb_binary, and
# fb_accounting inside the existing database. fb_binary carries one row per
# (forecaster, question, horizon) with a genuine 0/1 resolution.
build_fb <- function(con, dir = fb_dir()) {
  questions <- read_fb_questions(
    file.path(dir, "2024-07-21-human.json")
  )
  res <- read_fb_resolutions(
    file.path(dir, "2024-07-21_resolution_set.json")
  )
  resolutions <- res$resolutions[
    res$resolutions$question_id %in% questions$question_id,
  ]

  forecasts <- rbind(
    read_fb_forecasts(
      file.path(dir, "2024-07-21.ForecastBench.human_super_individual.json"),
      cohort = "fb_super"
    ),
    read_fb_forecasts(
      file.path(dir, "2024-07-21.ForecastBench.human_public_individual.json"),
      cohort = "fb_public"
    )
  )

  DBI::dbWriteTable(con, "fb_questions", questions, overwrite = TRUE)
  DBI::dbWriteTable(con, "fb_resolutions", resolutions, overwrite = TRUE)
  DBI::dbWriteTable(con, "fb_forecasts_raw", forecasts, overwrite = TRUE)

  # One row per (forecaster, question, horizon). Entries without a resolution
  # date are the market-question submissions; a few hundred public entries
  # sit just outside [0, 1] (rounding artefacts such as -0.05 or 1.02). Both
  # are dropped here and counted below. The group-by is a guard rather than a
  # policy: this round holds no duplicate keys, and any that appeared would
  # be averaged and reported by `duplicate_horizon_entries_collapsed`.
  DBI::dbExecute(con,
    "CREATE OR REPLACE TABLE fb_forecasts AS
     SELECT cohort, user_id, question_id, resolution_date,
            min(source) AS source, min(due_date) AS due_date,
            avg(p) AS p, count(*) AS n_entries
     FROM fb_forecasts_raw
     WHERE resolution_date IS NOT NULL
       AND p IS NOT NULL AND p >= 0 AND p <= 1
     GROUP BY cohort, user_id, question_id, resolution_date"
  )

  DBI::dbExecute(con,
    "CREATE OR REPLACE TABLE fb_binary AS
     SELECT
       f.cohort, f.user_id, f.question_id, q.source, q.source_type,
       f.p, r.resolved_to,
       r.resolution_date,
       date_diff('day', f.due_date, r.resolution_date) AS horizon_days
     FROM fb_forecasts f
     JOIN fb_questions q USING (question_id)
     JOIN fb_resolutions r USING (question_id, resolution_date)
     WHERE q.source_type = 'dataset'
       AND r.resolved
       AND r.resolved_to IN (0.0, 1.0)"
  )

  DBI::dbExecute(con, "DROP TABLE IF EXISTS fb_accounting")
  DBI::dbExecute(con,
    "CREATE TABLE fb_accounting (level VARCHAR, reason VARCHAR, n BIGINT)"
  )
  acct <- function(level, reason, n) {
    DBI::dbExecute(con, sprintf(
      "INSERT INTO fb_accounting VALUES ('%s', '%s', %d)", level, reason, n
    ))
  }
  n1 <- function(sql) DBI::dbGetQuery(con, sql)[[1]]
  acct("resolution", "source_entries_all_sets", res$n_total)
  acct("resolution", "combo_dropped", res$n_combo)
  acct("resolution", "human_set", nrow(resolutions))

  acct("question", "human_set", nrow(questions))
  acct("question", "market_excluded",
       sum(questions$source_type == "market"))
  acct("question", "dataset_kept",
       sum(questions$source_type == "dataset"))
  # Not every dataset question carries a resolution: the round's resolution
  # set omits a few outright, and those leave no scored row. Counted here so
  # dataset_kept = dataset_scored + dataset_no_resolution holds.
  acct("question", "dataset_scored",
       n1("SELECT count(DISTINCT question_id) FROM fb_binary"))
  acct("question", "dataset_no_resolution",
       n1("SELECT count(*) FROM fb_questions
           WHERE source_type = 'dataset'
             AND question_id NOT IN (SELECT question_id FROM fb_resolutions)"))

  acct("forecast_row", "source_entries", nrow(forecasts))
  acct("forecast_row", "market_question_entries",
       sum(is.na(forecasts$resolution_date)))
  acct("forecast_row", "probability_out_of_domain",
       sum(!is.na(forecasts$resolution_date) &
             (is.na(forecasts$p) | forecasts$p < 0 | forecasts$p > 1)))
  acct("forecast_row", "duplicate_horizon_entries_collapsed",
       n1("SELECT coalesce(sum(n_entries - 1), 0) FROM fb_forecasts"))
  acct("forecast_row", "horizon_entries_kept",
       n1("SELECT count(*) FROM fb_forecasts"))
  # A horizon can only be scored once the round's resolution set covers it.
  # Roughly two in five kept entries sit at a horizon it does not: the far
  # horizons run to 2034, and a few questions never resolved at all. Both are
  # counted rather than lost at the join that builds fb_binary.
  acct("forecast_row", "entries_on_unresolved_question",
       n1("SELECT count(*) FROM fb_forecasts
           WHERE question_id NOT IN (SELECT question_id FROM fb_resolutions)"))
  acct("forecast_row", "horizon_without_resolution",
       n1("SELECT count(*) FROM fb_forecasts f
           WHERE f.question_id IN (SELECT question_id FROM fb_resolutions)
             AND NOT EXISTS (
               SELECT 1 FROM fb_resolutions r
               WHERE r.question_id = f.question_id
                 AND r.resolution_date = f.resolution_date
                 AND r.resolved AND r.resolved_to IN (0.0, 1.0))"))
  acct("forecast_row", "scored_rows_binary",
       n1("SELECT count(*) FROM fb_binary"))
  invisible(TRUE)
}
