# QA gate over the built DuckDB schema.
#
# Hard checks fail the build. Soft checks are reported with counts and left
# to the scoring protocol to handle explicitly.

qa_check <- function(name, hard, n_violations, detail = "") {
  data.frame(
    check = name, hard = hard, n_violations = n_violations,
    pass = n_violations == 0, detail = detail
  )
}

count1 <- function(con, sql) {
  DBI::dbGetQuery(con, sql)[[1]]
}

run_qa_checks <- function(con) {
  checks <- list()

  checks$probability_domain <- qa_check(
    "probability_domain_accepted", hard = TRUE,
    count1(con,
      "SELECT count(*) FROM forecasts_accepted
       WHERE value IS NULL OR value < 0 OR value > 1"),
    "accepted forecast probabilities must lie in [0, 1]"
  )

  checks$orphans <- qa_check(
    "accepted_forecasts_join_questions", hard = TRUE,
    count1(con,
      "SELECT count(*) FROM forecasts_accepted f
       ANTI JOIN questions_accepted q USING (ifp_id)"),
    "every accepted forecast joins an accepted question"
  )

  checks$outcome_valid <- qa_check(
    "binary_outcomes_are_a_or_b", hard = TRUE,
    count1(con,
      "SELECT count(*) FROM questions_accepted
       WHERE outcome IS NULL OR outcome NOT IN ('a', 'b')"),
    "accepted questions are closed binary IFPs resolved to a or b"
  )

  checks$question_accounting <- qa_check(
    "question_accounting_identity", hard = TRUE,
    abs(
      count1(con, "SELECT count(*) FROM questions") -
        (count1(con, "SELECT count(*) FROM questions_accepted") +
           count1(con, "SELECT count(*) FROM questions_rejected"))
    ),
    "questions = accepted + rejected, no double counting"
  )

  checks$forecast_accounting <- qa_check(
    "forecast_accounting_identity", hard = TRUE,
    abs(
      count1(con, "SELECT count(*) FROM forecasts") -
        (count1(con, "SELECT count(*) FROM forecasts_accepted") +
           count1(con, "SELECT count(*) FROM forecasts_rejected"))
    ),
    "forecast rows = accepted + rejected, no double counting"
  )

  checks$binary_view_complete <- qa_check(
    "binary_view_one_row_per_event", hard = TRUE,
    count1(con,
      "SELECT count(*) FROM (
         SELECT year, forecast_id, ifp_id, user_id
         FROM forecasts_accepted
         GROUP BY year, forecast_id, ifp_id, user_id
       ) events") -
      count1(con, "SELECT count(*) FROM binary_forecasts"),
    "every accepted forecast event appears exactly once in binary_forecasts"
  )

  checks$out_of_window <- qa_check(
    "forecasts_outside_question_window", hard = FALSE,
    count1(con,
      "SELECT count(*) FROM forecasts_accepted WHERE NOT in_window"),
    "flagged only; the scoring protocol decides treatment"
  )

  if (DBI::dbExistsTable(con, "fb_binary")) {
    checks$fb_domain <- qa_check(
      "fb_probability_and_resolution_domain", hard = TRUE,
      count1(con,
        "SELECT count(*) FROM fb_binary
         WHERE p < 0 OR p > 1 OR resolved_to NOT IN (0.0, 1.0)"),
      "scored ForecastBench rows have valid p and 0/1 resolutions"
    )
    checks$fb_nonempty <- qa_check(
      "fb_binary_nonempty", hard = TRUE,
      as.integer(count1(con, "SELECT count(*) FROM fb_binary") == 0),
      "the ForecastBench scored set must not be empty"
    )
    checks$fb_sources <- qa_check(
      "fb_scored_sources_are_dataset_type", hard = TRUE,
      count1(con,
        "SELECT count(*) FROM fb_binary WHERE source_type <> 'dataset'"),
      "market-proxy resolutions are excluded from the scored set"
    )
    checks$fb_horizon_key <- qa_check(
      "fb_one_row_per_forecaster_question_horizon", hard = TRUE,
      count1(con,
        "SELECT count(*) FROM (
           SELECT 1 FROM fb_binary
           GROUP BY cohort, user_id, question_id, resolution_date
           HAVING count(*) > 1
         )"),
      "the scored set is keyed by forecaster, question, and horizon date"
    )
    # The exclusion counts are checked against the tables they describe, not
    # against each other: `kept` and `scored` are recounted live, so a filter
    # added without a reason row breaks the identity and fails the build.
    row_n <- function(reason) {
      count1(con, sprintf(
        "SELECT coalesce(sum(n), 0) FROM fb_accounting
         WHERE level = 'forecast_row' AND reason = '%s'", reason))
    }
    q_n <- function(reason) {
      count1(con, sprintf(
        "SELECT coalesce(sum(n), 0) FROM fb_accounting
         WHERE level = 'question' AND reason = '%s'", reason))
    }
    kept <- count1(con, "SELECT count(*) FROM fb_forecasts")
    scored <- count1(con, "SELECT count(*) FROM fb_binary")
    scored_q <- count1(con,
      "SELECT count(DISTINCT question_id) FROM fb_binary")

    checks$fb_question_accounting <- qa_check(
      "fb_question_accounting_identity", hard = TRUE,
      abs(q_n("dataset_kept") -
            (scored_q + q_n("dataset_no_resolution"))),
      "dataset questions = scored + dropped for having no resolution"
    )
    checks$fb_forecast_accounting <- qa_check(
      "fb_forecast_accounting_identity", hard = TRUE,
      abs(row_n("source_entries") -
            (row_n("market_question_entries") +
               row_n("probability_out_of_domain") +
               row_n("duplicate_horizon_entries_collapsed") + kept)) +
        abs(kept - (row_n("entries_on_unresolved_question") +
                      row_n("horizon_without_resolution") + scored)),
      "source entries = scored rows + counted exclusions, at both stages"
    )
  }

  if (DBI::dbExistsTable(con, "gjp_user_question_scores")) {
    checks$score_domain <- qa_check(
      "gjp_scores_within_brier_range", hard = TRUE,
      count1(con,
        "SELECT count(*) FROM gjp_user_question_scores
         WHERE mean_daily_brier < 0 OR mean_daily_brier > 2
            OR days_held <= 0"),
      "day-weighted Brier scores lie in [0, 2] with positive day counts"
    )
    checks$events_labeled <- qa_check(
      "gjp_events_all_have_cohorts", hard = TRUE,
      count1(con,
        "SELECT count(*) FROM gjp_events WHERE cohort IS NULL"),
      "every scored event carries an analysis cohort label"
    )
  }

  if (DBI::dbExistsTable(con, "gjp_panel")) {
    checks$panel_days <- qa_check(
      "gjp_panel_days_match_scored_days", hard = TRUE,
      count1(con,
        "SELECT count(*) FROM
           (SELECT ifp_id, user_id, count(*) AS n_panel
            FROM gjp_panel GROUP BY 1, 2) a
         FULL JOIN
           (SELECT ifp_id, user_id, sum(days_held) AS n_scored
            FROM gjp_user_question_scores WHERE cond = 1
            GROUP BY 1, 2) b
           USING (ifp_id, user_id)
         WHERE a.n_panel IS DISTINCT FROM b.n_scored"),
      "the aggregation panel holds exactly the days the protocol scores,
       for exactly the forecasters the protocol scores"
    )
    checks$panel_unique <- qa_check(
      "gjp_panel_one_row_per_forecaster_day", hard = TRUE,
      count1(con,
        "SELECT count(*) FROM (
           SELECT 1 FROM gjp_panel GROUP BY ifp_id, user_id, day
           HAVING count(*) > 1
         )"),
      "no forecaster contributes twice to one day's crowd"
    )
  }

  checks$unknown_ifp_ids <- qa_check(
    "forecast_ifp_ids_absent_from_questions", hard = FALSE,
    count1(con,
      "SELECT count(*) FROM forecasts f
       ANTI JOIN questions q USING (ifp_id)"),
    "forecast rows whose ifp_id is not in ifps.csv at all
     (distinct from designed exclusions)"
  )

  checks$conditions_known <- qa_check(
    "condition_codes_recognized", hard = FALSE,
    count1(con,
      "SELECT count(*) FROM forecasts_accepted
       WHERE cond IS NULL OR cond NOT BETWEEN 1 AND 5"),
    "cond group outside the documented 1-5 range"
  )

  do.call(rbind, checks)
}

# A soft check with a nonzero count has not failed anything — it has reported
# a number the protocol handles deliberately. Only a hard check can fail.
qa_status <- function(hard, pass) {
  ifelse(pass, "pass", ifelse(hard, "FAIL", "reported"))
}

qa_report_text <- function(con) {
  res <- run_qa_checks(con)
  acct <- DBI::dbGetQuery(con,
    "SELECT level, reason, n FROM qa_accounting ORDER BY level, n DESC")
  # Ordered by insertion, not by size: the ForecastBench rows are a ledger
  # that reads source -> exclusions -> scored, and the hard accounting check
  # is the claim that it adds up.
  fb_acct <- if (DBI::dbExistsTable(con, "fb_accounting")) {
    DBI::dbGetQuery(con,
      "SELECT level, reason, n FROM fb_accounting ORDER BY rowid")
  } else {
    acct[0, ]
  }
  lines <- c(
    "# QA report",
    "",
    sprintf("Generated: %s", format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")),
    "",
    "## Checks",
    "",
    sprintf(
      paste("%d hard, %d soft. A hard violation fails the build. A soft",
            "check reports a count the scoring protocol handles",
            "explicitly; it never fails the build."),
      sum(res$hard), sum(!res$hard)
    ),
    "",
    "| check | type | violations | status |",
    "|---|---|---:|---|",
    sprintf(
      "| %s | %s | %d | %s |",
      res$check, ifelse(res$hard, "hard", "soft"),
      res$n_violations, qa_status(res$hard, res$pass)
    ),
    "",
    "## Accounting — Good Judgment Project",
    "",
    "| level | reason | n |",
    "|---|---|---:|",
    sprintf("| %s | %s | %d |", acct$level, acct$reason, acct$n),
    "",
    "## Accounting — ForecastBench",
    "",
    "| level | reason | n |",
    "|---|---|---:|",
    sprintf("| %s | %s | %d |", fb_acct$level, fb_acct$reason, fb_acct$n)
  )
  list(text = paste(lines, collapse = "\n"), results = res)
}

# Writes qa/qa_report.md and fails on any hard-check violation.
run_qa_gate <- function(db = db_path(), out = file.path("qa", "qa_report.md")) {
  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db, read_only = TRUE)
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE), add = TRUE)
  rep <- qa_report_text(con)
  dir.create(dirname(out), recursive = TRUE, showWarnings = FALSE)
  writeLines(rep$text, out)
  hard_fail <- rep$results[rep$results$hard & !rep$results$pass, ]
  if (nrow(hard_fail) > 0) {
    stop(
      "QA gate failed: ",
      paste(hard_fail$check, collapse = ", "),
      call. = FALSE
    )
  }
  invisible(rep$results)
}
