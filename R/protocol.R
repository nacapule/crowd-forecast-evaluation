# GJP scoring protocol.
#
# Daily carry-forward, computed on segments rather than expanded days: a
# forecast stands from its date until the day before the forecaster's next
# forecast on that question (or the end of the scoring window), so its
# daily-weighted Brier contribution is segment_days * brier. Per-question
# scores are day-weighted means; cross-question averages are unweighted, so
# long-lived questions do not dominate.
#
# Window and edge rules, stated once and enforced in SQL:
# - Scoring window: date_start through coalesce(date_suspend, date_closed).
# - Multiple forecasts on one day: the last (by timestamp) stands that day.
# - Forecasts before the window start carry from the window start.
# - Forecasts after the window end contribute zero days.
# - A withdrawal (fcast_type 4) is scored on its own day (its values are the
#   forecaster's last standing) and the forecaster exits the question after
#   that day until any later forecast re-enters.
#
# Scoring cell: (question, forecaster, condition code, tournament year).
# Participants were re-randomized between seasons, so on the 31 questions
# that straddle a year boundary a forecaster can appear under two conditions
# on the same question — 3,729 such cases. Keying the cell on the full
# condition code keeps each cohort's days its own instead of attributing a
# whole question to whichever condition sorted first, and it is what lets the
# aggregation stage compare a crowd against exactly the forecasters in it.

build_gjp_scores <- function(con) {
  DBI::dbExecute(con,
    "CREATE OR REPLACE TABLE gjp_daily_events AS
     WITH ranked AS (
       SELECT *,
         coalesce(date_suspend, date_closed) AS window_end,
         row_number() OVER (
           PARTITION BY ifp_id, user_id, fcast_date
           ORDER BY timestamp DESC, forecast_id DESC
         ) AS rn
       FROM binary_forecasts
     )
     SELECT * EXCLUDE (rn) FROM ranked WHERE rn = 1"
  )
  DBI::dbExecute(con,
    "CREATE OR REPLACE TABLE gjp_segments AS
     SELECT *,
       greatest(fcast_date, date_start) AS seg_start,
       least(
         window_end,
         CASE WHEN fcast_type = 4 THEN fcast_date
              ELSE coalesce(
                lead(fcast_date) OVER (
                  PARTITION BY ifp_id, user_id ORDER BY fcast_date
                ) - 1,
                window_end
              ) END
       ) AS seg_end
     FROM gjp_daily_events"
  )
  DBI::dbExecute(con,
    "CREATE OR REPLACE TABLE gjp_user_question_scores AS
     SELECT
       ifp_id, user_id, year, ctt, cond,
       min(resolved_to) AS resolved_to,
       sum(seg_days) AS days_held,
       count(*) AS n_forecasts,
       sum(seg_days * 2 * (p - resolved_to) * (p - resolved_to))
         / sum(seg_days) AS mean_daily_brier
     FROM (
       SELECT *, date_diff('day', seg_start, seg_end) + 1 AS seg_days
       FROM gjp_segments
       WHERE seg_end >= seg_start
     )
     GROUP BY ifp_id, user_id, year, ctt, cond
     HAVING sum(seg_days) > 0"
  )
}

# Top-decile cohort: cond-1 forecasters ranked by year-1 unweighted mean
# question score, among those with at least `min_questions` scored year-1
# questions. Defined on year 1 only so later-year comparisons carry no
# selection leakage.
build_top_decile <- function(con, min_questions = 10) {
  DBI::dbExecute(con, sprintf(
    "CREATE OR REPLACE TABLE gjp_top_decile AS
     WITH per_question AS (
       SELECT user_id, ifp_id, avg(mean_daily_brier) AS q_score
       FROM gjp_user_question_scores
       WHERE year = 1 AND cond = 1
       GROUP BY user_id, ifp_id
     ), year1 AS (
       SELECT user_id,
         avg(q_score) AS mean_score,
         count(*) AS n_questions
       FROM per_question
       GROUP BY user_id
       HAVING count(*) >= %d
     )
     SELECT user_id, mean_score, n_questions
     FROM year1
     WHERE mean_score <= (
       SELECT quantile_cont(mean_score, 0.10) FROM year1
     )", min_questions
  ))
}

# Event-level table for calibration and horizon analyses: the last-per-day
# forecast events, labeled with analysis cohorts. days_to_end is the number
# of days from the forecast to the end of the scoring window.
build_gjp_events <- function(con) {
  DBI::dbExecute(con,
    "CREATE OR REPLACE TABLE gjp_events AS
     SELECT e.*,
       date_diff('day', e.fcast_date, e.window_end) AS days_to_end,
       CASE
         WHEN e.cond = 1 AND e.year >= 2 AND t.user_id IS NOT NULL
           THEN 'gjp_top_decile'
         WHEN e.cond = 1 THEN 'gjp_individual'
         WHEN e.cond = 2 THEN 'gjp_crowd_info'
         WHEN e.cond = 4 THEN 'gjp_team'
         WHEN e.cond = 5 THEN 'gjp_superteam'
       END AS cohort
     FROM gjp_daily_events e
     LEFT JOIN gjp_top_decile t USING (user_id)
     WHERE e.fcast_date <= e.window_end"
  )
}

run_gjp_protocol <- function(con) {
  build_gjp_scores(con)
  build_top_decile(con)
  build_gjp_events(con)
}
