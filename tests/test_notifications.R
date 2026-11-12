# Deterministic race interleavings and fake GitHub/SMTP; no remote writes or mail.
source("scripts/reading_email.R")
count <- 0L
check <- function(label, code) { force(code); count <<- count + 1L; cat("PASS:", label, "\n") }
fails <- function(code) stopifnot(tryCatch({ force(code); FALSE }, error = function(error) TRUE))
sha <- function(n) sprintf("%040d", as.integer(n))
clone <- function(x) unserialize(serialize(x, NULL))
catalog <- jsonlite::read_json("data/curated-passages.json")
reader <- function(revision, path, root) {
  if (path == "data/curated-passages.json") return(as.character(jsonlite::toJSON(catalog, auto_unbox = TRUE)))
  book <- c("Isaiah", "Romans", "John", "Isaiah")[[as.integer(revision)]]
  paste0('---\ncurrent-bible-book: "', book, '"\n---\n')
}
history <- function(cursor, target, root) {
  first <- as.integer(cursor); last <- as.integer(target)
  if (first >= last) return(list(kind = if (first == last) "current" else "stale", commits = list()))
  list(kind = "forward", commits = lapply(seq.int(first + 1L, last), function(n) list(sha = sha(n), parents = sha(n - 1L))))
}
memory_store <- function() {
  env <- new.env(); env$version <- 0L; env$head <- NULL; env$state <- new_notification_state(sha(1))
  env$claim_hook <- NULL; env$fail_finish <- FALSE; env$lose_claim_ack <- FALSE
  load <- function() clone(list(head = env$head, state = env$state))
  save <- function(snapshot, state) {
    validate_notification_state(state)
    sending <- any(vapply(state$events, function(e) e$status == "sending", logical(1)))
    if (sending && !is.null(env$claim_hook)) { hook <- env$claim_hook; env$claim_hook <- NULL; hook() }
    if (!identical(snapshot$head, env$head)) return(NULL)
    if (env$fail_finish && any(vapply(state$events, function(e) e$status %in% c("smtp_accepted", "uncertain"), logical(1)))) return(NULL)
    env$version <- env$version + 1L; env$head <- sha(100 + env$version); env$state <- clone(state)
    if (sending && env$lose_claim_ack) stop("simulated lost claim response")
    load()
  }
  list(load = load, save = save, env = env)
}
process <- function(store, target = sha(2), owner = "run-a:1", deliver = function(...) TRUE,
                    history_fn = history, reader_fn = reader) {
  invisible(capture.output(process_reading_notifications(store, target, owner,
    history = history_fn, reader = reader_fn, deliver = deliver)))
}

check("Consecutive commits journal each transition, including a return to the original book", {
  state <- journal_reading_events(new_notification_state(sha(1)), sha(4), history = history, reader = reader)
  stopifnot(length(state$events) == 3L, state$cursor == sha(4),
    identical(vapply(state$events, `[[`, character(1), "id"), vapply(2:4, sha, character(1))))
})
check("Repeated runs do not repeat accepted events", {
  store <- memory_store(); sent <- 0L
  deliver <- function(notification, transport = NULL) { if (is.null(transport)) sent <<- sent + 1L; TRUE }
  process(store, sha(4), deliver = deliver); process(store, sha(4), owner = "run-b:1", deliver = deliver)
  stopifnot(sent == 3L, all(vapply(store$env$state$events, function(e) e$status == "smtp_accepted" && e$delivery == "unconfirmed", logical(1))))
})
check("Concurrent worker wins a claim; stale worker never calls SMTP", {
  store <- memory_store(); sent <- 0L
  deliver <- function(notification, transport = NULL) { if (is.null(transport)) sent <<- sent + 1L; TRUE }
  store$env$claim_hook <- function() process(store, owner = "run-b:1", deliver = deliver)
  fails(process(store, owner = "run-a:1", deliver = deliver))
  stopifnot(sent == 1L, store$env$state$events[[1]]$attempt == paste("run-b:1", sha(2), sep = ":"))
})
check("SMTP exceptions are uncertain, retained, and never automatically retried", {
  store <- memory_store(); attempts <- 0L
  deliver <- function(notification, transport = NULL) {
    if (is.null(transport)) { attempts <<- attempts + 1L; stop("PRIVATE-SMTP-TEST-MARKER") }; TRUE
  }
  fails(process(store, deliver = deliver)); fails(process(store, owner = "run-b:1", deliver = deliver))
  stopifnot(attempts == 1L, store$env$state$events[[1]]$status == "uncertain",
    store$env$state$events[[1]]$delivery == "unconfirmed")
})
check("A non-positive SMTP result is not treated as acceptance", {
  store <- memory_store()
  deliver <- function(notification, transport = NULL) if (is.null(transport)) FALSE else TRUE
  fails(process(store, deliver = deliver))
  stopifnot(store$env$state$events[[1]]$status == "uncertain")
})
check("Missing credentials leave an unattempted event pending", {
  store <- memory_store(); attempts <- 0L
  deliver <- function(...) { attempts <<- attempts + 1L; stop("preflight failure") }
  fails(process(store, deliver = deliver))
  stopifnot(attempts == 1L, store$env$state$events[[1]]$status == "pending", is.null(store$env$state$events[[1]]$attempt))
})
check("Lost claim acknowledgment prevents SMTP and leaves the claim held", {
  store <- memory_store(); store$env$lose_claim_ack <- TRUE; attempts <- 0L
  deliver <- function(notification, transport = NULL) { if (is.null(transport)) attempts <<- attempts + 1L; TRUE }
  fails(process(store, deliver = deliver)); store$env$lose_claim_ack <- FALSE
  fails(process(store, deliver = deliver))
  stopifnot(attempts == 0L, store$env$state$events[[1]]$status == "sending")
})
check("Failure recording SMTP acceptance cannot cause another delivery attempt", {
  store <- memory_store(); store$env$fail_finish <- TRUE; attempts <- 0L
  deliver <- function(notification, transport = NULL) { if (is.null(transport)) attempts <<- attempts + 1L; TRUE }
  fails(process(store, deliver = deliver)); store$env$fail_finish <- FALSE
  fails(process(store, deliver = deliver))
  stopifnot(attempts == 1L, store$env$state$events[[1]]$status == "sending")
})
check("Unknown metadata, merge history, and rewritten history require manual review", {
  for (kind in c("metadata", "merge", "rewrite")) {
    store <- memory_store(); attempts <- 0L
    h <- if (kind == "merge") function(...) list(kind = "forward", commits = list(list(sha = sha(2), parents = c(sha(1), sha(9))))) else
      if (kind == "rewrite") function(...) list(kind = "review", commits = list()) else history
    r <- if (kind == "metadata") function(...) stop("invalid metadata") else reader
    fails(process(store, history_fn = h, reader_fn = r,
      deliver = function(...) { attempts <<- attempts + 1L; TRUE }))
    stopifnot(!is.null(store$env$state$review), attempts == 0L, !length(store$env$state$events))
  }
})
check("Older workflow revisions cannot move the cursor backward", {
  store <- memory_store(); process(store, sha(4)); process(store, sha(2))
  stopifnot(store$env$state$cursor == sha(4), length(store$env$state$events) == 3L)
})
check("A later book change survives an earlier uncertain SMTP outcome", {
  store <- memory_store(); fails(process(store, deliver = function(notification, transport = NULL) {
    if (is.null(transport)) stop("uncertain"); TRUE
  }))
  sent <- 0L
  fails(process(store, sha(3), owner = "run-b:1", deliver = function(notification, transport = NULL) {
    if (is.null(transport)) sent <<- sent + 1L; TRUE
  }))
  stopifnot(sent == 1L, length(store$env$state$events) == 2L,
    store$env$state$events[[1]]$status == "uncertain", store$env$state$events[[2]]$status == "smtp_accepted")
})

# Fake GitHub Git Database API: validates actual adapter endpoints and parent/CAS behavior.
fake_github <- function() {
  db <- new.env(); db$n <- 500L; db$head <- NULL; db$objects <- list(); db$forces <- logical()
  make <- function(value) { db$n <- db$n + 1L; key <- sha(db$n); db$objects[[key]] <- value; key }
  reply <- function(status, data = NULL) list(status = status, data = data)
  request <- function(method, path, body = NULL) {
    if (path == "git/ref/heads/notification-state") return(if (is.null(db$head)) reply(404L) else reply(200L, list(object = list(sha = db$head))))
    if (startsWith(path, "contents/journal.json?ref=")) {
      key <- sub("contents/journal.json?ref=", "", path, fixed = TRUE)
      commit <- db$objects[[key]]; blob <- db$objects[[db$objects[[commit$tree]]]]
      return(reply(200L, list(content = jsonlite::base64_enc(charToRaw(blob)))))
    }
    if (path == "git/blobs") return(reply(201L, list(sha = make(body$content))))
    if (path == "git/trees") {
      stopifnot(length(body$tree) == 1L, body$tree[[1]]$path == "journal.json")
      return(reply(201L, list(sha = make(body$tree[[1]]$sha))))
    }
    if (path == "git/commits") return(reply(201L, list(sha = make(body))))
    if (path == "git/refs") {
      stopifnot(body$ref == "refs/heads/notification-state")
      if (!is.null(db$head)) return(reply(422L))
      db$head <- body$sha; return(reply(201L))
    }
    if (path == "git/refs/heads/notification-state") {
      db$forces <- c(db$forces, body$force)
      commit <- db$objects[[body$sha]]
      if (!identical(body$force, FALSE) || !identical(commit$parents, list(db$head))) return(reply(422L))
      db$head <- body$sha; return(reply(200L))
    }
    stop("Unexpected API operation")
  }
  list(request = request, db = db)
}
check("GitHub adapter creates an isolated journal and rejects stale concurrent writes", {
  api <- fake_github(); store <- github_notification_store(sha(1), "example/example", request = api$request, initialize = TRUE)
  empty <- store$load()
  first <- store$save(empty, empty$state)
  stopifnot(!is.null(first), is.null(store$save(empty, empty$state)))
  a <- store$load(); b <- store$load()
  a$state$events <- journal_reading_events(a$state, sha(2), history = history, reader = reader)$events
  a$state$cursor <- sha(2)
  a$state$events[[1]]$status <- "sending"; a$state$events[[1]]$attempt <- "run-a:1"
  b$state <- a$state; b$state$events[[1]]$attempt <- "run-b:1"
  stopifnot(!is.null(store$save(a, a$state)), is.null(store$save(b, b$state)))
  stopifnot(store$load()$state$events[[1]]$attempt == "run-a:1", all(!api$db$forces))
})
check("Missing state cannot silently initialize or replay email history", {
  api <- fake_github()
  store <- github_notification_store(sha(1), "example/example", request = api$request)
  fails(store$load())
  stopifnot(is.null(api$db$head), !length(api$db$objects))
})
check("History command scans ordered commits and distinguishes stale runs", {
  observed <- list()
  fake <- function(args, root, status_only = FALSE) {
    observed[[length(observed) + 1L]] <<- args
    if (status_only) return(if (identical(args[3], sha(1))) 0L else 1L)
    paste(sha(2), sha(1))
  }
  h <- reading_history(sha(1), sha(2), git = fake)
  stopifnot(h$kind == "forward", h$commits[[1]]$parents == sha(1),
    any(vapply(observed, function(args) "--reverse" %in% args && "--first-parent" %in% args, logical(1))))
})
check("Stored journal rejects private payload fields and confirmed-delivery claims", {
  state <- journal_reading_events(new_notification_state(sha(1)), sha(2), history = history, reader = reader)
  state$events[[1]]$recipient <- "recipient@example.invalid"; fails(validate_notification_state(state))
  state$events[[1]]$recipient <- NULL; state$events[[1]]$delivery <- "confirmed"
  fails(validate_notification_state(state))
})
cat(count, "notification-journal checks passed with mocked GitHub and SMTP only.\n")
