# Manual delivery check only: never uses the reading-book notification path.
.script_path <- local({
  sources <- Filter(is.character, lapply(sys.frames(), function(frame) frame$ofile))
  path <- if (length(sources)) tail(sources, 1L)[[1]] else
    gsub("~+~", " ", sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE)[1]), fixed = TRUE)
  normalizePath(path, mustWork = TRUE)
})
source(file.path(dirname(.script_path), "shared.R"), local = TRUE)

TEST_EMAIL_REF <- "refs/tags/kyleverse-email-delivery-test-v1"

test_email_message <- function() list(
  subject = "[TEST ONLY] KyleVerse email delivery check",
  body = paste("This is a one-time KyleVerse email delivery test.",
    "This is not a book-change notification. Your reading book and passage collections were not changed.",
    "No Scripture or personal contextual notes are included in this message.", sep = "\n\n"),
  id = "kyleverse-email-delivery-test-v1")

claim_email_test <- function(repo, sha, runner = system2) {
  if (!grepl("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", repo) || !valid_sha(sha))
    curation_error("Invalid test repository or revision.")
  # Creating a fixed ref is atomic. Existing ref, ambiguous response, or any API
  # failure blocks SMTP. The marker remains even if delivery subsequently fails.
  status <- suppressWarnings(runner("gh", c("api", "--method", "POST",
    shQuote(paste0("repos/", repo, "/git/refs")),
    "--raw-field", shQuote(paste0("ref=", TEST_EMAIL_REF)),
    "--raw-field", shQuote(paste0("sha=", sha)), "--silent"),
    stdout = FALSE, stderr = FALSE))
  if (!identical(as.integer(status), 0L))
    curation_error("The one-time test could not be claimed. No email was attempted; do not automatically retry.")
  invisible(TRUE)
}

run_email_test <- function(send = FALSE, env = Sys.getenv, claim = claim_email_test,
                           deliver = send_reading_email) {
  notification <- test_email_message()
  if (!isTRUE(send)) {
    cat("DRY RUN: one clearly labeled test message; no email or GitHub marker created.\n")
    return(invisible(FALSE))
  }
  if (!identical(env("GITHUB_ACTIONS"), "true") ||
      !identical(env("GITHUB_EVENT_NAME"), "workflow_dispatch") ||
      !identical(env("GITHUB_REF"), "refs/heads/main") ||
      !identical(env("GITHUB_RUN_ATTEMPT"), "1") ||
      !identical(env("EMAIL_TEST_CONFIRMATION"), "SEND ONE TEST EMAIL"))
    curation_error("The test requires an explicitly confirmed first manual run on main.")
  # Reuse existing address/credential/header validation with a no-op transport.
  # No SMTP connection is made during this preflight.
  deliver(notification, transport = function(...) invisible(NULL))
  claim(env("GITHUB_REPOSITORY"), env("GITHUB_SHA"))
  deliver(notification)
  cat("One test email accepted by Gmail. This test is now locked against repeat attempts.\n")
  invisible(TRUE)
}

if (sys.nframe() == 0L) {
  quit(status = safe_cli(function() run_email_test("--send-test" %in% commandArgs(trailingOnly = TRUE)),
    "Email test stopped. Check configuration and the one-time marker. Sensitive details were suppressed; no automatic retries are permitted."))
}
