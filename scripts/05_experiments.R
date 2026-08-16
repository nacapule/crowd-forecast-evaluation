source(file.path("R", "ingest.R"))
source(file.path("R", "scoring.R"))
source(file.path("R", "aggregate.R"))
source(file.path("R", "experiments.R"))

res <- run_experiments()
cat("frozen settings (tuned on GJP years 1-2):\n")
print(data.frame(parameter = names(res$settings),
                 value = unlist(res$settings, use.names = FALSE)),
      row.names = FALSE)
cat("\nresults (mean question Brier, two-option scale):\n")
print(res$results, row.names = FALSE, digits = 3)
cat("\nresults written to analysis/results/\n")
