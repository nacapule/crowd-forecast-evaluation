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
