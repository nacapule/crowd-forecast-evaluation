test_that("all hard QA checks pass on the fixture build", {
  con <- build_fixture_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  res <- run_qa_checks(con)
  expect_true(all(res$pass[res$hard]))
})

test_that("soft checks report the expected fixture counts", {
  con <- build_fixture_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  res <- run_qa_checks(con)
  oow <- res[res$check == "forecasts_outside_question_window", ]
  expect_equal(oow$n_violations, 2)
  expect_false(oow$hard)
})

test_that("QA catches an injected probability-domain violation", {
  con <- build_fixture_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  DBI::dbExecute(
    con,
    "UPDATE forecasts_accepted SET value = 1.5
     WHERE user_id = 'u1' AND answer_option = 'a' AND ifp_id = '1001-0'"
  )
  res <- run_qa_checks(con)
  domain <- res[res$check == "probability_domain_accepted", ]
  expect_equal(domain$n_violations, 1)
  expect_false(domain$pass)
})

test_that("run_qa_gate writes a report and fails on hard violations", {
  db <- tempfile(fileext = ".duckdb")
  build_db(raw = fixture_path(), db = db)
  out <- tempfile(fileext = ".md")
  res <- run_qa_gate(db = db, out = out)
  expect_true(file.exists(out))
  expect_true(any(grepl("QA report", readLines(out))))

  con <- DBI::dbConnect(duckdb::duckdb(), dbdir = db)
  DBI::dbExecute(con, "UPDATE forecasts_accepted SET value = -1")
  DBI::dbDisconnect(con, shutdown = TRUE)
  expect_error(run_qa_gate(db = db, out = out), "QA gate failed")
})
