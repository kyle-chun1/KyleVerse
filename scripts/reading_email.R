# Journaled reading-book notifications, independent of publication; dry run by default.
.script_path <- local({
  sources <- Filter(is.character, lapply(sys.frames(), function(frame) frame$ofile))
  path <- if (length(sources)) tail(sources, 1L)[[1]] else
    gsub("~+~", " ", sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE)[1]), fixed = TRUE)
  normalizePath(path, mustWork = TRUE)
})
source(file.path(dirname(.script_path), "shared.R"), local = TRUE)
source(file.path(dirname(.script_path), "notification_state.R"), local = TRUE)

git_revision_file <- function(sha, path, root = PROJECT_ROOT) {
  if (!valid_sha(sha) || !path %in% c("index.qmd", "data/curated-passages.json"))
    curation_error("Invalid reading-notification revision or path.")
  result <- suppressWarnings(system2("git", c("-C", shQuote(root), "show", shQuote(paste0(sha, ":", path))), stdout = TRUE, stderr = FALSE))
  if (!is.null(attr(result, "status"))) curation_error("Could not read reading metadata from the published Git revision.")
  paste(result, collapse = "\n")
}

reading_notification <- function(previous_sha, current_sha, root = PROJECT_ROOT, reader = git_revision_file) {
  if (!valid_sha(current_sha)) curation_error("A valid current publication SHA is required.")
  if (!scalar_text(previous_sha) || identical(previous_sha, strrep("0", 40))) return(NULL)
  previous <- reading_book(reader(previous_sha, "index.qmd", root))
  current <- reading_book(reader(current_sha, "index.qmd", root))
  if (identical(previous, current)) return(NULL)
  catalog <- jsonlite::fromJSON(reader(current_sha, "data/curated-passages.json", root), simplifyVector = FALSE)
  validate_catalog(catalog)
  require_book(catalog, previous)
  require_book(catalog, current)
  entries <- Filter(function(entry) entry$status != "rejected", catalog[[current]])
  suggestions <- vapply(entries, function(entry) {
    paste0("- [", toupper(entry$status), "] ", entry$reference,
      "\n  Context: ", entry$context,
      if (!is.null(entry$theme)) paste0("\n  Theme: ", entry$theme) else "")
  }, character(1))
  body <- paste(c(
    paste0("You have started ", current, " on KyleVerse."), "",
    paste0("Would you like to add any new passage references from ", previous, ", the book you just finished?"),
    "Your previous book's collection has been retained. Send Codex any references and contextual notes you want to add; explicitly approve each reference after reviewing it.", "",
    paste0("Potential passage references for ", current, ":"),
    if (length(suggestions)) suggestions else "No candidates have been prepared yet. Ask Codex to prepare approximately 10-15 suggestions for this book.", "",
    "SUGGESTED references are unapproved and cannot enter the daily rotation. APPROVED references are already active. Check the surrounding chapter before approving anything.",
    if (!length(approved_entries(catalog, current))) "No approved passages exist for this book, so the website will display unavailable." else NULL,
    "This email contains references and editorial notes only, not Scripture text. Replying does not automatically approve passages.", "",
    "https://kyle-chun1.github.io/KyleVerse/"
  ), collapse = "\n")
  list(previous = previous, current = current, subject = paste("KyleVerse reading:", previous, "to", current),
       body = body, id = paste0("kyleverse-reading-", current_sha))
}

reading_email_main <- function(args = commandArgs(trailingOnly = TRUE)) {
  # Only --send initiates a network operation. The default prints a reviewable draft.
  send <- "--send" %in% args
  current <- Sys.getenv("READING_CURRENT_SHA")
  previous <- Sys.getenv("READING_PREVIOUS_SHA")
  if (send) {
    if (Sys.getenv("GITHUB_ACTIONS") != "true" || Sys.getenv("GITHUB_REF") != "refs/heads/main" ||
        !Sys.getenv("GITHUB_EVENT_NAME") %in% c("push", "schedule", "workflow_dispatch") ||
        !grepl("^[0-9]+$", Sys.getenv("GITHUB_RUN_ID")) || !grepl("^[0-9]+$", Sys.getenv("GITHUB_RUN_ATTEMPT")))
      notification_error("CONFIGURATION_INVALID")
    origin <- tryCatch(jsonlite::read_json(file.path(PROJECT_ROOT, "data/notification-origin.json"))$baseline_sha,
      error = function(error) notification_error("CONFIGURATION_INVALID"))
    initialize <- Sys.getenv("GITHUB_EVENT_NAME") == "workflow_dispatch" &&
      Sys.getenv("NOTIFICATION_INITIALIZE") == "INITIALIZE NOTIFICATION JOURNAL"
    return(process_reading_notifications(github_notification_store(origin, initialize = initialize), current,
      paste(Sys.getenv("GITHUB_RUN_ID"), Sys.getenv("GITHUB_RUN_ATTEMPT"), sep = ":")))
  }
  notification <- reading_notification(previous, current)
  if (is.null(notification)) {
    cat("No published book transition to notify; no email sent.\n")

  } else {
    cat("DRY RUN - no email sent\nTo: configured notification recipient",
        "\nSubject:", notification$subject, "\n\n", notification$body, "\n")
  }
}

if (sys.nframe() == 0L) {
  quit(status = notification_cli(function() reading_email_main()))
}
