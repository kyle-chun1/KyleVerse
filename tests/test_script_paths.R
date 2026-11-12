# Exercise unchanged CLIs from unrelated directories without mutating this repo.
repo <- normalizePath(".")
count <- 0L
check <- function(label, code) { force(code); count <<- count + 1L; cat("PASS:", label, "\n") }
run <- function() {
  initial <- getwd()
  fixture <- tempfile("R scripts with spaces ")
  outside <- tempfile("caller directory ")
  dir.create(file.path(fixture, "scripts"), recursive = TRUE)
  dir.create(file.path(fixture, "data"))
  dir.create(outside)
  on.exit({ setwd(initial); unlink(c(fixture, outside), recursive = TRUE) }, add = TRUE)
  for (name in c("curation.R", "reading_email.R", "test_email.R", "shared.R"))
    file.copy(file.path(repo, "scripts", name), file.path(fixture, "scripts", name))
  file.copy(file.path(repo, "data/curated-passages.json"), file.path(fixture, "data/curated-passages.json"))
  file.copy(file.path(repo, "data/bible-books.json"), file.path(fixture, "data/bible-books.json"))
  file.copy(file.path(repo, "index.qmd"), file.path(fixture, "index.qmd"))
  catalog <- jsonlite::read_json(file.path(fixture, "data/curated-passages.json"))
  catalog$Romans <- list()
  jsonlite::write_json(catalog, file.path(fixture, "data/curated-passages.json"), auto_unbox = TRUE)
  setwd(outside)
  cli <- function(name, args = character(), env = character()) {
    output <- suppressWarnings(system2(Sys.which("Rscript"),
      shQuote(c(file.path(fixture, "scripts", name), args)), stdout = TRUE, stderr = TRUE, env = env))
    list(status = if (is.null(attr(output, "status"))) 0L else attr(output, "status"), output = output)
  }
  check("Curation validation locates its repository from an unrelated working directory", {
    stopifnot(cli("curation.R", "validate")$status == 0L)
  })
  check("Preparation resolves the draft relative to the caller and preserves approval gates", {
    jsonlite::write_json(list(list(reference = "Romans 8:38-39", context = "Reference-only test context.")),
      "draft with spaces.json", auto_unbox = TRUE)
    result <- cli("curation.R", c("prepare", "Romans", "draft with spaces.json"))
    stopifnot(result$status == 0L)
    result <- cli("curation.R", c("approve", "Romans", "Romans 8:38-39"))
    stopifnot(result$status == 1L)
    data <- jsonlite::read_json(file.path(fixture, "data/curated-passages.json"))
    entry <- tail(data$Romans, 1)[[1]]
    stopifnot(entry$status == "suggested")
  })
  check("One-time email CLI defaults to dry run outside the repository", {
    result <- cli("test_email.R")
    stopifnot(result$status == 0L, any(grepl("DRY RUN", result$output)))
  })
  check("Normal email dry run finds Git history independently of the caller directory", {
    # Read existing commits only; no credentials or network operations.
    sha <- system2("git", c("-C", shQuote(repo), "rev-parse", "HEAD"), stdout = TRUE)
    output <- system2(Sys.which("Rscript"), shQuote(file.path(repo, "scripts/reading_email.R")),
      stdout = TRUE, stderr = TRUE,
      env = c(paste0("READING_PREVIOUS_SHA=", sha), paste0("READING_CURRENT_SHA=", sha)))
    stopifnot(is.null(attr(output, "status")), any(grepl("no email sent", output)))
  })
  check("Sourcing each CLI from another directory does not import other CLIs", {
    for (name in c("curation.R", "reading_email.R", "test_email.R")) {
      scope <- new.env(parent = globalenv())
      source(file.path(fixture, "scripts", name), local = scope)
      stopifnot(identical(scope$PROJECT_ROOT, normalizePath(fixture)), is.function(scope$safe_cli))
      if (name != "curation.R") stopifnot(!exists("curation_main", scope, inherits = FALSE))
      if (name == "test_email.R") stopifnot(!exists("reading_email_main", scope, inherits = FALSE))
    }
  })
  check("Errors from foreign-directory commands remain sanitized", {
    result <- cli("curation.R", c("prepare", "Romans", "PRIVATE-MISSING-DRAFT.json"))
    stopifnot(result$status == 1L, !any(grepl("PRIVATE-MISSING-DRAFT", result$output)))
  })
}
run()
cat(count, "cross-directory script checks passed. No email sent.\n")
