fb_fixture_dir <- function() fixture_path("forecastbench")

test_that("fb question reader classifies source types", {
  q <- read_fb_questions(
    file.path(fb_fixture_dir(), "2024-07-21-human.json")
  )
  expect_equal(nrow(q), 4)
  expect_equal(
    q$source_type[order(q$question_id)],
    c("dataset", "dataset", "dataset", "market")
  )
})

test_that("fb resolution reader drops combos and counts them", {
  r <- read_fb_resolutions(
    file.path(fb_fixture_dir(), "2024-07-21_resolution_set.json")
  )
  expect_equal(r$n_total, 7)
  expect_equal(r$n_combo, 1)
  expect_equal(nrow(r$resolutions), 6)
  expect_false(any(vapply(r$resolutions$question_id, is.list, logical(1))))
})

test_that("build_fb keeps only dataset questions with 0/1 resolutions", {
  con <- build_fixture_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  build_fb(con, dir = fb_fixture_dir())
  b <- DBI::dbGetQuery(con, "SELECT * FROM fb_binary ORDER BY cohort, user_id")
  expect_equal(nrow(b), 6)
  expect_false(any(b$question_id == "q_mkt1"))
  # q_data3 is a dataset question the resolution set never covers.
  expect_false(any(b$question_id == "q_data3"))
  expect_false(any(b$resolution_date > as.Date("2025-01-01")))
  expect_setequal(unique(b$horizon_days), c(7, 30))
})

test_that("horizon forecasts stay separate rather than averaging together", {
  con <- build_fixture_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  build_fb(con, dir = fb_fixture_dir())
  # u_s1 gave 0.8 at the 7-day horizon and 0.3 at the 30-day horizon on the
  # same question; each horizon keeps its own forecast.
  s1 <- DBI::dbGetQuery(con,
    "SELECT resolution_date, p FROM fb_binary
     WHERE user_id = 'u_s1' AND question_id = 'q_data1'
     ORDER BY resolution_date")
  expect_equal(s1$p, c(0.8, 0.3))

  # Two entries share one (forecaster, question, horizon) key; the guard
  # averages them and records the collapse.
  dup <- DBI::dbGetQuery(con,
    "SELECT p, n_entries FROM fb_forecasts
     WHERE user_id = 'u_p1' AND question_id = 'q_data1'
       AND resolution_date = DATE '2024-08-20'")
  expect_equal(dup$p, 0.8)
  expect_equal(dup$n_entries, 2)
})

test_that("fb accounting records exclusions", {
  con <- build_fixture_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  build_fb(con, dir = fb_fixture_dir())
  acct <- DBI::dbGetQuery(con, "SELECT * FROM fb_accounting")
  n <- function(level, reason) {
    acct$n[acct$level == level & acct$reason == reason]
  }
  expect_equal(n("resolution", "source_entries_all_sets"), 7)
  expect_equal(n("resolution", "combo_dropped"), 1)
  expect_equal(n("resolution", "human_set"), 5)
  expect_equal(n("question", "market_excluded"), 1)
  expect_equal(n("question", "dataset_kept"), 3)
  expect_equal(n("question", "dataset_scored"), 2)
  expect_equal(n("question", "dataset_no_resolution"), 1)
  expect_equal(n("forecast_row", "source_entries"), 13)
  expect_equal(n("forecast_row", "market_question_entries"), 2)
  expect_equal(n("forecast_row", "probability_out_of_domain"), 1)
  expect_equal(n("forecast_row", "duplicate_horizon_entries_collapsed"), 1)
  expect_equal(n("forecast_row", "horizon_entries_kept"), 9)
  # q_data3 never resolved; q_data2's far horizon is not resolved yet.
  expect_equal(n("forecast_row", "entries_on_unresolved_question"), 2)
  expect_equal(n("forecast_row", "horizon_without_resolution"), 1)
  expect_equal(n("forecast_row", "scored_rows_binary"), 6)
})

test_that("fb accounting closes: every source entry is scored or excluded", {
  con <- build_fixture_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  build_fb(con, dir = fb_fixture_dir())
  res <- run_qa_checks(con)
  for (check in c("fb_question_accounting_identity",
                  "fb_forecast_accounting_identity")) {
    expect_equal(res$n_violations[res$check == check], 0)
  }

  # Drop a scored row without recording a reason for it — what a new filter
  # added to fb_binary would look like. The identity must catch it.
  DBI::dbExecute(con, "DELETE FROM fb_binary WHERE user_id = 'u_p2'")
  broken <- run_qa_checks(con)
  expect_gt(
    broken$n_violations[broken$check == "fb_forecast_accounting_identity"], 0
  )
})

test_that("qa hard checks pass with fb and score layers present", {
  con <- build_fixture_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  build_fb(con, dir = fb_fixture_dir())
  run_gjp_protocol(con)
  res <- run_qa_checks(con)
  expect_true(all(res$pass[res$hard]))
  expect_true("fb_probability_and_resolution_domain" %in% res$check)
  expect_true("gjp_scores_within_brier_range" %in% res$check)
})
