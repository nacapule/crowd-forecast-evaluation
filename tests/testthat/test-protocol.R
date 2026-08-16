protocol_db <- function() {
  con <- build_fixture_db()
  run_gjp_protocol(con)
  con
}

test_that("segment scoring matches hand-computed day-weighted Brier", {
  con <- protocol_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  s <- DBI::dbGetQuery(con,
    "SELECT user_id, ifp_id, days_held, mean_daily_brier
     FROM gjp_user_question_scores ORDER BY user_id, ifp_id")

  u1 <- s[s$user_id == "u1" & s$ifp_id == "1001-0", ]
  expect_equal(u1$days_held, 117)
  expect_equal(u1$mean_daily_brier, 0.08, tolerance = 1e-12)

  u9 <- s[s$user_id == "u9", ]
  expect_equal(u9$days_held, 117)
  expect_equal(
    u9$mean_daily_brier,
    (26 * brier_score(0.6, 0) + 91 * brier_score(0.3, 0)) / 117,
    tolerance = 1e-12
  )
})

test_that("same-day updates keep only the last forecast of the day", {
  con <- protocol_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  day <- DBI::dbGetQuery(con,
    "SELECT p FROM gjp_daily_events
     WHERE user_id = 'u9' AND fcast_date = DATE '2011-10-01'")
  expect_equal(day$p, 0.3)
})

test_that("withdrawals score their own day only", {
  con <- protocol_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  u8 <- DBI::dbGetQuery(con,
    "SELECT days_held, mean_daily_brier FROM gjp_user_question_scores
     WHERE user_id = 'u8'")
  expect_equal(u8$days_held, 1)
  expect_equal(u8$mean_daily_brier, brier_score(0.5, 1), tolerance = 1e-12)
})

test_that("forecasts after the scoring window contribute nothing", {
  con <- protocol_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(DBI::dbGetQuery(con,
    "SELECT count(*) FROM gjp_user_question_scores
     WHERE user_id = 'u7'")[[1]], 0)
  expect_equal(DBI::dbGetQuery(con,
    "SELECT count(*) FROM gjp_events WHERE user_id = 'u7'")[[1]], 0)
})

test_that("top decile selects by year-1 score without labeling year 1", {
  con <- protocol_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  expect_equal(
    DBI::dbGetQuery(con, "SELECT count(*) FROM gjp_top_decile")[[1]], 0
  )
  build_top_decile(con, min_questions = 1)
  td <- DBI::dbGetQuery(con, "SELECT user_id FROM gjp_top_decile")
  expect_equal(td$user_id, "u1")
  build_gjp_events(con)
  cohorts <- DBI::dbGetQuery(con,
    "SELECT DISTINCT cohort FROM gjp_events WHERE user_id = 'u1'")
  expect_equal(cohorts$cohort, "gjp_individual")
})
