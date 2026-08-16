ifps_header <- paste(
  c(
    "ifp_id", "q_type", "q_text", "q_desc", "q_status", "date_start",
    "date_suspend", "date_to_close", "date_closed", "outcome",
    "short_title", "days_open", "n_opts", "options"
  ),
  collapse = ","
)

ifps_row <- function(id, q_type, q_text, outcome, n_opts) {
  paste(
    c(
      id, q_type, shQuote(q_text, "cmd"), "\"d\"", "closed", "9/1/11",
      "12/30/11 0:00", "12/31/11", "1/2/12", outcome, "\"S\"", "120",
      n_opts, "\"(a) Yes, (b) No\""
    ),
    collapse = ","
  )
}

test_that("read_ifps handles CR-only line endings", {
  path <- tempfile(fileext = ".csv")
  lines <- c(
    ifps_header,
    ifps_row("1001-0", 0, "Q?", "b", 2),
    ifps_row("1002-0", 6, "Q2?", "a", 4)
  )
  writeChar(paste0(paste(lines, collapse = "\r"), "\r"), path, eos = NULL)
  ifps <- read_ifps(path)
  expect_equal(nrow(ifps), 2)
  expect_equal(ifps$ifp_id, c("1001-0", "1002-0"))
})

test_that("read_ifps converts Latin-1 text to UTF-8", {
  path <- tempfile(fileext = ".csv")
  row <- ifps_row("1001-0", 0, "Caf? question", "b", 2)
  txt <- paste0(ifps_header, "\r", row, "\r")
  bytes <- charToRaw(txt)
  bytes[bytes == charToRaw("?")] <- as.raw(0xe9)
  writeBin(bytes, path)
  ifps <- read_ifps(path)
  expect_equal(nrow(ifps), 1)
  expect_equal(ifps$q_text, "Café question")
})

test_that("parse_mdy handles dates with and without a time of day", {
  expect_equal(parse_mdy("9/1/11"), as.Date("2011-09-01"))
  expect_equal(parse_mdy("12/30/11 0:00"), as.Date("2011-12-30"))
})

test_that("prepare_questions derives type and status flags", {
  q <- prepare_questions(read_ifps(fixture_path("ifps.csv")))
  expect_equal(nrow(q), 7)
  expect_true(q$is_binary[q$ifp_id == "1001-0"])
  expect_true(q$is_conditional[q$ifp_id == "1004-1"])
  expect_true(q$is_ordered[q$ifp_id == "1003-0"])
  expect_true(q$is_voided[q$ifp_id == "1005-0"])
  expect_false(q$is_binary[q$ifp_id == "1002-0"])
  expect_equal(q$base_id[q$ifp_id == "1004-1"], "1004")
})

test_that("build_db accepts and rejects questions with stated reasons", {
  con <- build_fixture_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  accepted <- DBI::dbGetQuery(con, "SELECT ifp_id FROM questions_accepted")
  expect_setequal(accepted$ifp_id, c("1001-0", "1006-0"))
  rejected <- DBI::dbGetQuery(
    con, "SELECT ifp_id, reason FROM questions_rejected"
  )
  expect_equal(
    rejected$reason[rejected$ifp_id == "1002-0"], "multinomial"
  )
  expect_equal(
    rejected$reason[rejected$ifp_id == "1003-0"], "ordered_multinomial"
  )
  expect_equal(
    rejected$reason[rejected$ifp_id == "1004-1"], "conditional_ifp"
  )
  expect_equal(rejected$reason[rejected$ifp_id == "1005-0"], "voided")
  expect_equal(rejected$reason[rejected$ifp_id == "1007-0"], "not_closed")
})

test_that("build_db accounts for every forecast row exactly once", {
  con <- build_fixture_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  acct <- DBI::dbGetQuery(con, "SELECT * FROM qa_accounting")
  n <- function(level, reason) {
    acct$n[acct$level == level & acct$reason == reason]
  }
  expect_equal(n("forecast_row", "source_rows"), 27)
  expect_equal(n("forecast_row", "exact_duplicate_dropped"), 1)
  expect_equal(n("forecast_row", "accepted"), 16)
  total <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM forecasts")$n
  rej <- DBI::dbGetQuery(con, "SELECT count(*) AS n FROM forecasts_rejected")$n
  expect_equal(total, 26)
  expect_equal(rej + n("forecast_row", "accepted"), total)
})

test_that("forecast rejections carry the expected reasons", {
  con <- build_fixture_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  rej <- DBI::dbGetQuery(
    con, "SELECT user_id, reason FROM forecasts_rejected"
  )
  expect_setequal(
    unique(rej$reason[rej$user_id == "u4"]), "probability_out_of_domain"
  )
  expect_setequal(
    unique(rej$reason[rej$user_id == "u5"]), "option_sum_not_one"
  )
  expect_setequal(
    unique(rej$reason[rej$user_id %in% c("u3", "u6")]),
    "question_not_in_analysis_set"
  )
})

test_that("binary view has one row per event with correct resolution", {
  con <- build_fixture_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  b <- DBI::dbGetQuery(con, "SELECT * FROM binary_forecasts ORDER BY user_id")
  expect_equal(nrow(b), 8)
  u1 <- b[b$user_id == "u1", ]
  expect_equal(u1$p[u1$ifp_id == "1001-0"], 0.2)
  expect_equal(u1$resolved_to[u1$ifp_id == "1001-0"], 0)
  expect_equal(u1$p[u1$ifp_id == "1006-0"], 0.9)
  expect_equal(u1$resolved_to[u1$ifp_id == "1006-0"], 1)
  expect_equal(b$fcast_type[b$user_id == "u8"], 4)
})

test_that("out-of-window forecasts are flagged but kept", {
  con <- build_fixture_db()
  on.exit(DBI::dbDisconnect(con, shutdown = TRUE))
  u7 <- DBI::dbGetQuery(
    con,
    "SELECT in_window FROM forecasts_accepted WHERE user_id = 'u7'"
  )
  expect_equal(nrow(u7), 2)
  expect_true(all(!u7$in_window))
})
