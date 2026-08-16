# Aggregation experiments: the out-of-sample horse race.
#
# The crowd is scored under exactly the protocol its members were scored
# under in the calibration stage. For GJP that means a daily panel: on each
# day of a question's scoring window every forecaster's standing forecast is
# collected, one aggregation rule turns them into a single probability, that
# probability is scored, and the question's score is the mean over its days.
# Cross-question averages stay unweighted. For ForecastBench, where each
# forecaster answers once per horizon, the crowd is aggregated per
# question-horizon.
#
# Split: every free parameter is tuned on GJP years 1-2 and then frozen.
# Evaluation is GJP years 3-4, plus the ForecastBench 2024 round as external
# validation. A question belongs to the year it was first forecast in, so the
# 31 questions that straddle a year boundary land on one side only.
# `assert_tuning_only()` is the enforcement: the tuner refuses scores that
# carry an evaluation year.

tuning_years <- function() c(1L, 2L)

evaluation_years <- function() c(3L, 4L)

# Forecasters need this many resolved questions behind them before their
# trailing accuracy is allowed to select them into a crowd.
select_min_history <- function() 5L

assert_tuning_only <- function(scores) {
  bad <- setdiff(unique(scores$q_year), tuning_years())
  if (length(bad) > 0) {
    stop(
      "tuning was handed evaluation-year data (years ",
      paste(sort(bad), collapse = ", "), ")",
      call. = FALSE
    )
  }
  invisible(TRUE)
}

# Day panel for the primary population: one row per (question, forecaster,
# day) on which that forecaster had a standing forecast. Each row also
# carries the forecaster's trailing accuracy as of that day, taken from the
# most recent question that resolved strictly before it — the ASOF join on
# `day > resolved_on` is what keeps select-crowd from seeing its own future.
#
# The panel is ordered down to user_id, not just (question, day). The rules
# themselves do not care about order, but the crowd-size curve draws by row
# position within a day, so an unordered panel would hand the same seed a
# different subcrowd on every rebuild.
build_gjp_panel <- function(con, min_history = select_min_history()) {
  DBI::dbExecute(con,
    "CREATE OR REPLACE TABLE gjp_question_year AS
     SELECT ifp_id, min(year) AS q_year
     FROM binary_forecasts GROUP BY ifp_id"
  )
  DBI::dbExecute(con,
    "CREATE OR REPLACE TABLE gjp_trailing AS
     WITH per_question AS (
       SELECT s.user_id, s.ifp_id,
              coalesce(q.date_suspend, q.date_closed) AS resolved_on,
              avg(s.mean_daily_brier) AS q_score
       FROM gjp_user_question_scores s
       JOIN questions_accepted q USING (ifp_id)
       WHERE s.cond = 1
       GROUP BY 1, 2, 3
     ), per_close AS (
       SELECT user_id, resolved_on,
              sum(q_score) AS sum_score, count(*) AS n
       FROM per_question GROUP BY 1, 2
     )
     SELECT user_id, resolved_on,
            sum(sum_score) OVER w / sum(n) OVER w AS trailing_mean,
            sum(n) OVER w AS trailing_n
     FROM per_close
     WINDOW w AS (
       PARTITION BY user_id ORDER BY resolved_on
       ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
     )"
  )
  DBI::dbExecute(con,
    "CREATE OR REPLACE TABLE gjp_panel_raw AS
     SELECT ifp_id, user_id, resolved_to, p,
            unnest(generate_series(seg_start, seg_end, INTERVAL 1 DAY))::DATE
              AS day
     FROM gjp_segments
     WHERE cond = 1 AND seg_end >= seg_start"
  )
  DBI::dbExecute(con, sprintf(
    "CREATE OR REPLACE TABLE gjp_panel AS
     SELECT r.ifp_id, y.q_year, r.day, r.user_id, r.p, r.resolved_to,
            CASE WHEN t.trailing_n >= %d THEN t.trailing_mean END
              AS trailing_score
     FROM gjp_panel_raw r
     JOIN gjp_question_year y USING (ifp_id)
     ASOF LEFT JOIN gjp_trailing t
       ON r.user_id = t.user_id AND r.day > t.resolved_on
     ORDER BY r.ifp_id, r.day, r.user_id", min_history
  ))
  DBI::dbExecute(con, "DROP TABLE gjp_panel_raw")
  invisible(TRUE)
}

# Start and end row indices of each run of equal keys in an already-sorted
# table. Used instead of split() because the panel runs to millions of rows.
run_bounds <- function(...) {
  keys <- list(...)
  n <- length(keys[[1]])
  if (n == 0) return(list(start = integer(0), end = integer(0)))
  changed <- rep(FALSE, max(n - 1, 0))
  for (k in keys) changed <- changed | (k[-1] != k[-n])
  start <- c(1L, which(changed) + 1L)
  list(start = start, end = c(start[-1] - 1L, n))
}

# Rule names, in the order their columns appear in the day matrix. Each
# select-crowd rule also gets a `fallback:` column recording the days it had
# too little forecaster history and reverted to the whole-crowd median.
rule_columns <- function(fns, select_ks) {
  # paste0 drops a zero-length argument instead of returning one, so the
  # empty case is spelled out.
  if (length(select_ks) == 0) {
    return(list(rules = names(fns), fallback = character(0)))
  }
  sel <- paste0("select_crowd_k", select_ks)
  list(rules = c(names(fns), sel), fallback = paste0("fallback:", sel))
}

# vapply over groups, always returning a matrix with one named column per
# rule — t() alone collapses when there is a single rule.
score_matrix <- function(n_groups, columns, fn) {
  raw <- vapply(seq_len(n_groups), fn, numeric(length(columns)))
  mat <- if (length(columns) == 1) matrix(raw, ncol = 1) else t(raw)
  colnames(mat) <- columns
  mat
}

# Applies every rule to one group of standing forecasts and scores each
# result on the two-option Brier scale.
score_group <- function(p, y, fns, select_ks, trailing) {
  scores <- vapply(fns, function(f) 2 * (f(p) - y)^2, numeric(1))
  if (length(select_ks) == 0) return(scores)
  sel <- vapply(select_ks, function(k) {
    r <- agg_select_crowd(p, trailing, k = k)
    c(2 * (r$value - y)^2, as.numeric(r$fallback))
  }, numeric(2))
  sel_names <- paste0("select_crowd_k", select_ks)
  c(scores,
    stats::setNames(sel[1, ], sel_names),
    stats::setNames(sel[2, ], paste0("fallback:", sel_names)))
}

# Runs the horse race over the GJP day panel and returns one row per
# (rule, question): the question's day-weighted Brier, its day count, and the
# share of days a select-crowd rule fell back to the whole crowd. Questions
# stream in chunks so the panel never lands in memory whole.
crowd_scores_gjp <- function(con, fns, years, select_ks = numeric(0),
                             chunk = 25L) {
  cols <- rule_columns(fns, select_ks)
  ids <- DBI::dbGetQuery(con, sprintf(
    "SELECT DISTINCT ifp_id FROM gjp_panel WHERE q_year IN (%s)
     ORDER BY ifp_id", paste(years, collapse = ", ")
  ))$ifp_id
  parts <- unname(split(ids, ceiling(seq_along(ids) / chunk)))
  per_chunk <- lapply(parts, function(batch) {
    rows <- DBI::dbGetQuery(con, sprintf(
      "SELECT ifp_id, q_year, day, p, resolved_to, trailing_score
       FROM gjp_panel WHERE ifp_id IN (%s)
       ORDER BY ifp_id, day, user_id",
      paste(sprintf("'%s'", batch), collapse = ", ")
    ))
    b <- run_bounds(rows$ifp_id, as.integer(rows$day))
    day_mat <- score_matrix(length(b$start), c(cols$rules, cols$fallback),
      function(i) {
        idx <- b$start[i]:b$end[i]
        score_group(rows$p[idx], rows$resolved_to[idx[1]], fns, select_ks,
                    rows$trailing_score[idx])
      })
    day_q <- rows$ifp_id[b$start]
    question_mean(day_mat, day_q, rows$q_year[b$start])
  })
  long_scores(per_chunk, cols)
}

# Collapses a day-level score matrix to one row per question (unweighted
# mean over the question's scoring days).
question_mean <- function(day_mat, day_q, day_year) {
  sums <- rowsum(day_mat, day_q)
  n_days <- as.vector(table(day_q)[rownames(sums)])
  data.frame(
    question_id = rownames(sums),
    q_year = day_year[match(rownames(sums), day_q)],
    n_days = n_days,
    sums / n_days,
    check.names = FALSE, stringsAsFactors = FALSE
  )
}

# Wide (one column per rule) to long (one row per rule and question).
long_scores <- function(per_chunk, cols) {
  wide <- do.call(rbind, per_chunk)
  out <- lapply(cols$rules, function(r) {
    fb <- paste0("fallback:", r)
    data.frame(
      rule = r,
      question_id = wide$question_id,
      q_year = wide$q_year,
      n_days = wide$n_days,
      brier = wide[[r]],
      fallback_rate = if (fb %in% names(wide)) wide[[fb]] else NA_real_,
      stringsAsFactors = FALSE
    )
  })
  res <- do.call(rbind, out)
  rownames(res) <- NULL
  res
}

# ForecastBench: one aggregate per (cohort, question, horizon). A single
# round carries no forecaster history, so select-crowd cannot run here.
crowd_scores_fb <- function(con, fns) {
  rows <- DBI::dbGetQuery(con,
    "SELECT cohort, question_id, resolution_date, horizon_days, p, resolved_to
     FROM fb_binary
     ORDER BY cohort, question_id, resolution_date"
  )
  b <- run_bounds(rows$cohort, rows$question_id,
                  as.integer(rows$resolution_date))
  mat <- score_matrix(length(b$start), names(fns), function(i) {
    idx <- b$start[i]:b$end[i]
    vapply(fns, function(f) 2 * (f(rows$p[idx]) - rows$resolved_to[idx[1]])^2,
           numeric(1))
  })
  head_rows <- b$start
  do.call(rbind, lapply(names(fns), function(r) {
    data.frame(
      rule = r,
      cohort = rows$cohort[head_rows],
      question_id = rows$question_id[head_rows],
      resolution_date = rows$resolution_date[head_rows],
      horizon_days = rows$horizon_days[head_rows],
      n_forecasters = b$end - b$start + 1L,
      brier = mat[, r],
      stringsAsFactors = FALSE
    )
  }))
}

# Candidate rules for the tuning sweep: every grid value of every
# parameterized family, evaluated in one pass over the tuning panel.
tuning_candidates <- function(grid = tuning_grid()) {
  family <- function(label, f, values) {
    stats::setNames(
      lapply(values, function(v) {
        force(v)
        function(p) f(p, v)
      }),
      sprintf("%s@%.2f", label, values)
    )
  }
  c(
    family("trimmed_mean", agg_trimmed_mean, grid$trim),
    family("hd_trim", agg_hd_trim, grid$hd_trim),
    family("soften_mean", agg_soften_mean, grid$soften),
    family("extremized", agg_extremized, grid$extremize_a)
  )
}

# Picks the grid value with the lowest mean question Brier on the tuning
# years and returns the frozen settings used everywhere downstream.
tune_settings <- function(con, grid = tuning_grid()) {
  scores <- crowd_scores_gjp(con, tuning_candidates(grid),
                             years = tuning_years(),
                             select_ks = grid$select_k)
  assert_tuning_only(scores)
  means <- stats::aggregate(brier ~ rule, data = scores, FUN = mean)
  best <- function(labels, values) {
    hit <- match(labels, means$rule)
    if (anyNA(hit)) {
      stop("tuning sweep is missing candidates: ",
           paste(labels[is.na(hit)], collapse = ", "), call. = FALSE)
    }
    values[which.min(means$brier[hit])]
  }
  settings <- list(
    trim = best(sprintf("trimmed_mean@%.2f", grid$trim), grid$trim),
    hd_trim = best(sprintf("hd_trim@%.2f", grid$hd_trim), grid$hd_trim),
    soften = best(sprintf("soften_mean@%.2f", grid$soften), grid$soften),
    extremize_a = best(sprintf("extremized@%.2f", grid$extremize_a),
                       grid$extremize_a),
    select_k = best(paste0("select_crowd_k", grid$select_k), grid$select_k)
  )
  list(settings = settings, sweep = means)
}

# Crowd-size curve: on each scoring day draw at most n of the forecasters
# standing that day, run the rules on that subcrowd, and average over days as
# usual. Drawing per day rather than once per question is what keeps the
# curve about size: every size is scored on exactly the same days, so a larger
# crowd cannot look worse merely by covering more of a question's hard early
# stretch. At n = 1 the curve is the average member. Days are thinned evenly
# (`max_days`) — an unbiased subsample of the daily protocol that keeps the
# sweep affordable.
crowd_size_curve <- function(con, fns, years, sizes, reps = 5L,
                             max_days = 30L, seed = 8145) {
  set.seed(seed)
  ids <- DBI::dbGetQuery(con, sprintf(
    "SELECT DISTINCT ifp_id FROM gjp_panel WHERE q_year IN (%s)
     ORDER BY ifp_id", paste(years, collapse = ", ")
  ))$ifp_id
  out <- lapply(ids, function(qid) {
    rows <- DBI::dbGetQuery(con, sprintf(
      "SELECT day, p, resolved_to FROM gjp_panel
       WHERE ifp_id = '%s' ORDER BY day, user_id", qid
    ))
    y <- rows$resolved_to[1]
    b <- run_bounds(as.integer(rows$day))
    groups <- lapply(thin_index(length(b$start), max_days),
                     function(i) b$start[i]:b$end[i])
    do.call(rbind, lapply(sizes, function(n) {
      do.call(rbind, lapply(seq_len(reps), function(r) {
        vals <- vapply(groups, function(idx) {
          # idx[sample.int(...)] rather than sample(idx, n): sample() reads a
          # length-one vector as a range.
          take <- if (length(idx) <= n) idx else idx[sample.int(length(idx), n)]
          vapply(fns, function(f) 2 * (f(rows$p[take]) - y)^2, numeric(1))
        }, numeric(length(fns)))
        data.frame(
          question_id = qid, size = n, rep = r, rule = names(fns),
          brier = rowMeans(matrix(vals, nrow = length(fns))),
          stringsAsFactors = FALSE
        )
      }))
    }))
  })
  do.call(rbind, out)
}

# Evenly spaced indices: all of 1..n when n <= keep, otherwise `keep` of them
# spread across the range.
thin_index <- function(n, keep) {
  if (n <= keep) return(seq_len(n))
  unique(round(seq(1, n, length.out = keep)))
}

# What a randomly chosen member of the crowd scores on their own: on each day
# the standing forecasters are scored individually and averaged, then days are
# averaged the way every rule's days are. Same panel, same population, same
# weighting — so it is the line the rules have to beat, and it is also the
# n = 1 point of the crowd-size curve.
individual_baseline_gjp <- function(con, years) {
  DBI::dbGetQuery(con, sprintf(
    "SELECT ifp_id AS question_id, avg(day_brier) AS brier
     FROM (
       SELECT ifp_id, day,
              avg(2 * (p - resolved_to) * (p - resolved_to)) AS day_brier
       FROM gjp_panel WHERE q_year IN (%s)
       GROUP BY ifp_id, day
     ) GROUP BY 1 ORDER BY 1", paste(years, collapse = ", ")
  ))
}

individual_baseline_fb <- function(con) {
  DBI::dbGetQuery(con,
    "SELECT cohort, question_id, resolution_date,
            avg(2 * (p - resolved_to) * (p - resolved_to)) AS brier
     FROM fb_binary GROUP BY 1, 2, 3 ORDER BY 1, 2, 3"
  )
}

# One results row per (corpus, cohort, rule): mean question score with a
# question-cluster bootstrap interval. Clustering is on question id, so the
# several horizons of one ForecastBench question resample together.
summarise_rule <- function(per_question, corpus, cohort, rule, reps) {
  b <- bootstrap_questions(per_question, function(df) mean(df$brier),
                           reps = reps)
  data.frame(
    corpus = corpus, cohort = cohort, rule = rule,
    n_questions = length(unique(per_question$question_id)),
    n_scored = nrow(per_question),
    mean_brier = unname(b["estimate"]),
    ci_low = unname(b["low"]), ci_high = unname(b["high"]),
    stringsAsFactors = FALSE
  )
}

results_table <- function(scores, corpus, cohort, reps) {
  parts <- lapply(split(scores, scores$rule), function(df) {
    summarise_rule(df, corpus, cohort, df$rule[1], reps)
  })
  out <- do.call(rbind, parts)
  out[order(out$mean_brier), ]
}

# The whole Stage 3 pipeline: build the panel, tune on years 1-2, freeze,
# evaluate on years 3-4 and on the ForecastBench round, and write results.
run_experiments <- function(db = db_path(), out_dir = file.path("analysis",
                                                                "results"),
                            reps = 2000L, size_reps = 5L) {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)

  build_gjp_panel(con)
  tuned <- tune_settings(con)
  settings <- tuned$settings
  fns <- aggregator_set(settings)

  gjp <- crowd_scores_gjp(con, fns, years = evaluation_years(),
                          select_ks = settings$select_k)
  fb <- crowd_scores_fb(con, fns)

  ind_gjp <- individual_baseline_gjp(con, evaluation_years())
  ind_fb <- individual_baseline_fb(con)

  tables <- list(
    results_table(gjp, "gjp", "independent individuals (yrs 3-4)",
                  reps = reps),
    summarise_rule(ind_gjp, "gjp", "independent individuals (yrs 3-4)",
                   "individual forecaster", reps = reps)
  )
  for (ch in sort(unique(fb$cohort))) {
    tables <- c(tables, list(
      results_table(fb[fb$cohort == ch, ], "forecastbench", ch, reps = reps),
      summarise_rule(ind_fb[ind_fb$cohort == ch, ], "forecastbench", ch,
                     "individual forecaster", reps = reps)
    ))
  }
  results <- do.call(rbind, tables)
  rownames(results) <- NULL

  sizes <- c(1, 2, 3, 5, 10, 25, 50, 100)
  curve <- crowd_size_curve(
    con, fns[c("mean", "median", "extremized", "hd_trim")],
    years = evaluation_years(), sizes = sizes, reps = size_reps
  )
  curve_summary <- stats::aggregate(brier ~ rule + size, data = curve,
                                    FUN = mean)

  settings_df <- data.frame(
    parameter = names(settings),
    value = unlist(settings, use.names = FALSE),
    stringsAsFactors = FALSE
  )
  DBI::dbWriteTable(con, "agg_results", results, overwrite = TRUE)
  DBI::dbWriteTable(con, "agg_settings", settings_df, overwrite = TRUE)
  DBI::dbWriteTable(con, "agg_sweep", tuned$sweep, overwrite = TRUE)
  DBI::dbWriteTable(con, "agg_gjp_questions", gjp, overwrite = TRUE)
  DBI::dbWriteTable(con, "agg_fb_questions", fb, overwrite = TRUE)
  DBI::dbWriteTable(con, "agg_crowd_size", curve_summary, overwrite = TRUE)

  write_result_csv(results, file.path(out_dir, "aggregation.csv"))
  write_result_csv(tuned$sweep, file.path(out_dir, "tuning-sweep.csv"))
  write_result_csv(settings_df, file.path(out_dir, "frozen-settings.csv"))
  write_result_csv(curve_summary, file.path(out_dir, "crowd-size.csv"))

  list(settings = settings, results = results, sweep = tuned$sweep,
       crowd_size = curve_summary)
}

write_result_csv <- function(df, path) {
  num <- vapply(df, is.numeric, logical(1))
  df[num] <- lapply(df[num], function(x) round(x, 6))
  utils::write.csv(df, path, row.names = FALSE)
}
