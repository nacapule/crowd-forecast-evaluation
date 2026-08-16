test_that("brier_score uses the two-option convention", {
  expect_equal(brier_score(0.7, 1), 0.18)
  expect_equal(brier_score(0.5, 0), 0.5)
  expect_equal(brier_score(1, 1), 0)
  expect_equal(brier_score(0, 1), 2)
})

test_that("log_score clamps certain-and-wrong forecasts", {
  expect_true(is.finite(log_score(0, 1)))
  expect_equal(log_score(0, 1), -log(1e-3))
  expect_lt(log_score(0.9, 1), log_score(0.6, 1))
})

test_that("wilson_interval matches a known value", {
  ci <- wilson_interval(5, 10)
  expect_equal(ci[1], 0.2366, tolerance = 1e-3)
  expect_equal(ci[2], 0.7634, tolerance = 1e-3)
  expect_equal(wilson_interval(0, 0), c(NA_real_, NA_real_))
})

test_that("calibration_bins partitions and summarizes correctly", {
  p <- c(0.05, 0.05, 0.55, 0.55, 0.55, 0.95)
  y <- c(0, 0, 1, 0, 1, 1)
  cb <- calibration_bins(p, y, bins = 10)
  expect_equal(nrow(cb), 3)
  expect_equal(cb$n, c(2, 3, 1))
  mid <- cb[cb$bin == 6, ]
  expect_equal(mid$mean_p, 0.55)
  expect_equal(mid$freq, 2 / 3, tolerance = 1e-12)
  expect_true(mid$freq_low < mid$freq & mid$freq < mid$freq_high)
})

test_that("murphy decomposition identity holds for binned forecasts", {
  set.seed(42)
  bins <- 10
  mids <- (seq_len(bins) - 0.5) / bins
  p <- sample(mids, 500, replace = TRUE)
  y <- rbinom(500, 1, p)
  md <- murphy_decomposition(p, y, bins = bins)
  expect_equal(
    md$reliability - md$resolution + md$uncertainty,
    mean(brier_score(p, y)),
    tolerance = 1e-12
  )
  expect_gte(md$reliability, 0)
  expect_gte(md$resolution, 0)
})

test_that("bootstrap_questions resamples by question with a stable seed", {
  pq <- data.frame(
    question_id = letters[1:10],
    score = c(1, 1, 1, 1, 1, 3, 3, 3, 3, 3)
  )
  stat <- function(df) mean(df$score)
  b1 <- bootstrap_questions(pq, stat, reps = 200)
  b2 <- bootstrap_questions(pq, stat, reps = 200)
  expect_equal(b1, b2)
  expect_equal(unname(b1["estimate"]), 2)
  expect_true(b1["low"] >= 1 && b1["high"] <= 3)
  expect_true(b1["low"] < 2 && b1["high"] > 2)
})

test_that("the question bootstrap does not depend on input row order", {
  per_q <- data.frame(
    question_id = sprintf("q%02d", 1:40),
    brier = seq(0.05, 0.95, length.out = 40)
  )
  stat <- function(df) mean(df$brier)
  # Shuffle outside the call: an inline sample() would be forced lazily,
  # after the function seeds the generator, and shift the draw sequence.
  reordered <- per_q[sample(nrow(per_q)), ]
  straight <- bootstrap_questions(per_q, stat, reps = 200)
  shuffled <- bootstrap_questions(reordered, stat, reps = 200)
  expect_equal(straight, shuffled)
})
