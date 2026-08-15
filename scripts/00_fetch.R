source(file.path("R", "fetch.R"))

manifest <- read_manifest()
res <- verify_raw(manifest)
print(res, row.names = FALSE)
require_verified_raw(manifest)
cat("raw data verified\n")
