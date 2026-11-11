source("scripts/check_links.R")
root <- tempfile("link-check-")
dir.create(root)
# All fixtures and cleanup are confined to this disposable test directory.
run <- function() {
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  writeLines("<html></html>", file.path(root, "photography.html"))
  dir.create(file.path(root, "nested"))
  writeLines("<html></html>", file.path(root, "nested/index.html"))
  fails <- function(html) {
    writeLines(html, file.path(root, "index.html"))
    stopifnot(tryCatch({ check_internal_links(root); FALSE }, error = function(error) TRUE))
  }
  writeLines('<a href="photography.html?view=1#photo">Photo</a><a href="nested/">Nested</a><a href="/photography.html">Root</a><a href="https://example.invalid/">External</a><a href="#top">Top</a>', file.path(root, "index.html"))
  writeLines("<a href='../photography.html'>Photo</a>", file.path(root, "nested/index.html"))
  check_internal_links(root)
  fails('<a href="Photography.html">Wrong case</a>')
  fails('<a href="missing.html">Missing</a>')
  # Even an existing source file must never make an unresolved .qmd link valid.
  writeLines("placeholder", file.path(root, "photography.qmd"))
  fails('<a href="photography.qmd">Unrendered</a>')
  fails('<a href="../outside.html">Outside output</a>')
  cat("5 link-validation scenarios passed, including case mismatch on macOS.\n")
}
run()
