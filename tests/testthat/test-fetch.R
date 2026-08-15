make_manifest <- function(path, bytes = file.size(path), md5 = file_md5(path),
                          required = TRUE) {
  data.frame(
    filename = basename(path),
    dataverse_file_id = 1L,
    bytes = bytes,
    md5 = md5,
    role = "test",
    required = required
  )
}

test_that("verify_raw passes a file with matching size and md5", {
  dir <- tempfile()
  dir.create(dir)
  path <- file.path(dir, "a.csv")
  writeLines("x,y\n1,2", path)
  res <- verify_raw(make_manifest(path), dir)
  expect_true(all(res$present, res$size_ok, res$md5_ok))
})

test_that("verify_raw flags a missing file", {
  dir <- tempfile()
  dir.create(dir)
  path <- file.path(dir, "a.csv")
  writeLines("x", path)
  manifest <- make_manifest(path)
  file.remove(path)
  res <- verify_raw(manifest, dir)
  expect_false(res$present)
  expect_false(res$md5_ok)
})

test_that("verify_raw flags a size mismatch", {
  dir <- tempfile()
  dir.create(dir)
  path <- file.path(dir, "a.csv")
  writeLines("x", path)
  manifest <- make_manifest(path, bytes = file.size(path) + 1)
  res <- verify_raw(manifest, dir)
  expect_true(res$present)
  expect_false(res$size_ok)
})

test_that("verify_raw flags an md5 mismatch", {
  dir <- tempfile()
  dir.create(dir)
  path <- file.path(dir, "a.csv")
  writeLines("x", path)
  manifest <- make_manifest(path, md5 = strrep("0", 32))
  res <- verify_raw(manifest, dir)
  expect_true(res$size_ok)
  expect_false(res$md5_ok)
})

test_that("require_verified_raw stops on corrupted required file", {
  dir <- tempfile()
  dir.create(dir)
  path <- file.path(dir, "a.csv")
  writeLines("x", path)
  manifest <- make_manifest(path, md5 = strrep("0", 32))
  expect_error(require_verified_raw(manifest, dir), "failed verification")
})
