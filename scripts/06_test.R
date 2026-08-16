# Runs the unit tests and records the totals.
#
# The counts are written to qa/test-summary.csv so that anything quoting them
# — the README, the manuscript — reads them from a build artefact instead of
# carrying a number that can quietly go stale.

res <- testthat::test_dir("tests/testthat", stop_on_failure = TRUE,
                          reporter = "summary")
df <- as.data.frame(res)

summary_df <- data.frame(
  metric = c("files", "tests", "assertions"),
  n = c(length(unique(df$file)), nrow(df), sum(df$passed)),
  stringsAsFactors = FALSE
)
dir.create("qa", showWarnings = FALSE)
utils::write.csv(summary_df, file.path("qa", "test-summary.csv"),
                 row.names = FALSE)
cat(sprintf("\n%d assertions across %d tests in %d files\n",
            summary_df$n[3], summary_df$n[2], summary_df$n[1]))
