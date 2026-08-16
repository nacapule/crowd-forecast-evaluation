fb_fixture_dir <- function() fixture_path("forecastbench")

test_that("fb question reader classifies source types", {
  q <- read_fb_questions(
    file.path(fb_fixture_dir(), "2024-07-21-human.json")
  )
  expect_equal(nrow(q), 3)
  expect_equal(
    q$source_type[order(q$question_id)], c("dataset", "dataset", "market")
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
  expect_false(any(b$resolution_date > as.Date("2025-01-01")))
  expect_setequal(unique(b$horizon_days), c(7, 30))

  collapsed <- DBI::dbGetQuery(con,
    "SELECT p, n_submissions FROM fb_forecasts
     WHERE user_id = 'u_p1' AND question_id = 'q_data1'")
  expect_equal(collapsed$p, 0.8)
  expect_equal(collapsed$n_submissions, 2)
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
  expect_equal(n("question", "dataset_kept"), 2)
  expect_equal(n("forecast_row", "source_rows"), 6)
  expect_equal(n("forecast_row", "multi_submission_collapsed"), 1)
  expect_equal(n("forecast_row", "scored_rows_binary"), 6)
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
