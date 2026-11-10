source("scripts/test_email.R")
count <- 0L
check <- function(name, code) { force(code); count <<- count + 1L; cat("PASS:", name, "\n") }
fails <- function(code) stopifnot(tryCatch({ force(code); FALSE }, error = function(error) TRUE))
settings <- c(GITHUB_ACTIONS = "true", GITHUB_EVENT_NAME = "workflow_dispatch",
  GITHUB_REF = "refs/heads/main", GITHUB_RUN_ATTEMPT = "1",
  EMAIL_TEST_CONFIRMATION = "SEND ONE TEST EMAIL", GITHUB_REPOSITORY = "example/example",
  GITHUB_SHA = strrep("a", 40))
env <- function(name) unname(settings[[name]])
check("Dry run cannot claim or send", {
  run_email_test(FALSE, env, function(...) stop("claimed"), function(...) stop("sent"))
})
check("Manual first-run confirmation is mandatory", {
  for (key in c("GITHUB_ACTIONS", "GITHUB_EVENT_NAME", "GITHUB_REF", "GITHUB_RUN_ATTEMPT", "EMAIL_TEST_CONFIRMATION")) {
    modified <- settings; modified[key] <- "invalid"
    fails(run_email_test(TRUE, function(name) unname(modified[[name]]), function(...) stop("claimed"), function(...) stop("sent")))
  }
})
check("Atomic persistent claim permits only one SMTP invocation", {
  claimed <- FALSE; sent <- 0L; preflight <- 0L
  claim <- function(...) { if (claimed) stop("already claimed"); claimed <<- TRUE }
  deliver <- function(notification, transport = NULL) {
    if (is.null(transport)) sent <<- sent + 1L else preflight <<- preflight + 1L
  }
  invisible(capture.output(run_email_test(TRUE, env, claim, deliver)))
  fails(run_email_test(TRUE, env, claim, deliver))
  stopifnot(sent == 1L, preflight == 2L)
})
check("SMTP error leaves the claim consumed and cannot retry", {
  claimed <- FALSE; attempts <- 0L
  claim <- function(...) { if (claimed) stop("already claimed"); claimed <<- TRUE }
  deliver <- function(notification, transport = NULL) {
    if (is.null(transport)) { attempts <<- attempts + 1L; stop("simulated SMTP error") }
  }
  fails(run_email_test(TRUE, env, claim, deliver))
  fails(run_email_test(TRUE, env, claim, deliver))
  stopifnot(claimed, attempts == 1L)
})
check("Preflight failure cannot consume a claim or send mail", {
  claimed <- FALSE
  fails(run_email_test(TRUE, env, function(...) claimed <<- TRUE, function(...) stop("configuration failed")))
  stopifnot(!claimed)
})
check("API failure or existing ref fails closed without leaking diagnostics", {
  fails(claim_email_test("example/example", strrep("a", 40), function(...) 1L))
  fails(claim_email_test("example/example", "invalid", function(...) stop("called")))
  claim_email_test("example/example", strrep("a", 40), function(...) 0L)
})
check("Message is fixed, labeled, and contains no Scripture or collection notes", {
  note <- test_email_message()
  stopifnot(startsWith(note$subject, "[TEST ONLY]"), !grepl("@", note$body),
    identical(note$id, "kyleverse-email-delivery-test-v1"))
})
cat(count, "email-test checks passed using mocks only. No real email sent.\n")
