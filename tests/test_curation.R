# Base-R assertions: no test framework or live API/SMTP credentials required.
source("scripts/curation.R")
source("scripts/reading_email.R")
Sys.setenv(KYLEVERSE_NOTIFICATION_EMAIL = "recipient@example.invalid")
count <- 0L
check <- function(name, code) {
  force(code)
  count <<- count + 1L
  cat("PASS:", name, "\n")
}
fails <- function(code) {
  failed <- tryCatch({ force(code); FALSE }, error = function(error) TRUE)
  stopifnot(failed)
}
fixture <- function(code) {
  root <- tempfile("curation-test-")
  dir.create(file.path(root, "data"), recursive = TRUE)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  file.copy("data/curated-passages.json", file.path(root, "data/curated-passages.json"))
  homepage <- sub("(?m)^current-bible-book:[^\\n]*", 'current-bible-book: "Isaiah"', read_homepage(), perl = TRUE)
  writeLines(homepage, file.path(root, "index.qmd"))
  catalog <- load_catalog(root)
  catalog$Romans <- list()
  save_catalog(catalog, root)
  code(root)
}
candidates <- list(
  list(reference = "Romans 8:38-39", context = "Reference-only test note identifying Paul and the Roman believers.", theme = "Test theme"),
  list(reference = "Romans 12:9-11", context = "Reference-only test context for Paul's instructions to the church.")
)
selector <- function(root, day = "2026-11-10") {
  code <- paste0("import sys; from pathlib import Path; from datetime import date; ",
    "sys.path.insert(0, sys.argv[2]); import verse_of_day as v; ",
    "\ntry: print(v.selected_reference('Romans', date.fromisoformat(sys.argv[3]), Path(sys.argv[1])))",
    "\nexcept v.Unavailable: print('UNAVAILABLE')")
  result <- system2("python3", c("-c", shQuote(code), shQuote(root),
    shQuote(normalizePath("scripts")), shQuote(day)), stdout = TRUE, stderr = TRUE)
  stopifnot(is.null(attr(result, "status")))
  result
}

check("Existing collections validate without changing the homepage", {
  validate_catalog(load_catalog())
  stopifnot(reading_book(read_homepage()) %in% names(load_catalog()))
})
check("Reference normalization and invalid ranges", {
  stopifnot(normalize_reference("Romans 8:38\u201339", "Romans") == "Romans 8:38-39",
    normalize_reference("Romans 8:38-38", "Romans") == "Romans 8:38",
    normalize_reference("Psalm 23:1", "Psalms") == "Psalms 23:1")
  for (reference in c("Romans 8", "Romans 8:1-4", "Romans 8:0", "Romans 8:4-2", "Romans 8:1-9:1", "John 1:1"))
    fails(normalize_reference(reference, "Romans"))
})
check("Preparation appends unapproved entries without switching books", fixture(function(root) {
  homepage <- read_homepage(root)
  isaiah <- load_catalog(root)$Isaiah
  prepare_book("Romans", candidates, root)
  catalog <- load_catalog(root)
  stopifnot(all(vapply(catalog$Romans, function(entry) entry$status == "suggested", logical(1))),
    identical(catalog$Isaiah, isaiah), identical(read_homepage(root), homepage),
    length(approved_entries(catalog, "Romans")) == 0L, selector(root) == "UNAVAILABLE")
}))
check("A prepared batch cannot smuggle approvals or copied text fields", fixture(function(root) {
  original <- load_catalog(root)
  candidate <- candidates[[1]]; candidate$status <- "approved"
  fails(prepare_book("Romans", list(candidate), root))
  candidate <- candidates[[1]]; candidate$text <- "NOT SCRIPTURE: prohibited test field"
  fails(prepare_book("Romans", list(candidate), root))
  stopifnot(identical(load_catalog(root), original))
}))
check("Duplicate references are rejected across every review status", fixture(function(root) {
  prepare_book("Romans", candidates, root)
  original <- load_catalog(root)
  fails(append_passage("Romans", "Romans 8:38\u201339", "Different context", root = root))
  review_passage("Romans", "Romans 8:38-39", "rejected", root = root)
  fails(append_passage("Romans", "Romans 8:38-39", "Different context", root = root))
  stopifnot(length(load_catalog(root)$Romans) == length(original$Romans))
}))
check("Invalid import batches do not partially overwrite the collection", fixture(function(root) {
  original <- load_catalog(root)
  fails(prepare_book("Romans", c(candidates, candidates), root))
  stopifnot(identical(load_catalog(root), original))
}))
check("Approving requires explicit confirmation and preserves notes", fixture(function(root) {
  prepare_book("Romans", candidates, root)
  fails(review_passage("Romans", "Romans 8:38-39", "approved", root = root))
  stopifnot(selector(root) == "UNAVAILABLE")
  review_passage("Romans", "Romans 8:38\u201339", "approved", TRUE, root)
  entry <- load_catalog(root)$Romans[[1]]
  stopifnot(entry$status == "approved", entry$approval_source == "user-confirmed",
    nzchar(entry$reviewed_at), identical(entry$context, candidates[[1]]$context),
    identical(entry$theme, candidates[[1]]$theme), selector(root) == "Romans 8:38-39")
}))
check("Rejecting an approved reference removes it from selection without deleting notes", fixture(function(root) {
  prepare_book("Romans", candidates, root)
  review_passage("Romans", "Romans 8:38-39", "approved", TRUE, root)
  review_passage("Romans", "Romans 8:38-39", "rejected", root = root)
  stopifnot(selector(root) == "UNAVAILABLE", length(load_catalog(root)$Romans) == 2L,
    identical(load_catalog(root)$Romans[[1]]$context, candidates[[1]]$context))
}))
check("Append defaults to suggested and never overwrites old entries", fixture(function(root) {
  prepare_book("Romans", candidates, root)
  old <- load_catalog(root)$Romans
  append_passage("Romans", "Romans 15:13", "Additional reference-only context", "Hope", root = root)
  catalog <- load_catalog(root)
  stopifnot(identical(catalog$Romans[1:2], old), catalog$Romans[[3]]$status == "suggested",
    selector(root) == "UNAVAILABLE")
}))
check("Explicitly approved append stores the theme and review audit", fixture(function(root) {
  append_passage("Romans", "Romans 8:38-39", "Reference-only context", "God's inseparable love", TRUE, root)
  entry <- load_catalog(root)$Romans[[1]]
  stopifnot(entry$status == "approved", entry$theme == "God's inseparable love",
    selector(root) == "Romans 8:38-39")
}))
check("Switch refuses an unapproved book and changes only the metadata when ready", fixture(function(root) {
  before <- read_homepage(root)
  fails(switch_book("Romans", root))
  prepare_book("Romans", candidates, root)
  fails(switch_book("Romans", root))
  stopifnot(identical(read_homepage(root), before))
  review_passage("Romans", "Romans 8:38-39", "approved", TRUE, root)
  switch_book("Romans", root)
  after <- read_homepage(root)
  stopifnot(reading_book(after) == "Romans", identical(
    sub('current-bible-book: "Isaiah"', 'current-bible-book: "Romans"', before, fixed = TRUE), after),
    length(load_catalog(root)$Isaiah) > 0L)
}))
check("Approved rotation cycles before repeating and handles appended approvals predictably", fixture(function(root) {
  prepare_book("Romans", candidates, root)
  for (entry in candidates) review_passage("Romans", entry$reference, "approved", TRUE, root)
  first <- selector(root, "2026-11-10")
  second <- selector(root, "2026-11-11")
  stopifnot(first != second, selector(root, "2026-11-12") == first)
  append_passage("Romans", "Romans 15:13", "Reference-only context", confirmed = TRUE, root = root)
  dates <- as.character(as.Date("2026-11-10") + 0:2)
  selected <- vapply(dates, function(day) selector(root, day), character(1))
  stopifnot(length(unique(selected)) == 3L, selector(root, "2026-11-13") == selected[1])
}))
check("Missing or fabricated approval fields cannot activate a reference", fixture(function(root) {
  prepare_book("Romans", candidates, root)
  catalog <- load_catalog(root)
  catalog$Romans[[1]]$status <- "approved"
  fails(validate_catalog(catalog))
  # Test the Python publication boundary even if someone hand-edits around the R CLI.
  jsonlite::write_json(catalog, file.path(root, "data/curated-passages.json"), auto_unbox = TRUE)
  stopifnot(selector(root) == "UNAVAILABLE")
}))

old_sha <- strrep("a", 40); new_sha <- strrep("b", 40)
mail_catalog <- load_catalog()
mail_catalog$Romans <- lapply(candidates, function(entry) { entry$status <- "suggested"; entry })
mail_catalog$Romans[[2]]$status <- "rejected"
reader <- function(sha, path, root) {
  if (path == "index.qmd") return(paste0('---\ncurrent-bible-book: "', if (sha == old_sha) "Isaiah" else "Romans", '"\n---\n'))
  as.character(jsonlite::toJSON(mail_catalog, auto_unbox = TRUE))
}
check("Email draft includes the finished-book question and unapproved candidate notes", {
  notification <- reading_notification(old_sha, new_sha, reader = reader)
  stopifnot(notification$previous == "Isaiah", notification$current == "Romans",
    grepl("Would you like to add any new passage references from Isaiah", notification$body, fixed = TRUE),
    grepl("[SUGGESTED] Romans 8:38-39", notification$body, fixed = TRUE),
    grepl(candidates[[1]]$context, notification$body, fixed = TRUE),
    !grepl("Romans 12:9-11", notification$body, fixed = TRUE))
})
check("Unchanged book and initial publication never send a transition email", {
  same_reader <- function(sha, path, root) reader(old_sha, path, root)
  stopifnot(is.null(reading_notification(old_sha, new_sha, reader = same_reader)),
    is.null(reading_notification(strrep("0", 40), new_sha, reader = reader)))
})
check("SMTP uses the environment recipient, authenticated TLS, and quiet diagnostics", {
  notification <- reading_notification(old_sha, new_sha, reader = reader)
  captured <- NULL
  fake_transport <- function(...) captured <<- list(...)
  send_reading_email(notification, "recipient@example.invalid", "TEST-ONLY-PASSWORD", fake_transport)
  stopifnot(captured$mail_rcpt == "recipient@example.invalid", captured$verbose == FALSE,
    captured$smtp_server == "smtps://smtp.gmail.com:465", captured$use_ssl == "force",
    captured$ssl_verifypeer, captured$ssl_verifyhost == 2L, !captured$followlocation,
    !grepl("TEST-ONLY-PASSWORD", captured$message, fixed = TRUE),
    grepl("Content-Transfer-Encoding: base64", captured$message, fixed = TRUE))
  encoded <- strsplit(captured$message, "\r\n\r\n", fixed = TRUE)[[1]][2]
  decoded <- rawToChar(jsonlite::base64_dec(gsub("[\r\n]", "", encoded)))
  stopifnot(identical(decoded, notification$body))
})
check("SMTP missing credentials and errors never expose passwords", {
  notification <- reading_notification(old_sha, new_sha, reader = reader)
  fails(send_reading_email(notification, "", "", function(...) stop("should not call")))
  fails(send_reading_email(notification, "recipient@example.invalid\r\nBcc: attacker@example.com", "test", function(...) stop("should not call")))
  error <- tryCatch(send_reading_email(notification, "recipient@example.invalid", "TEST-ONLY-PASSWORD",
    function(...) stop("TEST-ONLY-PASSWORD")), error = conditionMessage)
  stopifnot(!grepl("TEST-ONLY-PASSWORD", error, fixed = TRUE))
})
check("Git revision input cannot inject a shell command", {
  fails(git_revision_file("not-a-sha; command", "index.qmd"))
})
check("Successful-publication lookup is scoped to main and fails safely", {
  captured <- NULL
  fake <- function(command, args, ...) { captured <<- c(command, args); old_sha }
  stopifnot(previous_successful_revision("kyle-chun1/KyleVerse", fake) == old_sha,
    "status=success" %in% captured, "branch=main" %in% captured)
  fails(previous_successful_revision("kyle-chun1/KyleVerse", function(...) structure(character(), status = 1L)))
  stopifnot(previous_successful_revision("kyle-chun1/KyleVerse", function(...) character()) == "")
})
check("Missing or injected recipients block transport without fallback", {
  notification <- reading_notification(old_sha, new_sha, reader = reader)
  called <- FALSE
  transport <- function(...) called <<- TRUE
  for (recipient in c("", "invalid", "recipient@example.invalid\r\nBcc: other@example.invalid"))
    fails(send_reading_email(notification, "sender@example.invalid", "TEST-ONLY-PASSWORD", transport, recipient))
  stopifnot(!called)
})
check("Environment recipient is used in SMTP envelope and message headers", {
  Sys.setenv(KYLEVERSE_NOTIFICATION_EMAIL = "other@example.invalid")
  captured <- NULL
  send_reading_email(reading_notification(old_sha, new_sha, reader = reader),
    "sender@example.invalid", "TEST-ONLY-PASSWORD", function(...) captured <<- list(...))
  stopifnot(captured$mail_rcpt == "other@example.invalid",
    grepl("To: other@example.invalid", captured$message, fixed = TRUE))
  Sys.setenv(KYLEVERSE_NOTIFICATION_EMAIL = "recipient@example.invalid")
})
check("CLI errors and preceding warnings cannot disclose exception contents", {
  marker <- "PRIVATE-NOTE-AND-CREDENTIAL-TEST-MARKER"
  output <- capture.output({
    status <- safe_cli(function() { warning(marker); stop(marker) }, "Safe failure message.")
  }, type = "message")
  stopifnot(status == 1L, identical(output, "Safe failure message."),
    !any(grepl(marker, output, fixed = TRUE)))
  output <- capture.output({
    status <- safe_cli(function() jsonlite::fromJSON(paste0("{", marker)), "Safe parsing failure.")
  }, type = "message")
  stopifnot(status == 1L, identical(output, "Safe parsing failure."))
  stopifnot(safe_cli(function() invisible(NULL), "Unused failure.") == 0L)
})
cat(count, "curation and notification checks passed. No email was sent.\n")
