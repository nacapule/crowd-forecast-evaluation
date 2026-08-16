# ForecastBench ingest: 2024-07-21 human round -> DuckDB.
#
# Humans forecast each question once (by the due date); the benchmark then
# scores that single forecast at several later resolution dates (horizons).
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

  # A forecaster occasionally submits several values for one question; with
  # no timestamps in the file, the mean is used and the case is counted.
  DBI::dbExecute(con,
    "CREATE OR REPLACE TABLE fb_forecasts AS
     SELECT cohort, user_id, question_id, min(source) AS source,
            min(due_date) AS due_date,
            avg(p) AS p, count(*) AS n_submissions
     FROM fb_forecasts_raw
     GROUP BY cohort, user_id, question_id"
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
     JOIN fb_resolutions r USING (question_id)
     WHERE q.source_type = 'dataset'
       AND r.resolved
       AND r.resolved_to IN (0.0, 1.0)
       AND f.p IS NOT NULL AND f.p >= 0 AND f.p <= 1"
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
  acct("resolution", "source_entries_all_sets", res$n_total)
  acct("resolution", "combo_dropped", res$n_combo)
  acct("resolution", "human_set", nrow(resolutions))
  acct("question", "human_set", nrow(questions))
  acct("question", "market_excluded",
       sum(questions$source_type == "market"))
  acct("question", "dataset_kept",
       sum(questions$source_type == "dataset"))
  acct("forecast_row", "source_rows", nrow(forecasts))
  acct("forecast_row", "multi_submission_collapsed",
       DBI::dbGetQuery(con,
         "SELECT count(*) FROM fb_forecasts WHERE n_submissions > 1")[[1]])
  acct("forecast_row", "scored_rows_binary",
       DBI::dbGetQuery(con, "SELECT count(*) FROM fb_binary")[[1]])
  invisible(TRUE)
}
