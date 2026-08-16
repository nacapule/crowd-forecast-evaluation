# Aggregation rules: many probability forecasts on one question -> one
# probability.
#
# Every rule here takes a numeric vector of probabilities in [0, 1] and
# returns a single probability. Rules that work in log odds cannot see a 0 or
# a 1, so probabilities are clamped to [eps, 1 - eps] with the same eps used
# for log scores; the clamp is stated wherever extremized results are.
#
# Four rules delegate to aggutils (Forecasting Research Institute, MIT), the
# reference implementation of the trimming and extremizing methods published
# in Powell et al. (2022) and Neyman & Roughgarden (2021). aggutils works on
# the 0-100 percentage scale — its zero/one handling replaces exact 0 and 100
# values with quantiles of the rest — so the wrappers convert on the way in
# and out. Tests cross-check each wrapper against a native reimplementation.

agg_eps <- 1e-3

clamp_p <- function(p, eps = agg_eps) {
  pmin(pmax(p, eps), 1 - eps)
}

logit <- function(p) log(p / (1 - p))

inv_logit <- function(z) 1 / (1 + exp(-z))

agg_mean <- function(p) mean(p)

agg_median <- function(p) stats::median(p)

# Symmetric trimmed mean: drops round(trim * n) values from each end.
# Matches aggutils::trim, which trims the same count from a sorted vector.
agg_trimmed_mean <- function(p, trim = 0.1) {
  n <- length(p)
  k <- round(trim * n)
  if (2 * k >= n) return(stats::median(p))
  mean(sort(p)[(k + 1):(n - k)])
}

# Geometric mean of odds: the mean is taken in log-odds space and mapped
# back, which is the standard pooling rule for probabilities.
agg_geo_mean_odds <- function(p) {
  inv_logit(mean(logit(clamp_p(p))))
}

# Log-odds extremizing (Satopaa et al. 2014): the pooled log odds are
# multiplied by a > 1, pushing the aggregate away from 50%. a = 1 is exactly
# the geometric mean of odds.
agg_extremized <- function(p, a = 2) {
  inv_logit(a * mean(logit(clamp_p(p))))
}

# Highest-density trimmed mean (Powell et al. 2022): the mean of the values
# inside the shortest interval holding (1 - trim) of them.
agg_hd_trim <- function(p, trim = 0.1) {
  aggutils::hd_trim(100 * p, p = trim) / 100
}

# Softened mean (aggutils): trims only the tail the mean leans towards,
# pulling confident crowds back rather than extremizing them.
agg_soften_mean <- function(p, trim = 0.1) {
  aggutils::soften_mean(100 * p, p = trim) / 100
}

# Neyman extremized aggregate (Neyman & Roughgarden 2021): pooled log odds
# extremized by a factor derived from the crowd size, so it has no free
# parameter to tune.
agg_neyman <- function(p) {
  aggutils::neymanAggCalc(100 * p) / 100
}

# Select crowd: the median of the k forecasters with the best trailing
# accuracy. `score` is each forecaster's mean Brier on questions that
# resolved strictly before the forecast date (lower is better) and is NA for
# forecasters without enough history. When fewer than `min_selected` are
# eligible the rule falls back to the whole-crowd median, and callers count
# how often that happens.
agg_select_crowd <- function(p, score, k = 10, min_selected = 2) {
  ok <- !is.na(score)
  if (sum(ok) < min_selected) {
    return(list(value = stats::median(p), fallback = TRUE))
  }
  keep <- order(score[ok])[seq_len(min(k, sum(ok)))]
  list(value = stats::median(p[ok][keep]), fallback = FALSE)
}

# The rules entered in the horse race, with their frozen parameters bound in.
# `select_crowd` is handled separately because it needs forecaster history,
# which ForecastBench's single round does not provide.
aggregator_set <- function(settings = default_settings()) {
  list(
    mean = agg_mean,
    median = agg_median,
    trimmed_mean = function(p) agg_trimmed_mean(p, settings$trim),
    hd_trim = function(p) agg_hd_trim(p, settings$hd_trim),
    soften_mean = function(p) agg_soften_mean(p, settings$soften),
    geo_mean_odds = agg_geo_mean_odds,
    extremized = function(p) agg_extremized(p, settings$extremize_a),
    neyman = agg_neyman
  )
}

# Tuning grids. Every free parameter in the horse race is listed here and
# nowhere else, so the tuning stage cannot silently gain a knob.
tuning_grid <- function() {
  list(
    trim = c(0.05, 0.10, 0.20, 0.30, 0.40, 0.45),
    hd_trim = c(0.05, 0.10, 0.20, 0.30, 0.40, 0.50),
    soften = c(0.05, 0.10, 0.20, 0.30, 0.40),
    extremize_a = c(1.0, 1.25, 1.5, 2.0, 2.5, 3.0),
    select_k = c(5, 10, 20, 40, 80)
  )
}

# Grid midpoints, used only as a starting point and as the fallback when a
# tuning run is not available.
default_settings <- function() {
  list(trim = 0.10, hd_trim = 0.10, soften = 0.10,
       extremize_a = 1.0, select_k = 10)
}
