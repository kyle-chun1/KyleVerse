# One local validation command. All checks run in isolated child processes.
# Child output is captured rather than echoed: exceptions can contain private data.
run_validation_step <- function(command, args) {
  output <- suppressWarnings(system2(command, shQuote(args), stdout = TRUE, stderr = TRUE))
  status <- attr(output, "status")
  if (is.null(status)) 0L else as.integer(status)
}

validate_project <- function(root, runner = run_validation_step) {
  previous_directory <- getwd()
  on.exit(setwd(previous_directory), add = TRUE)
  setwd(root)
  # Local checks never need credentials, SMTP delivery, or GitHub write access.
  secret_names <- c("ESV_API_TOKEN", "GMAIL_SMTP_USER", "GMAIL_SMTP_APP_PASSWORD",
                    "KYLEVERSE_NOTIFICATION_EMAIL", "GH_TOKEN", "GITHUB_TOKEN")
  previous <- Sys.getenv(secret_names, unset = NA_character_)
  on.exit({
    Sys.unsetenv(secret_names)
    present <- !is.na(previous)
    if (any(present)) do.call(Sys.setenv, as.list(previous[present]))
  }, add = TRUE)
  Sys.unsetenv(secret_names)

  tools <- Sys.which(c("Rscript", "python3", "quarto"))
  if (any(!nzchar(tools))) stop("Install Rscript, python3, and Quarto before validating.", call. = FALSE)
  if (!all(vapply(c("jsonlite", "curl"), requireNamespace, logical(1), quietly = TRUE)))
    stop("Install the existing R packages jsonlite and curl before validating.", call. = FALSE)
  r_tests <- sort(list.files("tests", pattern = "^test_.*\\.R$", full.names = TRUE))
  if (!length(r_tests)) stop("No R test suites found.", call. = FALSE)
  steps <- list(list(label = "Curated catalog", tool = "Rscript", args = c("scripts/curation.R", "validate")))
  for (test in r_tests)
    steps[[length(steps) + 1L]] <- list(label = paste("R tests:", basename(test)), tool = "Rscript", args = test)
  steps <- c(steps, list(
    list(label = "Python Scripture tests", tool = "python3", args = c("-B", "-m", "unittest", "discover", "-s", "tests", "-v")),
    list(label = "Quarto website render", tool = "quarto", args = "render"),
    list(label = "Generated internal links", tool = "Rscript", args = "scripts/check_links.R"),
    list(label = "ESV rendered-output verification", tool = "python3", args = c("-B", "scripts/verse_of_day.py", "verify-output"))
  ))
  for (i in seq_along(steps)) {
    step <- steps[[i]]
    cat(sprintf("[%d/%d] %s ...\n", i, length(steps), step$label))
    status <- tryCatch(runner(unname(tools[[step$tool]]), step$args), error = function(error) 1L)
    if (!identical(status, 0L)) {
      cat("FAIL: ", step$label, ". Details withheld to protect sensitive data.\n", sep = "")
      return(invisible(1L))
    }
    cat("PASS: ", step$label, "\n", sep = "")
  }
  cat("All project validation checks passed. No email sent or site published.\n")
  invisible(0L)
}

if (sys.nframe() == 0L) {
  status <- tryCatch({
    script <- sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE)[1])
    root <- dirname(dirname(normalizePath(script, mustWork = TRUE)))
    validate_project(root)
  }, error = function(error) {
    message("Validation could not complete. Check required tools, R packages, and project access. Sensitive error details were suppressed.")
    1L
  })
  quit(status = status)
}
