# QA report

Generated: 2026-08-16 11:14:01 CST

## Checks

16 hard, 3 soft. A hard violation fails the build. A soft check reports a count the scoring protocol handles explicitly; it never fails the build.

| check | type | violations | status |
|---|---|---:|---|
| probability_domain_accepted | hard | 0 | pass |
| accepted_forecasts_join_questions | hard | 0 | pass |
| binary_outcomes_are_a_or_b | hard | 0 | pass |
| question_accounting_identity | hard | 0 | pass |
| forecast_accounting_identity | hard | 0 | pass |
| binary_view_one_row_per_event | hard | 0 | pass |
| forecasts_outside_question_window | soft | 27456 | reported |
| fb_probability_and_resolution_domain | hard | 0 | pass |
| fb_binary_nonempty | hard | 0 | pass |
| fb_scored_sources_are_dataset_type | hard | 0 | pass |
| fb_one_row_per_forecaster_question_horizon | hard | 0 | pass |
| fb_question_accounting_identity | hard | 0 | pass |
| fb_forecast_accounting_identity | hard | 0 | pass |
| gjp_scores_within_brier_range | hard | 0 | pass |
| gjp_events_all_have_cohorts | hard | 0 | pass |
| gjp_panel_days_match_scored_days | hard | 0 | pass |
| gjp_panel_one_row_per_forecaster_day | hard | 0 | pass |
| forecast_ifp_ids_absent_from_questions | soft | 0 | pass |
| condition_codes_recognized | soft | 0 | pass |

## Accounting — Good Judgment Project

| level | reason | n |
|---|---|---:|
| forecast_row | source_rows | 3143460 |
| forecast_row | question_not_in_analysis_set | 1739566 |
| forecast_row | accepted | 1403894 |
| forecast_row | exact_duplicate_dropped | 0 |
| question | accepted | 303 |
| question | voided | 119 |
| question | ordered_multinomial | 84 |
| question | conditional_ifp | 79 |
| question | multinomial | 32 |

## Accounting — ForecastBench

| level | reason | n |
|---|---|---:|
| resolution | source_entries_all_sets | 7561 |
| resolution | combo_dropped | 5992 |
| resolution | human_set | 596 |
| question | human_set | 200 |
| question | market_excluded | 90 |
| question | dataset_kept | 110 |
| question | dataset_scored | 105 |
| question | dataset_no_resolution | 5 |
| forecast_row | source_entries | 55372 |
| forecast_row | market_question_entries | 5096 |
| forecast_row | probability_out_of_domain | 281 |
| forecast_row | duplicate_horizon_entries_collapsed | 0 |
| forecast_row | horizon_entries_kept | 49995 |
| forecast_row | entries_on_unresolved_question | 2368 |
| forecast_row | horizon_without_resolution | 18028 |
| forecast_row | scored_rows_binary | 29599 |
