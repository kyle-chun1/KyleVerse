source("scripts/validate.R")
root <- normalizePath(".")
count <- 0L
check <- function(label, code) { force(code); count <<- count + 1L; cat("PASS:", label, "\n") }
check("All suites and safeguards run in the right order without real subprocesses", {
  calls <- list()
  output <- capture.output(status <- validate_project(root, function(command, args) {
    calls[[length(calls) + 1L]] <<- list(command = command, args = args)
    0L
  }))
  stopifnot(status == 0L, identical(calls[[1]]$args, c("scripts/curation.R", "validate")))
  executed <- vapply(calls, function(call) paste(call$args, collapse = " "), character(1))
  expected_tests <- sort(list.files("tests", pattern = "^test_.*\\.R$", full.names = TRUE))
  stopifnot(all(expected_tests %in% executed),
    identical(tail(executed, 4), c("-B -m unittest discover -s tests -v", "render",
      "scripts/check_links.R", "-B scripts/verse_of_day.py verify-output")),
    !any(grepl("--send|--send-test|publish| fetch", executed)))
})
check("Failure stops later steps and never prints exceptions", {
  calls <- 0L
  output <- capture.output(status <- validate_project(root, function(...) {
    calls <<- calls + 1L
    stop("PRIVATE-EXCEPTION-MARKER")
  }))
  stopifnot(status == 1L, calls == 1L, !any(grepl("PRIVATE-EXCEPTION-MARKER", output)), any(grepl("FAIL:", output)))
})
check("Child failure status propagates", {
  output <- capture.output(status <- validate_project(root, function(...) 2L))
  stopifnot(status == 1L)
})
check("Secrets are removed for checks and restored afterward", {
  before <- Sys.getenv("ESV_API_TOKEN", unset = NA_character_)
  Sys.setenv(ESV_API_TOKEN = "TEST-ONLY-ENV-MARKER")
  output <- capture.output(status <- validate_project(root, function(...) {
    stopifnot(Sys.getenv("ESV_API_TOKEN") == "")
    0L
  }))
  stopifnot(status == 0L, Sys.getenv("ESV_API_TOKEN") == "TEST-ONLY-ENV-MARKER")
  if (is.na(before)) Sys.unsetenv("ESV_API_TOKEN") else Sys.setenv(ESV_API_TOKEN = before)
})
check("Subprocess output is captured rather than echoed", {
  output <- capture.output(status <- run_validation_step(Sys.which("Rscript"),
    c("-e", 'cat("PRIVATE-OUTPUT-MARKER"); quit(status=2)')))
  stopifnot(status == 2L, !any(grepl("PRIVATE-OUTPUT-MARKER", output)))
})
cat(count, "validator checks passed using mocked orchestration.\n")
