# Reference curation only. Scripture text continues to come exclusively from Crossway.
# Run from the repository root; jsonlite is the only package used by this tool.

curation_error <- function(message) stop(message, call. = FALSE)
scalar_text <- function(x) is.character(x) && length(x) == 1L && !is.na(x) && nzchar(trimws(x))

normalize_reference <- function(reference, book) {
  if (!scalar_text(reference)) curation_error("A reference is required.")
  reference <- trimws(gsub("\u2013", "-", reference, fixed = TRUE))
  if (book == "Psalms") reference <- sub("^Psalm ", "Psalms ", reference)
  prefix <- paste0(book, " ")
  if (!startsWith(reference, prefix)) curation_error("The reference must belong to the requested book.")
  part <- substring(reference, nchar(prefix) + 1L)
  match <- regmatches(part, regexec("^([1-9][0-9]*):([1-9][0-9]*)(?:-([1-9][0-9]*))?$", part, perl = TRUE))[[1]]
  if (!length(match)) curation_error("Use a single chapter and one to three whole verses, e.g. Romans 8:38-39.")
  chapter <- as.numeric(match[2]); first <- as.numeric(match[3])
  last <- if (nzchar(match[4])) as.numeric(match[4]) else first
  if (any(!is.finite(c(chapter, first, last))) || chapter >= 1000 || last >= 1000 || last < first || last - first > 2)
    curation_error("Use a single chapter and one to three whole verses.")
  paste0(book, " ", chapter, ":", first, if (first != last) paste0("-", last) else "")
}

validate_catalog <- function(catalog) {
  if (!is.list(catalog) || is.null(names(catalog)) || anyDuplicated(names(catalog)))
    curation_error("The catalog must have unique book names as object keys.")
  allowed <- c("reference", "context", "theme", "status", "approval_source", "reviewed_at")
  for (book in names(catalog)) {
    entries <- catalog[[book]]
    if (!is.list(entries) || !is.null(names(entries))) curation_error("Each book must contain an array of entries.")
    seen <- character()
    for (entry in entries) {
      if (!is.list(entry) || is.null(names(entry)) || anyDuplicated(names(entry)) || any(!names(entry) %in% allowed))
        curation_error("Entries may contain only reference, context, theme, status, and approval audit fields; never Scripture text.")
      reference <- normalize_reference(entry$reference, book)
      if (reference %in% seen) curation_error(paste("Duplicate passage:", reference))
      seen <- c(seen, reference)
      if (!scalar_text(entry$context)) curation_error(paste("A context note is required for", reference))
      if (!scalar_text(entry$status) || !entry$status %in% c("suggested", "approved", "rejected"))
        curation_error(paste("Use suggested, approved, or rejected for", reference))
      for (field in intersect(c("theme", "approval_source", "reviewed_at"), names(entry)))
        if (!scalar_text(entry[[field]])) curation_error(paste("Invalid", field, "for", reference))
      if (entry$status == "approved" && (!scalar_text(entry$approval_source) ||
          !entry$approval_source %in% c("user-confirmed", "existing-active-collection")))
        curation_error(paste("Approved entries require an explicit approval source:", reference))
      if (identical(entry$approval_source, "user-confirmed") && !scalar_text(entry$reviewed_at))
        curation_error(paste("User-confirmed decisions require a review timestamp:", reference))
    }
  }
  invisible(catalog)
}

load_catalog <- function(root = ".") {
  catalog <- jsonlite::read_json(file.path(root, "data/curated-passages.json"), simplifyVector = FALSE)
  validate_catalog(catalog)
  catalog
}

save_catalog <- function(catalog, root = ".") {
  validate_catalog(catalog)
  path <- file.path(root, "data/curated-passages.json")
  temporary <- tempfile("curation-", tmpdir = dirname(path))
  on.exit(unlink(temporary), add = TRUE)
  jsonlite::write_json(catalog, temporary, auto_unbox = TRUE, pretty = TRUE, null = "null")
  if (!file.rename(temporary, path)) curation_error("Could not replace the catalog; the original was preserved.")
  invisible(catalog)
}

require_book <- function(catalog, book) {
  if (!scalar_text(book) || !book %in% names(catalog)) curation_error("Use an existing canonical book key from the catalog.")
}

approved_entries <- function(catalog, book) {
  require_book(catalog, book)
  Filter(function(entry) identical(entry$status, "approved"), catalog[[book]])
}

reading_book <- function(text) {
  lines <- strsplit(text, "\n", fixed = TRUE)[[1]]
  delimiters <- which(trimws(lines) == "---")
  if (length(delimiters) < 2L || delimiters[1] != 1L) curation_error("Homepage YAML metadata is missing.")
  header <- lines[seq.int(2L, delimiters[2] - 1L)]
  field <- grep("^current-bible-book:[ \t]*", header, value = TRUE)
  if (length(field) != 1L) curation_error("Set exactly one current-bible-book field in index.qmd.")
  value <- trimws(sub("^current-bible-book:[ \t]*", "", field))
  if (startsWith(value, '"')) value <- jsonlite::fromJSON(value)
  else if (startsWith(value, "'") && endsWith(value, "'")) value <- substring(value, 2L, nchar(value) - 1L)
  if (!scalar_text(value)) curation_error("Invalid current-bible-book metadata.")
  value
}

read_homepage <- function(root = ".") paste(readLines(file.path(root, "index.qmd"), warn = FALSE, encoding = "UTF-8"), collapse = "\n")

prepare_book <- function(book, candidates, root = ".") {
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

review_passage <- function(book, reference, decision, confirmed = FALSE, root = ".") {
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

append_passage <- function(book, reference, context, theme = NULL, confirmed = FALSE, root = ".") {
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

switch_book <- function(book, root = ".") {
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

show_book <- function(book, root = ".") {
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

safe_cli <- function(action, failure_message) {
  tryCatch(withCallingHandlers({
    action()
    0L
  }, warning = function(warning) invokeRestart("muffleWarning")),
  error = function(error) {
    message(failure_message)
    1L
  })
}

if (sys.nframe() == 0L) {
  quit(status = safe_cli(function() curation_main(),
    "Curation failed. Check the command, JSON, references, and review confirmation. Error details were suppressed."))
}
