# QA report

Generated: 2026-08-15 12:29:35 CST

## Checks

| check | type | violations | pass |
|---|---|---:|---|
| probability_domain_accepted | hard | 0 | yes |
| accepted_forecasts_join_questions | hard | 0 | yes |
| binary_outcomes_are_a_or_b | hard | 0 | yes |
| question_accounting_identity | hard | 0 | yes |
| forecast_accounting_identity | hard | 0 | yes |
| binary_view_one_row_per_event | hard | 0 | yes |
| forecasts_outside_question_window | soft | 27456 | NO |
| forecast_ifp_ids_absent_from_questions | soft | 0 | yes |
| condition_codes_recognized | soft | 0 | yes |

## Accounting

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
