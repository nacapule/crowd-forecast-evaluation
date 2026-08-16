source(file.path("R", "ingest.R"))
source(file.path("R", "protocol.R"))

con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db_path())
on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
run_gjp_protocol(con)
summary <- DBI::dbGetQuery(con,
  "SELECT cohort, count(*) AS events, count(DISTINCT user_id) AS users
   FROM gjp_events GROUP BY cohort ORDER BY cohort")
print(summary, row.names = FALSE)
cat(sprintf(
  "user-question scores: %d rows; top-decile cohort: %d users\n",
  DBI::dbGetQuery(con,
    "SELECT count(*) FROM gjp_user_question_scores")[[1]],
  DBI::dbGetQuery(con, "SELECT count(*) FROM gjp_top_decile")[[1]]
))
