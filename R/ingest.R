# Ingest: raw GJP files -> normalized DuckDB schema.
#
# Source layout (see docs/data-notes.md and the dataset readmes):
#   ifps.csv                questions, one row per IFP (CR-only line endings)
#   survey_fcasts.yrN.csv   survey forecasts, one row per answer option

db_path <- function() file.path("data", "db", "gjp.duckdb")

# ifps.csv uses classic-Mac CR line endings, non-UTF-8 (Latin-1) text, and
# m/d/y dates. Line endings are fixed at the byte level before any string
# handling so the encoding cannot break the conversion.
read_ifps <- function(path) {
  bytes <- readBin(path, "raw", file.size(path))
  bytes[bytes == as.raw(0x0d)] <- as.raw(0x0a)
  txt <- rawToChar(bytes)
  if (!all(validUTF8(txt))) {
    txt <- iconv(txt, from = "latin1", to = "UTF-8")
  }
  readr::read_csv(
    I(txt),
    col_types = readr::cols(
      ifp_id = readr::col_character(),
      q_type = readr::col_integer(),
      q_text = readr::col_character(),
      q_desc = readr::col_character(),
      q_status = readr::col_character(),
      date_start = readr::col_character(),
      date_suspend = readr::col_character(),
      date_to_close = readr::col_character(),
      date_closed = readr::col_character(),
      outcome = readr::col_character(),
      short_title = readr::col_character(),
      days_open = readr::col_double(),
      n_opts = readr::col_integer(),
      options = readr::col_character()
    ),
    na = c("", "NA")
  )
}

# Dates in ifps.csv are m/d/y, some with a trailing time of day.
parse_mdy <- function(x) {
  as.Date(sub(" .*$", "", x), format = "%m/%d/%y")
}

prepare_questions <- function(ifps) {
  out <- dplyr::mutate(
    ifps,
    base_id = sub("-.*$", "", ifp_id),
    suffix = sub("^[^-]*-?", "", ifp_id),
    q_status = tolower(q_status),
    date_start = parse_mdy(date_start),
    date_suspend = parse_mdy(date_suspend),
    date_to_close = parse_mdy(date_to_close),
    date_closed = parse_mdy(date_closed),
    is_conditional = q_type >= 1 & q_type <= 5,
    is_ordered = q_type == 6,
    is_binary = q_type == 0 & n_opts == 2,
    is_voided = q_status == "voided"
  )
  dplyr::select(
    out,
    ifp_id, base_id, suffix, q_type, n_opts, q_status, outcome,
    date_start, date_suspend, date_to_close, date_closed,
    is_conditional, is_ordered, is_binary, is_voided,
    short_title, q_text, options, days_open
  )
}

survey_columns <- function() {
  c(
    ifp_id = "VARCHAR", ctt = "VARCHAR", cond = "INTEGER",
    training = "VARCHAR", team = "VARCHAR", user_id = "VARCHAR",
    forecast_id = "BIGINT", fcast_type = "INTEGER",
    answer_option = "VARCHAR", value = "DOUBLE", fcast_date = "DATE",
    expertise = "INTEGER", q_status = "VARCHAR", viewtime = "DOUBLE",
    year = "INTEGER", timestamp = "TIMESTAMP"
  )
}

# Loads survey CSVs straight into DuckDB (typed, NA-aware), keeping full
# forecast history. Exact duplicate rows are dropped and counted.
load_survey_forecasts <- function(con, paths) {
  cols <- survey_columns()
  col_spec <- paste(sprintf("'%s': '%s'", names(cols), cols), collapse = ", ")
  path_list <- paste(sprintf("'%s'", paths), collapse = ", ")
  DBI::dbExecute(con, sprintf(
    "CREATE OR REPLACE TABLE forecasts_raw AS
     SELECT * FROM read_csv([%s],
       header = true, nullstr = 'NA', quote = '\"', columns = {%s})",
    path_list, col_spec
  ))
  DBI::dbExecute(con,
    "CREATE OR REPLACE TABLE forecasts AS
     SELECT DISTINCT * FROM forecasts_raw"
  )
  raw_n <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM forecasts_raw")$n
  kept_n <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM forecasts")$n
  DBI::dbExecute(con, "DROP TABLE forecasts_raw")
  list(raw_rows = raw_n, kept_rows = kept_n, duplicate_rows = raw_n - kept_n)
}

# Question-level acceptance for the analysis set: closed, non-voided,
# regular binary questions. Every rejection carries a single stated reason
# (first matching rule wins).
build_question_sets <- function(con) {
  DBI::dbExecute(con,
    "CREATE OR REPLACE TABLE questions_rejected AS
     SELECT ifp_id,
       CASE
         WHEN is_voided THEN 'voided'
         WHEN is_conditional THEN 'conditional_ifp'
         WHEN is_ordered THEN 'ordered_multinomial'
         WHEN q_status <> 'closed' THEN 'not_closed'
         WHEN NOT is_binary THEN 'multinomial'
         ELSE NULL
       END AS reason
     FROM questions
     WHERE reason IS NOT NULL"
  )
  DBI::dbExecute(con,
    "CREATE OR REPLACE TABLE questions_accepted AS
     SELECT q.* FROM questions q
     ANTI JOIN questions_rejected r USING (ifp_id)"
  )
}

# Forecast-level acceptance mirrors the question set and drops rows that
# cannot be scored. Out-of-window forecasts are flagged, not dropped; the
# scoring protocol decides how to treat them.
build_forecast_sets <- function(con) {
  DBI::dbExecute(con,
    "CREATE OR REPLACE TABLE forecasts_rejected AS
     SELECT f.*,
       CASE
         WHEN q.ifp_id IS NULL THEN 'question_not_in_analysis_set'
         WHEN f.value IS NULL OR f.value < 0 OR f.value > 1
           THEN 'probability_out_of_domain'
         WHEN bad_sum.forecast_key IS NOT NULL THEN 'option_sum_not_one'
         ELSE NULL
       END AS reason
     FROM forecasts f
     LEFT JOIN questions_accepted q USING (ifp_id)
     LEFT JOIN (
       SELECT year, forecast_id, ifp_id, user_id,
              concat_ws('-', year, forecast_id, ifp_id, user_id)
                AS forecast_key
       FROM forecasts
       GROUP BY year, forecast_id, ifp_id, user_id
       HAVING abs(sum(value) - 1.0) > 1e-6
     ) bad_sum USING (year, forecast_id, ifp_id, user_id)
     WHERE reason IS NOT NULL"
  )
  DBI::dbExecute(con,
    "CREATE OR REPLACE TABLE forecasts_accepted AS
     SELECT f.*,
       f.fcast_date >= q.date_start
         AND f.fcast_date <= coalesce(q.date_suspend, q.date_closed)
         AS in_window
     FROM forecasts f
     JOIN questions_accepted q USING (ifp_id)
     ANTI JOIN forecasts_rejected r
       USING (year, forecast_id, ifp_id, user_id, answer_option)"
  )
}

# One row per forecast event on a binary question: p is the probability
# assigned to option 'a'; resolved_to is 1 when the question resolved 'a'.
build_binary_view <- function(con) {
  DBI::dbExecute(con,
    "CREATE OR REPLACE TABLE binary_forecasts AS
     SELECT
       f.ifp_id, f.year, f.forecast_id, f.user_id, f.ctt, f.cond,
       f.training, f.team, f.fcast_type, f.fcast_date, f.timestamp,
       f.in_window, f.value AS p,
       CASE WHEN q.outcome = 'a' THEN 1 ELSE 0 END AS resolved_to,
       q.outcome, q.date_start, q.date_suspend, q.date_closed
     FROM forecasts_accepted f
     JOIN questions_accepted q USING (ifp_id)
     WHERE f.answer_option = 'a'"
  )
}

write_accounting <- function(con, load_stats) {
  DBI::dbExecute(con, "DROP TABLE IF EXISTS qa_accounting")
  DBI::dbExecute(con,
    "CREATE TABLE qa_accounting (
       level VARCHAR, reason VARCHAR, n BIGINT)"
  )
  DBI::dbExecute(con, sprintf(
    "INSERT INTO qa_accounting VALUES
       ('forecast_row', 'source_rows', %d),
       ('forecast_row', 'exact_duplicate_dropped', %d)",
    load_stats$raw_rows, load_stats$duplicate_rows
  ))
  DBI::dbExecute(con,
    "INSERT INTO qa_accounting
     SELECT 'question', reason, count(*) FROM questions_rejected
     GROUP BY reason"
  )
  DBI::dbExecute(con,
    "INSERT INTO qa_accounting
     SELECT 'question', 'accepted', count(*) FROM questions_accepted"
  )
  DBI::dbExecute(con,
    "INSERT INTO qa_accounting
     SELECT 'forecast_row', reason, count(*) FROM forecasts_rejected
     GROUP BY reason"
  )
  DBI::dbExecute(con,
    "INSERT INTO qa_accounting
     SELECT 'forecast_row', 'accepted', count(*) FROM forecasts_accepted"
  )
}

# Full build: raw files -> DuckDB analysis schema.
build_db <- function(raw = raw_dir(), db = db_path()) {
  dir.create(dirname(db), recursive = TRUE, showWarnings = FALSE)
  if (file.exists(db)) file.remove(db)
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)

  questions <- prepare_questions(read_ifps(file.path(raw, "ifps.csv")))
  DBI::dbWriteTable(con, "questions", questions)

  survey_paths <- sort(list.files(
    raw, pattern = "^survey_fcasts\\.yr[0-9]\\.csv$", full.names = TRUE
  ))
  load_stats <- load_survey_forecasts(con, survey_paths)

  build_question_sets(con)
  build_forecast_sets(con)
  build_binary_view(con)
  write_accounting(con, load_stats)
  invisible(load_stats)
}
