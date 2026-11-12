# Reference curation only. Scripture text continues to come exclusively from Crossway.
.script_path <- local({
  sources <- Filter(is.character, lapply(sys.frames(), function(frame) frame$ofile))
  path <- if (length(sources)) tail(sources, 1L)[[1]] else
    gsub("~+~", " ", sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE)[1]), fixed = TRUE)
  normalizePath(path, mustWork = TRUE)
})
source(file.path(dirname(.script_path), "shared.R"), local = TRUE)

load_catalog <- function(root = PROJECT_ROOT) {
  catalog <- jsonlite::read_json(file.path(root, "data/curated-passages.json"), simplifyVector = FALSE)
  validate_catalog(catalog)
  catalog
}

save_catalog <- function(catalog, root = PROJECT_ROOT) {
  validate_catalog(catalog)
  path <- file.path(root, "data/curated-passages.json")
  temporary <- tempfile("curation-", tmpdir = dirname(path))
  on.exit(unlink(temporary), add = TRUE)
  jsonlite::write_json(catalog, temporary, auto_unbox = TRUE, pretty = TRUE, null = "null")
  if (!file.rename(temporary, path)) curation_error("Could not replace the catalog; the original was preserved.")
  invisible(catalog)
}

read_homepage <- function(root = PROJECT_ROOT) paste(readLines(file.path(root, "index.qmd"), warn = FALSE, encoding = "UTF-8"), collapse = "\n")

prepare_book <- function(book, candidates, root = PROJECT_ROOT) {
  catalog <- load_catalog(root)
  require_book(catalog, book)
  if (!is.list(candidates) || !is.null(names(candidates)) || !length(candidates))
    curation_error("Provide a JSON array of reference/context suggestions.")
  # Validate the entire batch in memory before writing anything. No partial imports.
  for (candidate in candidates) {
    if (!is.list(candidate) || is.null(names(candidate)) || anyDuplicated(names(candidate)) ||
        any(!names(candidate) %in% c("reference", "context", "theme")))
      curation_error("Candidate imports accept only reference, context, and optional theme; approval cannot be imported.")
    candidate$reference <- normalize_reference(candidate$reference, book)
    candidate$status <- "suggested"
    catalog[[book]][[length(catalog[[book]]) + 1L]] <- candidate
  }
  save_catalog(catalog, root)
}

review_passage <- function(book, reference, decision, confirmed = FALSE, root = PROJECT_ROOT) {
  if (!decision %in% c("approved", "rejected")) curation_error("Choose approved or rejected.")
  if (decision == "approved" && !isTRUE(confirmed))
    curation_error("Approval requires --confirm-reviewed after your explicit review of this reference.")
  catalog <- load_catalog(root)
  require_book(catalog, book)
  key <- normalize_reference(reference, book)
  indexes <- which(vapply(catalog[[book]], function(entry) normalize_reference(entry$reference, book) == key, logical(1)))
  if (length(indexes) != 1L) curation_error("Reference not found; append it as a suggestion first.")
  entry <- catalog[[book]][[indexes]]
  entry$status <- decision
  entry$approval_source <- "user-confirmed"
  entry$reviewed_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  catalog[[book]][[indexes]] <- entry
  save_catalog(catalog, root)
}

append_passage <- function(book, reference, context, theme = NULL, confirmed = FALSE, root = PROJECT_ROOT) {
  candidate <- list(reference = reference, context = context)
  if (!is.null(theme)) candidate$theme <- theme
  # Build and review in memory so a failed approval cannot leave a partial write.
  catalog <- load_catalog(root)
  require_book(catalog, book)
  candidate$reference <- normalize_reference(reference, book)
  candidate$status <- if (isTRUE(confirmed)) "approved" else "suggested"
  if (isTRUE(confirmed)) {
    candidate$approval_source <- "user-confirmed"
    candidate$reviewed_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  }
  catalog[[book]][[length(catalog[[book]]) + 1L]] <- candidate
  save_catalog(catalog, root)
}

switch_book <- function(book, root = PROJECT_ROOT) {
  catalog <- load_catalog(root)
  require_book(catalog, book)
  if (!length(approved_entries(catalog, book))) curation_error("Approve at least one passage before switching books.")
  path <- file.path(root, "index.qmd")
  text <- read_homepage(root)
  previous <- reading_book(text)
  if (previous == book) return(invisible(FALSE))
  text <- sub("(?m)^current-bible-book:[^\n]*", paste0("current-bible-book: ", jsonlite::toJSON(book, auto_unbox = TRUE)), text, perl = TRUE)
  temporary <- tempfile("reading-", tmpdir = dirname(path))
  on.exit(unlink(temporary), add = TRUE)
  writeLines(enc2utf8(text), temporary, useBytes = TRUE)
  if (!file.rename(temporary, path)) curation_error("Could not update the homepage; the original was preserved.")
  invisible(TRUE)
}

show_book <- function(book, root = PROJECT_ROOT) {
  catalog <- load_catalog(root)
  require_book(catalog, book)
  if (!length(catalog[[book]])) cat(book, "has no candidates or approvals yet.\n")
  for (entry in catalog[[book]]) {
    cat(sprintf("[%s] %s\n  Context: %s\n", entry$status, entry$reference, entry$context))
    if (!is.null(entry$theme)) cat("  Theme:", entry$theme, "\n")
  }
}

curation_main <- function(args = commandArgs(trailingOnly = TRUE)) {
  if (!length(args)) curation_error("Commands: validate | show BOOK | prepare BOOK draft.json | approve BOOK REF --confirm-reviewed | reject BOOK REF | append BOOK REF --context NOTE [--theme THEME] [--confirm-reviewed] | switch BOOK")
  command <- args[1]
  if (command == "validate") {
    catalog <- load_catalog()
    require_book(catalog, reading_book(read_homepage()))
    cat("Catalog valid. Only explicitly approved entries may enter the daily rotation.\n")
    return(invisible(NULL))
  }
  if (length(args) < 2L) curation_error("A book name is required.")
  book <- args[2]
  if (command == "show") return(show_book(book))
  if (command == "switch") return(switch_book(book))
  if (length(args) < 3L) curation_error("A reference or candidate file is required.")
  if (command == "prepare") return(prepare_book(book, jsonlite::read_json(args[3], simplifyVector = FALSE)))
  confirmed <- "--confirm-reviewed" %in% args
  if (command %in% c("approve", "reject"))
    return(review_passage(book, args[3], if (command == "approve") "approved" else "rejected", confirmed))
  if (command == "append") {
    option <- function(flag, required = FALSE) {
      position <- which(args == flag)
      if (!length(position) && !required) return(NULL)
      if (length(position) != 1L || position >= length(args)) curation_error(paste("Provide", flag))
      args[position + 1L]
    }
    return(append_passage(book, args[3], option("--context", TRUE), option("--theme"), confirmed))
  }
  curation_error("Unknown curation command.")
}

if (sys.nframe() == 0L) {
  quit(status = safe_cli(function() curation_main(),
    "Curation failed. Check the command, JSON, references, and review confirmation. Error details were suppressed."))
}
