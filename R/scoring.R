# Proper scores, calibration, and question-cluster bootstrap.
#
# Score convention: the original two-option Brier score (Brier 1950), i.e.
# (p - y)^2 + ((1 - p) - (1 - y))^2 = 2 * (p - y)^2, ranging 0 (perfect) to
# 2 (confidently wrong). This is the convention used throughout the Good
# Judgment Project literature, which the results are reconciled against.

brier_score <- function(p, y) {
  2 * (p - y)^2
}

# Negative log likelihood of the outcome; probabilities are clamped to
# [eps, 1 - eps] so certain-and-wrong forecasts stay finite. eps is reported
# wherever log scores are.
log_score <- function(p, y, eps = 1e-3) {
  p <- pmin(pmax(p, eps), 1 - eps)
  -(y * log(p) + (1 - y) * log(1 - p))
}

# Equal-width calibration bins over [0, 1]. Returns one row per non-empty
# bin: count, mean forecast, outcome frequency, and a Wilson interval on the
# frequency.
calibration_bins <- function(p, y, bins = 10) {
  stopifnot(length(p) == length(y))
  edges <- seq(0, 1, length.out = bins + 1)
  idx <- pmin(findInterval(p, edges, rightmost.closed = TRUE), bins)
  out <- lapply(sort(unique(idx)), function(b) {
    sel <- idx == b
    n <- sum(sel)
    freq <- mean(y[sel])
    ci <- wilson_interval(sum(y[sel]), n)
    data.frame(
      bin = b, bin_mid = (edges[b] + edges[b + 1]) / 2, n = n,
      mean_p = mean(p[sel]), freq = freq,
      freq_low = ci[1], freq_high = ci[2]
    )
  })
  do.call(rbind, out)
}

wilson_interval <- function(k, n, z = 1.96) {
  if (n == 0) return(c(NA_real_, NA_real_))
  p_hat <- k / n
  denom <- 1 + z^2 / n
  center <- (p_hat + z^2 / (2 * n)) / denom
  half <- z * sqrt(p_hat * (1 - p_hat) / n + z^2 / (4 * n^2)) / denom
  c(max(0, center - half), min(1, center + half))
}

# Murphy (1973) decomposition of the mean Brier score over calibration bins:
# mean score = reliability - resolution + uncertainty. Computed on the
# two-option scale, so the identity holds against mean(brier_score(p, y))
# for the same binning. The binned estimator is exact for the binned
# forecasts; with continuous forecasts it inherits the usual within-bin
# approximation, which tests account for by binning first.
murphy_decomposition <- function(p, y, bins = 10) {
  edges <- seq(0, 1, length.out = bins + 1)
  idx <- pmin(findInterval(p, edges, rightmost.closed = TRUE), bins)
  n <- length(y)
  base <- mean(y)
  parts <- vapply(sort(unique(idx)), function(b) {
    sel <- idx == b
    nk <- sum(sel)
    c(
      rel = nk * (mean(p[sel]) - mean(y[sel]))^2,
      res = nk * (mean(y[sel]) - base)^2
    )
  }, c(rel = 0, res = 0))
  reliability <- 2 * sum(parts["rel", ]) / n
  resolution <- 2 * sum(parts["res", ]) / n
  uncertainty <- 2 * base * (1 - base)
  data.frame(
    reliability = reliability, resolution = resolution,
    uncertainty = uncertainty,
    brier = reliability - resolution + uncertainty
  )
}

# Cluster bootstrap over questions: resamples question ids with replacement
# from a per-question summary table and recomputes a statistic each time.
# Operates on precomputed summaries only; nothing upstream is re-run.
#
# The id list is sorted before resampling. Without that, a summary table
# arriving in a different row order — a SQL GROUP BY makes no ordering
# promise — would pair the same seed with a different draw sequence and move
# the interval between runs on identical data.
bootstrap_questions <- function(per_question, stat_fn, reps = 2000,
                                id_col = "question_id", seed = 8145) {
  set.seed(seed)
  ids <- sort(unique(per_question[[id_col]]))
  split_rows <- split(seq_len(nrow(per_question)), per_question[[id_col]])
  stats <- vapply(seq_len(reps), function(i) {
    take <- sample(ids, length(ids), replace = TRUE)
    rows <- unlist(split_rows[take], use.names = FALSE)
    stat_fn(per_question[rows, , drop = FALSE])
  }, numeric(1))
  c(
    estimate = stat_fn(per_question),
    low = unname(stats::quantile(stats, 0.025)),
    high = unname(stats::quantile(stats, 0.975))
  )
}
