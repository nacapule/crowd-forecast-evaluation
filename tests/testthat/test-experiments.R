test_that("run_bounds finds the runs of a sorted key", {
  b <- run_bounds(c("a", "a", "b", "c", "c", "c"))
  expect_equal(b$start, c(1L, 3L, 4L))
  expect_equal(b$end, c(2L, 3L, 6L))
  b2 <- run_bounds(c("a", "a", "a"), c(1L, 2L, 2L))
  expect_equal(b2$start, c(1L, 2L))
  expect_equal(b2$end, c(1L, 3L))
  expect_equal(run_bounds(character(0))$start, integer(0))
})

test_that("thin_index keeps everything below the cap and spreads above it", {
  expect_equal(thin_index(4, 30), 1:4)
  expect_equal(thin_index(100, 3), c(1, 50, 100))
})

test_that("the day panel holds exactly the days the scoring protocol counts", {
  con <- build_aggregation_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  res <- run_qa_checks(con)
  panel_checks <- c("gjp_panel_days_match_scored_days",
                    "gjp_panel_one_row_per_forecaster_day")
  expect_true(all(panel_checks %in% res$check))
  expect_true(all(res$pass[res$check %in% panel_checks]))

  shape <- DBI::dbGetQuery(con,
    "SELECT count(*) AS rows, count(DISTINCT ifp_id || day) AS question_days
     FROM gjp_panel")
  expect_equal(shape$rows, 115)
  expect_equal(shape$question_days, 31)
})

test_that("the panel QA check catches a forecaster the protocol never scored", {
  con <- build_aggregation_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(con,
    "INSERT INTO gjp_panel
     SELECT ifp_id, q_year, day, 'ghost', p, resolved_to, trailing_score
     FROM gjp_panel LIMIT 1")
  res <- run_qa_checks(con)
  expect_false(res$pass[res$check == "gjp_panel_days_match_scored_days"])
})

test_that("trailing accuracy only counts questions resolved before the day", {
  con <- build_aggregation_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  # 2001-0 stops scoring on 2012-01-10, so a forecast standing that same day
  # must not yet see its score; the next day it may.
  ua <- DBI::dbGetQuery(con,
    "SELECT day, trailing_score FROM gjp_panel
     WHERE ifp_id = '2002-0' AND user_id = 'uA'
       AND day BETWEEN DATE '2012-01-09' AND DATE '2012-01-12'
     ORDER BY day")
  expect_equal(as.character(ua$day),
               c("2012-01-09", "2012-01-10", "2012-01-11", "2012-01-12"))
  expect_true(all(is.na(ua$trailing_score[1:2])))
  expect_equal(ua$trailing_score[3:4], rep(brier_score(0.9, 1), 2))

  # No forecaster carries a trailing score on the first question at all.
  expect_equal(DBI::dbGetQuery(con,
    "SELECT count(*) FROM gjp_panel
     WHERE ifp_id = '2001-0' AND trailing_score IS NOT NULL")[[1]], 0)
})

test_that("crowd scores are day-weighted question means", {
  con <- build_aggregation_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  fns <- list(mean = agg_mean, median = agg_median)
  s <- crowd_scores_gjp(con, fns, years = 1L)
  early <- s[s$question_id == "2001-0", ]
  expect_equal(early$n_days, c(10, 10))
  expect_equal(early$brier[early$rule == "median"], brier_score(0.6, 1))
  expect_equal(early$brier[early$rule == "mean"], brier_score(0.54, 1))
})

test_that("select crowd scores and counts its fallback days", {
  con <- build_aggregation_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  s <- crowd_scores_gjp(con, list(median = agg_median), years = 1L,
                        select_ks = 2)
  late <- s[s$question_id == "2002-0" & s$rule == "select_crowd_k2", ]
  # Ten of the 21 days have too little history and revert to the whole
  # crowd (which is uA alone, on 0.2); the rest use uA and uD.
  expect_equal(late$fallback_rate, 10 / 21)
  expect_equal(
    late$brier,
    (10 * brier_score(0.2, 0) + 11 * brier_score(0.3, 0)) / 21
  )
  expect_true(is.na(s$fallback_rate[s$rule == "median"][1]))
})

test_that("the individual baseline uses the same days as the crowd", {
  con <- build_aggregation_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  base <- individual_baseline_gjp(con, years = 1L)
  early <- base$brier[base$question_id == "2001-0"]
  expect_equal(early, mean(brier_score(c(0.9, 0.1, 0.6, 0.7, 0.4), 1)))
  expect_setequal(base$question_id, c("2001-0", "2002-0"))
})

test_that("tuning refuses to look at evaluation years", {
  ok <- data.frame(rule = "mean", q_year = c(1L, 2L), brier = 0.3)
  expect_true(assert_tuning_only(ok))
  leaked <- data.frame(rule = "mean", q_year = c(1L, 3L), brier = 0.3)
  expect_error(assert_tuning_only(leaked), "evaluation-year data")
  expect_length(intersect(tuning_years(), evaluation_years()), 0)
})

test_that("tuning candidates cover the grid with bound parameters", {
  grid <- list(trim = c(0.1, 0.2), hd_trim = 0.1, soften = 0.1,
               extremize_a = c(1, 2), select_k = 5)
  cand <- tuning_candidates(grid)
  expect_equal(length(cand), 6)
  expect_true("trimmed_mean@0.20" %in% names(cand))
  # Each closure keeps its own parameter rather than the last one in the loop.
  x <- c(0.1, 0.2, 0.5, 0.8, 0.9)
  expect_equal(cand[["trimmed_mean@0.10"]](x), agg_trimmed_mean(x, 0.1))
  expect_equal(cand[["trimmed_mean@0.20"]](x), agg_trimmed_mean(x, 0.2))
  expect_equal(cand[["extremized@2.00"]](x), agg_extremized(x, 2))
})

test_that("crowd-size curves score every size on the same days", {
  con <- build_aggregation_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  curve <- crowd_size_curve(con, list(median = agg_median), years = 1L,
                            sizes = c(1, 2, 5), reps = 3L)
  expect_setequal(curve$size, c(1, 2, 5))
  expect_true(all(is.finite(curve$brier)))
  # A size at or above the standing crowd uses all of it.
  full <- curve$brier[curve$size == 5 & curve$question_id == "2001-0"]
  expect_equal(full, rep(brier_score(0.6, 1), 3))
  # Every question appears at every size, so coverage cannot vary with size.
  expect_equal(length(unique(table(curve$size, curve$question_id))), 1)
  # A crowd of one is drawn from that day's standing forecasters, so it stays
  # inside the range of their individual scores.
  one <- curve$brier[curve$size == 1 & curve$question_id == "2001-0"]
  expect_true(all(one >= min(brier_score(c(0.9, 0.1, 0.6, 0.7, 0.4), 1))))
  expect_true(all(one <= max(brier_score(c(0.9, 0.1, 0.6, 0.7, 0.4), 1))))
})

test_that("forecastbench crowd scores match a hand-computed median", {
  con <- build_fixture_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  build_fb(con, dir = fixture_path("forecastbench"))
  s <- crowd_scores_fb(con, list(median = agg_median))
  row <- s[s$cohort == "fb_super" & s$question_id == "q_data1" &
             s$resolution_date == as.Date("2024-07-28"), ]
  expect_equal(row$n_forecasters, 1L)
  expect_equal(row$brier, brier_score(0.8, 1))
  expect_setequal(unique(s$cohort), c("fb_public", "fb_super"))
})

test_that("results do not depend on the panel's stored row order", {
  con <- build_aggregation_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  fns <- list(median = agg_median)
  before_curve <- crowd_size_curve(con, fns, years = 1L, sizes = c(1, 2, 5),
                                   reps = 3L)
  before_scores <- crowd_scores_gjp(con, fns, years = 1L, select_ks = 2)

  DBI::dbExecute(con,
    "CREATE OR REPLACE TABLE gjp_panel AS
     SELECT * FROM gjp_panel ORDER BY random()")

  expect_equal(crowd_size_curve(con, fns, years = 1L, sizes = c(1, 2, 5),
                                reps = 3L),
               before_curve)
  expect_equal(crowd_scores_gjp(con, fns, years = 1L, select_ks = 2),
               before_scores)
})
