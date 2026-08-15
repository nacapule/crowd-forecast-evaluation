source(file.path("R", "ingest.R"))
source(file.path("R", "qa.R"))

res <- run_qa_gate()
print(res[, c("check", "hard", "n_violations", "pass")], row.names = FALSE)
cat("QA gate passed; report written to qa/qa_report.md\n")
