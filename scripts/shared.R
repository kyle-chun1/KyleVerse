# Shared catalog validation, safe CLI handling, and SMTP transport; no CLI side effects.
PROJECT_ROOT <- dirname(dirname(.script_path))

curation_error <- function(message) stop(message, call. = FALSE)

scalar_text <- function(x) is.character(x) && length(x) == 1L && !is.na(x) && nzchar(trimws(x))

BIBLE_BOOKS <- tryCatch(jsonlite::read_json(file.path(PROJECT_ROOT, "data/bible-books.json"), simplifyVector = TRUE),
  error = function(error) curation_error("The canonical Bible-book list is missing or invalid."))
if (!is.character(BIBLE_BOOKS) || !is.null(dim(BIBLE_BOOKS)) || !is.null(names(BIBLE_BOOKS)) ||
    length(BIBLE_BOOKS) != 66L || anyNA(BIBLE_BOOKS) ||
    any(!nzchar(trimws(BIBLE_BOOKS))) || anyDuplicated(BIBLE_BOOKS))
  curation_error("The canonical Bible-book list is missing or invalid.")

require_canonical_book <- function(book) {
  if (!scalar_text(book) || !book %in% BIBLE_BOOKS)
    curation_error("Use a canonical book name from data/bible-books.json.")
  invisible(book)
}

normalize_reference <- function(reference, book) {
  require_canonical_book(book)
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
    require_canonical_book(book)
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

require_book <- function(catalog, book) {
  require_canonical_book(book)
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
  require_canonical_book(value)
  value
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

valid_sha <- function(sha) scalar_text(sha) && grepl("^[a-fA-F0-9]{40}$", sha)

send_reading_email <- function(notification, sender = Sys.getenv("GMAIL_SMTP_USER"),
                               password = Sys.getenv("GMAIL_SMTP_APP_PASSWORD"),
                               transport = curl::send_mail,
                               recipient = Sys.getenv("KYLEVERSE_NOTIFICATION_EMAIL")) {
  if (!scalar_text(sender) || !grepl("^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+$", sender) ||
      grepl("[\r\n]", sender) || !scalar_text(password))
    curation_error("Configure GMAIL_SMTP_USER and GMAIL_SMTP_APP_PASSWORD repository secrets; no email was sent.")
  if (!scalar_text(recipient) || !grepl("^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9.-]+$", recipient) || grepl("[\r\n]", recipient))
    curation_error("Configure a valid KYLEVERSE_NOTIFICATION_EMAIL repository secret; no email was sent.")
  if (grepl("[\r\n]", notification$subject) || grepl("[\r\n]", notification$id))
    curation_error("Invalid email headers; no email was sent.")
  # Base64 protects UTF-8 notes and avoids SMTP line-length/dot-stuffing problems.
  encoded <- jsonlite::base64_enc(charToRaw(enc2utf8(notification$body)))
  encoded <- gsub("[\r\n]", "", encoded)
  starts <- seq.int(1L, nchar(encoded), by = 76L)
  body <- substring(encoded, starts, pmin(starts + 75L, nchar(encoded)))
  message <- paste(c(paste0("From: KyleVerse <", sender, ">"),
    paste0("To: ", recipient), paste0("Subject: ", notification$subject),
    paste0("Date: ", format(Sys.time(), "%a, %d %b %Y %H:%M:%S +0000", tz = "UTC")),
    paste0("Message-ID: <", notification$id, "@kyleverse.local>"),
    "MIME-Version: 1.0", "Content-Type: text/plain; charset=UTF-8",
    "Content-Transfer-Encoding: base64", "", body, ""), collapse = "\r\n")
  # Never print SMTP diagnostics or exception details: they can contain credentials.
  tryCatch(withCallingHandlers({
    invisible(transport(mail_from = sender, mail_rcpt = recipient, message = message,
      smtp_server = "smtps://smtp.gmail.com:465", use_ssl = "force", verbose = FALSE,
      username = sender, password = gsub("[[:space:]]", "", password),
      ssl_verifypeer = TRUE, ssl_verifyhost = 2L, followlocation = FALSE,
      connecttimeout = 10L, timeout = 30L))
  }, warning = function(warning) invokeRestart("muffleWarning")),
  error = function(error) curation_error("Gmail delivery failed. Check the SMTP secrets and Gmail settings; credential details were suppressed."))
  invisible(TRUE)
}
