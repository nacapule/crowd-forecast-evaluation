p5 <- c(0.10, 0.35, 0.50, 0.55, 0.90)

test_that("native trimmed mean matches the aggutils implementation", {
  for (trim in c(0.05, 0.1, 0.2, 0.3)) {
    expect_equal(
      agg_trimmed_mean(p5, trim), aggutils::trim(100 * p5, p = trim) / 100
    )
  }
  # A trim wide enough to remove everything falls back to the median.
  expect_equal(agg_trimmed_mean(p5, 0.5), stats::median(p5))
})

test_that("native geometric mean of odds matches aggutils", {
  expect_equal(
    agg_geo_mean_odds(p5), aggutils::geoMeanOfOddsCalc(100 * p5) / 100
  )
  # Hand-computed: back-transform of the mean log odds.
  expect_equal(
    agg_geo_mean_odds(c(0.25, 0.75)), 0.5, tolerance = 1e-12
  )
})

test_that("extremizing at a = 1 is the geometric mean of odds", {
  expect_equal(agg_extremized(p5, a = 1), agg_geo_mean_odds(p5))
})

test_that("extremizing pushes the aggregate away from a half", {
  low <- c(0.2, 0.3, 0.35)
  high <- c(0.65, 0.7, 0.8)
  expect_lt(agg_extremized(low, 2), agg_geo_mean_odds(low))
  expect_gt(agg_extremized(high, 2), agg_geo_mean_odds(high))
})

test_that("neyman aggregation matches the published factor", {
  n <- length(p5)
  d <- (n * (sqrt(3 * n^2 - 3 * n + 1) - 2)) / (n^2 - n - 1)
  expect_equal(agg_neyman(p5), agg_extremized(p5, a = d))
})

test_that("hd_trim wrapper reproduces the shortest-interval mean", {
  x <- sort(p5)
  n_out <- floor(length(x) * 0.2)
  n_in <- length(x) - n_out
  widths <- vapply(seq_len(n_out + 1),
                   function(i) x[i + n_in - 1] - x[i], numeric(1))
  i <- which.min(widths)
  expect_equal(agg_hd_trim(p5, 0.2), mean(x[i:(i + n_in - 1)]))
})

test_that("rules stay finite and inside the unit interval at 0 and 1", {
  extreme <- c(0, 0, 0.5, 1, 1)
  for (f in aggregator_set()) {
    v <- f(extreme)
    expect_true(is.finite(v))
    expect_gte(v, 0)
    expect_lte(v, 1)
  }
  expect_equal(agg_extremized(rep(1, 4), 2), 1 - .Machine$double.eps,
               tolerance = 1e-2)
})

test_that("select crowd takes the best-scoring forecasters", {
  p <- c(0.9, 0.1, 0.6, 0.7, 0.4)
  score <- c(0.02, 1.62, 0.32, 0.18, 0.72)
  # Best two are the 0.9 and 0.7 forecasters.
  expect_equal(agg_select_crowd(p, score, k = 2)$value, 0.8)
  expect_false(agg_select_crowd(p, score, k = 2)$fallback)
  # Forecasters without history are ineligible.
  expect_equal(
    agg_select_crowd(p, c(NA, NA, 0.32, NA, 0.72), k = 5)$value, 0.5
  )
})

test_that("select crowd falls back to the whole crowd without history", {
  p <- c(0.9, 0.1, 0.6, 0.7, 0.4)
  r <- agg_select_crowd(p, rep(NA_real_, 5), k = 3)
  expect_true(r$fallback)
  expect_equal(r$value, stats::median(p))
})

test_that("the tuning grid holds every free parameter and no others", {
  expect_setequal(names(tuning_grid()), names(default_settings()))
})
