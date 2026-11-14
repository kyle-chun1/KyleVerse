# Durable journal: Git history -> pending -> sending -> smtp_accepted / uncertain.
# Loaded by reading_email.R; no network calls or filesystem writes at load time.
NOTIFICATION_FAILURE_CATEGORIES <- c("CONFIGURATION_INVALID", "JOURNAL_MISSING",
  "JOURNAL_INVALID", "JOURNAL_ORIGIN_MISMATCH", "JOURNAL_ACCESS_DENIED",
  "JOURNAL_REQUEST_FAILED", "HISTORY_UNAVAILABLE", "HISTORY_REVIEW",
  "STATE_CONFLICT", "EVENT_REVIEW", "SMTP_PREFLIGHT_FAILED",
  "JOURNAL_FINALIZATION_FAILED", "DELIVERY_REVIEW", "UNEXPECTED")

notification_error <- function(category) {
  if (!scalar_text(category) || !category %in% NOTIFICATION_FAILURE_CATEGORIES) category <- "UNEXPECTED"
  category <- NOTIFICATION_FAILURE_CATEGORIES[match(category, NOTIFICATION_FAILURE_CATEGORIES)]
  stop(structure(list(message = category, call = NULL, category = category),
    class = c("notification_error", "error", "condition")))
}

notification_cli <- function(action) {
  tryCatch(withCallingHandlers({ action(); 0L },
    warning = function(warning) invokeRestart("muffleWarning")), error = function(error) {
    category <- if (inherits(error, "notification_error")) error$category else "UNEXPECTED"
    if (!scalar_text(category) || !category %in% NOTIFICATION_FAILURE_CATEGORIES) category <- "UNEXPECTED"
    category <- NOTIFICATION_FAILURE_CATEGORIES[match(category, NOTIFICATION_FAILURE_CATEGORIES)]
    message("Reading notification failed [", category, "]. Sensitive details suppressed.")
    1L
  })
}

notification_time <- function() format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
new_notification_state <- function(origin) list(version = 1L, origin = origin,
  cursor = origin, events = list(), review = NULL)

validate_notification_state <- function(state) {
  if (!is.list(state) || !identical(sort(names(state)), sort(c("version", "origin", "cursor", "events", "review"))) ||
      !isTRUE(state$version == 1L) || !valid_sha(state$origin) || !valid_sha(state$cursor) || !is.list(state$events) || !is.null(names(state$events)))
    notification_error("JOURNAL_INVALID")
  if (!is.null(state$review) && (!is.list(state$review) ||
      !identical(sort(names(state$review)), c("commit", "reason")) || !valid_sha(state$review$commit) ||
      !state$review$reason %in% c("unavailable_history", "divergent_or_missing_history",
        "merge_or_discontinuous_history", "invalid_reading_metadata", "incomplete_history")))
    notification_error("JOURNAL_INVALID")
  ids <- character()
  for (event in state$events) {
    if (!is.list(event) || any(!names(event) %in% c("id", "previous_sha", "status", "attempt", "updated_at", "delivery", "reason")) ||
        !valid_sha(event$id) || !valid_sha(event$previous_sha) || event$id %in% ids ||
        !scalar_text(event$status) || !event$status %in% c("pending", "sending", "smtp_accepted", "uncertain", "manual_review") ||
        !identical(event$delivery, "unconfirmed") ||
        (event$status %in% c("sending", "smtp_accepted", "uncertain") && !scalar_text(event$attempt)))
      notification_error("JOURNAL_INVALID")
    ids <- c(ids, event$id)
  }
  invisible(state)
}

notification_git <- function(args, root = PROJECT_ROOT, status_only = FALSE) {
  result <- suppressWarnings(system2("git", c("-C", shQuote(root), shQuote(args)),
    stdout = if (status_only) FALSE else TRUE, stderr = FALSE))
  if (status_only) return(result)
  if (!is.null(attr(result, "status"))) notification_error("HISTORY_UNAVAILABLE")
  result
}

reading_history <- function(cursor, target, root = PROJECT_ROOT, git = notification_git) {
  if (!valid_sha(cursor) || !valid_sha(target)) notification_error("HISTORY_UNAVAILABLE")
  if (cursor == target) return(list(kind = "current", commits = list()))
  ancestor <- function(a, b) identical(as.integer(git(c("merge-base", "--is-ancestor", a, b), root, TRUE)), 0L)
  if (ancestor(target, cursor)) return(list(kind = "stale", commits = list()))
  if (!ancestor(cursor, target)) return(list(kind = "review", reason = "divergent_or_missing_history", commits = list()))
  lines <- git(c("rev-list", "--first-parent", "--reverse", "--parents", paste0(cursor, "..", target)), root)
  parse_commits <- function(lines) lapply(lines, function(line) {
    parts <- strsplit(trimws(line), " ", fixed = TRUE)[[1]]
    if (length(parts) < 2L || !all(vapply(parts, valid_sha, logical(1)))) notification_error("HISTORY_UNAVAILABLE")
    list(sha = parts[1], parents = parts[-1])
  })
  commits <- parse_commits(lines)
  for (i in seq_along(commits)) {
    commit <- commits[[i]]
    if (length(commit$parents) > 1L) {
      if (!identical(git(c("rev-parse", "--is-shallow-repository"), root), "false"))
        notification_error("HISTORY_UNAVAILABLE")
      # Include the merge and every newly reachable side-branch commit, not just
      # its tip. Parent boundaries also reveal changes hidden by later reverts.
      commits[[i]]$introduced <- parse_commits(git(c("rev-list", "--topo-order", "--parents",
        commit$sha, "--not", commit$parents[1]), root))
    }
  }
  list(kind = "forward", commits = commits)
}

unchanged_reading_merge <- function(commit, root = PROJECT_ROOT, reader = git_revision_file) {
  nodes <- commit$introduced
  if (!length(nodes)) return(FALSE)
  ids <- vapply(nodes, `[[`, character(1), "sha")
  if (anyDuplicated(ids) || !commit$sha %in% ids ||
      !identical(nodes[[match(commit$sha, ids)]]$parents, commit$parents)) return(FALSE)
  revisions <- unique(c(commit$parents[1], unlist(lapply(nodes, function(node) c(node$sha, node$parents)))))
  if (!all(vapply(revisions, valid_sha, logical(1)))) return(FALSE)
  books <- vapply(revisions, function(sha) reading_book(reader(sha, "index.qmd", root)), character(1))
  all(books == books[1])
}

journal_reading_events <- function(state, target, root = PROJECT_ROOT,
                                   history = reading_history, reader = git_revision_file) {
  validate_notification_state(state)
  if (!is.null(state$review)) return(state)
  review <- function(reason, commit = target) {
    state$review <- list(reason = reason, commit = commit)
    state
  }
  result <- tryCatch(history(state$cursor, target, root), error = function(error) NULL)
  if (is.null(result)) return(review("unavailable_history"))
  if (result$kind %in% c("current", "stale")) return(state)
  if (result$kind != "forward") return(review("divergent_or_missing_history"))
  for (commit in result$commits) {
    if (!length(commit$parents) || commit$parents[1] != state$cursor)
      return(review("merge_or_discontinuous_history", commit$sha))
    if (length(commit$parents) > 1L) {
      unchanged <- tryCatch(unchanged_reading_merge(commit, root, reader), error = function(error) FALSE)
      if (!isTRUE(unchanged)) return(review("merge_or_discontinuous_history", commit$sha))
      state$cursor <- commit$sha
      next
    }
    books <- tryCatch(c(reading_book(reader(state$cursor, "index.qmd", root)),
                        reading_book(reader(commit$sha, "index.qmd", root))), error = function(error) NULL)
    if (is.null(books)) return(review("invalid_reading_metadata", commit$sha))
    if (books[1] != books[2]) {
      state$events[[length(state$events) + 1L]] <- list(id = commit$sha,
        previous_sha = state$cursor, status = "pending", attempt = NULL,
        updated_at = notification_time(), delivery = "unconfirmed", reason = NULL)
    }
    state$cursor <- commit$sha
  }
  if (state$cursor != target) return(review("incomplete_history"))
  state
}

# Only the state branch is written. Each new commit has the expected head as
# its sole parent. A stale sibling cannot fast-forward the ref (force is false).
github_notification_store <- function(origin, repo = Sys.getenv("GITHUB_REPOSITORY"),
                                       token = Sys.getenv("GH_TOKEN"), request = NULL, initialize = FALSE) {
  if (!valid_sha(origin) || !grepl("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", repo)) notification_error("CONFIGURATION_INVALID")
  if (is.null(request)) {
    if (!scalar_text(token)) notification_error("JOURNAL_ACCESS_DENIED")
    request <- function(method, path, body = NULL) {
      tryCatch({
        handle <- curl::new_handle(customrequest = method, followlocation = FALSE,
          connecttimeout = 10L, timeout = 30L, verbose = FALSE)
        curl::handle_setheaders(handle, Authorization = paste("Bearer", token),
          Accept = "application/vnd.github+json", `User-Agent` = "KyleVerse-notifications", `Content-Type` = "application/json")
        if (!is.null(body)) curl::handle_setopt(handle,
          postfields = as.character(jsonlite::toJSON(body, auto_unbox = TRUE, null = "null")))
        response <- curl::curl_fetch_memory(paste0("https://api.github.com/repos/", repo, "/", path), handle)
        list(status = response$status_code, data = if (response$status_code %in% c(200L, 201L))
          jsonlite::fromJSON(rawToChar(response$content), simplifyVector = FALSE) else NULL)
      }, error = function(error) notification_error("JOURNAL_REQUEST_FAILED"))
    }
  }
  required <- function(method, path, body = NULL) {
    response <- request(method, path, body)
    if (response$status %in% c(401L, 403L)) notification_error("JOURNAL_ACCESS_DENIED")
    if (!response$status %in% c(200L, 201L)) notification_error("JOURNAL_REQUEST_FAILED")
    response$data
  }
  load <- function() {
    response <- request("GET", "git/ref/heads/notification-state")
    if (response$status == 404L) {
      if (!isTRUE(initialize)) notification_error("JOURNAL_MISSING")
      return(list(head = NULL, state = new_notification_state(origin)))
    }
    if (response$status %in% c(401L, 403L)) notification_error("JOURNAL_ACCESS_DENIED")
    if (response$status != 200L) notification_error("JOURNAL_REQUEST_FAILED")
    if (!valid_sha(response$data$object$sha)) notification_error("JOURNAL_INVALID")
    head <- response$data$object$sha
    file <- required("GET", paste0("contents/journal.json?ref=", head))
    state <- tryCatch(jsonlite::fromJSON(rawToChar(jsonlite::base64_dec(file$content)), simplifyVector = FALSE),
      error = function(error) notification_error("JOURNAL_INVALID"))
    validate_notification_state(state)
    if (state$origin != origin) notification_error("JOURNAL_ORIGIN_MISMATCH")
    list(head = head, state = state)
  }
  save <- function(snapshot, state) {
    validate_notification_state(state)
    blob <- required("POST", "git/blobs", list(content = as.character(jsonlite::toJSON(state,
      auto_unbox = TRUE, null = "null")), encoding = "utf-8"))
    tree <- required("POST", "git/trees", list(tree = list(list(path = "journal.json", mode = "100644", type = "blob", sha = blob$sha))))
    commit <- required("POST", "git/commits", list(message = "Update notification journal", tree = tree$sha,
      parents = if (is.null(snapshot$head)) list() else list(snapshot$head)))
    if (!valid_sha(commit$sha)) notification_error("JOURNAL_INVALID")
    response <- if (is.null(snapshot$head)) request("POST", "git/refs",
      list(ref = "refs/heads/notification-state", sha = commit$sha)) else
      request("PATCH", "git/refs/heads/notification-state", list(sha = commit$sha, force = FALSE))
    if (response$status %in% c(401L, 403L)) notification_error("JOURNAL_ACCESS_DENIED")
    if (response$status %in% c(409L, 422L)) return(NULL)
    if (!response$status %in% c(200L, 201L)) notification_error("JOURNAL_REQUEST_FAILED")
    list(head = commit$sha, state = state)
  }
  list(load = load, save = save)
}

process_reading_notifications <- function(store, target, owner, root = PROJECT_ROOT,
                                         history = reading_history, reader = git_revision_file,
                                         deliver = send_reading_email) {
  if (!valid_sha(target) || !scalar_text(owner)) notification_error("CONFIGURATION_INVALID")
  snapshot <- store$load()
  state <- journal_reading_events(snapshot$state, target, root, history, reader)
  # Always establish a durable journal before any SMTP work.
  if (is.null(snapshot$head) || !identical(state, snapshot$state)) snapshot <- store$save(snapshot, state)
  if (is.null(snapshot)) notification_error("STATE_CONFLICT")
  if (!is.null(state$review)) notification_error("HISTORY_REVIEW")
  held <- FALSE
  for (i in seq_along(state$events)) {
    event <- state$events[[i]]
    if (event$status != "pending") {
      if (event$status != "smtp_accepted") held <- TRUE
      next
    }
    notification <- tryCatch(reading_notification(event$previous_sha, event$id, root, reader), error = function(error) NULL)
    if (is.null(notification)) {
      state$events[[i]]$status <- "manual_review"
      state$events[[i]]$reason <- "invalid_event_data"
      if (is.null(store$save(snapshot, state))) notification_error("STATE_CONFLICT")
      notification_error("EVENT_REVIEW")
    }
    # Preflight uses the existing SMTP validator but an explicitly inert transport.
    ready <- tryCatch({ isTRUE(deliver(notification, transport = function(...) invisible(NULL))) }, error = function(error) FALSE)
    if (!ready) notification_error("SMTP_PREFLIGHT_FAILED")
    state$events[[i]]$status <- "sending"
    # Owner is GitHub run ID + run attempt, unique across competing runs.
    state$events[[i]]$attempt <- paste(owner, event$id, sep = ":")
    state$events[[i]]$updated_at <- notification_time()
    snapshot <- store$save(snapshot, state)
    if (is.null(snapshot)) notification_error("STATE_CONFLICT")
    accepted <- tryCatch(isTRUE(deliver(notification)), error = function(error) FALSE)
    # SMTP exceptions are ambiguous, including an ACK lost after Gmail accepted.
    # Save conflicts never cause another SMTP call; a surviving sending claim is held.
    finalized <- FALSE
    for (retry in 1:3) {
      latest <- store$load()
      j <- which(vapply(latest$state$events, function(x) x$id == event$id, logical(1)))
      if (length(j) != 1L || latest$state$events[[j]]$status != "sending" ||
          latest$state$events[[j]]$attempt != state$events[[i]]$attempt) break
      latest$state$events[[j]]$status <- if (accepted) "smtp_accepted" else "uncertain"
      latest$state$events[[j]]$reason <- if (accepted) NULL else "smtp_outcome_unknown"
      latest$state$events[[j]]$updated_at <- notification_time()
      saved <- store$save(latest, latest$state)
      if (!is.null(saved)) { finalized <- TRUE; break }
    }
    if (!finalized) notification_error("JOURNAL_FINALIZATION_FAILED")
    # Reload rather than overwrite another run's newly discovered events.
    snapshot <- store$load(); state <- snapshot$state
    if (!accepted) held <- TRUE
  }
  if (held) notification_error("DELIVERY_REVIEW")
  cat("Notification journal processed. SMTP acceptance is not confirmed inbox delivery.\n")
  invisible(state)
}
