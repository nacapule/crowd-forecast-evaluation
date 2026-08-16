# Raw-data acquisition: manifest verification and download instructions.
#
# Harvard Dataverse fronts all endpoints (including file access) with a
# browser-verification wall, so the raw files cannot be fetched by script.
# Files are downloaded manually in a browser and verified here against
# data/manifest.csv before anything downstream runs.

manifest_path <- function() file.path("data", "manifest.csv")
raw_dir <- function() file.path("data", "raw")

read_manifest <- function(path = manifest_path()) {
  readr::read_csv(path, col_types = readr::cols(
    filename = readr::col_character(),
    dataverse_file_id = readr::col_integer(),
    bytes = readr::col_double(),
    md5 = readr::col_character(),
    role = readr::col_character(),
    required = readr::col_logical()
  ))
}

file_md5 <- function(path) {
  unname(tools::md5sum(path))
}

# Compare files under `dir` against the manifest. Returns one row per
# manifest entry with presence, size, and checksum results.
verify_raw <- function(manifest, dir = raw_dir()) {
  checks <- lapply(seq_len(nrow(manifest)), function(i) {
    row <- manifest[i, ]
    path <- file.path(dir, row$filename)
    present <- file.exists(path)
    size_ok <- present && file.size(path) == row$bytes
    md5_ok <- size_ok && identical(file_md5(path), row$md5)
    data.frame(
      filename = row$filename,
      required = row$required,
      present = present,
      size_ok = size_ok,
      md5_ok = md5_ok
    )
  })
  do.call(rbind, checks)
}

print_fetch_instructions <- function(missing_files) {
  gjp <- missing_files[!startsWith(missing_files, "forecastbench/")]
  fb <- missing_files[startsWith(missing_files, "forecastbench/")]
  if (length(gjp) > 0) {
    cat("Missing GJP files. Download them in a browser from:\n")
    cat("  https://doi.org/10.7910/DVN/BPCDH5\n")
    cat("(Good Judgment Project, 'GJP Data', Harvard Dataverse, CC0 1.0.\n")
    cat("The Dataverse blocks scripted downloads.)\n")
    cat("For survey_fcasts.yr*.csv choose the original comma-separated format\n")
    cat("('Access File' -> 'Comma Separated Values (Original File Format)').\n")
    cat("Place the files in data/raw/ with these names:\n")
    for (f in gjp) cat("  -", f, "\n")
  }
  if (length(fb) > 0) {
    cat("Missing ForecastBench files. Fetch them (pinned commit) with:\n")
    cat("  sh scripts/fetch_forecastbench.sh\n")
    for (f in fb) cat("  -", f, "\n")
  }
}

# Stops unless every required file is present with matching size and MD5.
require_verified_raw <- function(manifest = read_manifest(), dir = raw_dir()) {
  res <- verify_raw(manifest, dir)
  req <- res[res$required, ]
  if (!all(req$present)) {
    print_fetch_instructions(req$filename[!req$present])
    stop("required raw files missing", call. = FALSE)
  }
  bad <- req[!req$md5_ok, ]
  if (nrow(bad) > 0) {
    stop(
      "raw files failed verification (size or MD5): ",
      paste(bad$filename, collapse = ", "),
      call. = FALSE
    )
  }
  invisible(res)
}
