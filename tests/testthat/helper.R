for (f in list.files(file.path("..", "..", "R"), full.names = TRUE)) {
  source(f)
}

fixture_path <- function(...) testthat::test_path("fixtures", ...)

# Builds the DuckDB schema from the committed fixtures into a temp file and
# returns an open read-write connection (caller disconnects).
build_fixture_db <- function() {
  db <- tempfile(fileext = ".duckdb")
  build_db(raw = fixture_path(), db = db)
  DBI::dbConnect(duckdb::duckdb(), dbdir = db)
}

# Two-question fixture for the aggregation stage: 2001-0 resolves 'a' on
# 2012-01-10 and 2002-0 resolves 'b' on 2012-01-25, so forecasts on the
# second question straddle the first one's resolution and exercise the
# trailing-accuracy cutoff.
build_aggregation_db <- function(min_history = 1L) {
  db <- tempfile(fileext = ".duckdb")
  build_db(raw = fixture_path("aggregation"), db = db)
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db)
  run_gjp_protocol(con)
  build_gjp_panel(con, min_history = min_history)
  con
}
