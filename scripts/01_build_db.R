source(file.path("R", "fetch.R"))
source(file.path("R", "ingest.R"))

require_verified_raw()
stats <- build_db()
cat(sprintf(
  "built %s: %d source rows, %d duplicates dropped\n",
  db_path(), stats$raw_rows, stats$duplicate_rows
))
