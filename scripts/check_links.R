# Validate generated local href targets using exact directory-entry casing.
# Base R only; no filesystem case-sensitivity assumptions or network requests.
check_internal_links <- function(output = "_site") {
  if (!dir.exists(output)) stop("Render the website before checking links.", call. = FALSE)
  files <- list.files(output, recursive = TRUE, all.files = TRUE, include.dirs = FALSE)
  pages <- files[grepl("\\.html$", files)]
  if (!length(pages)) stop("No rendered HTML pages found.", call. = FALSE)
  resolve <- function(page, target) {
    path <- if (startsWith(target, "/")) substring(target, 2L) else paste(dirname(page), target, sep = "/")
    parts <- character()
    for (part in strsplit(path, "/", fixed = TRUE)[[1]]) {
      if (part %in% c("", ".")) next
      if (part == "..") {
        if (!length(parts)) return(NA_character_)
        parts <- head(parts, -1L)
      } else parts <- c(parts, part)
    }
    path <- paste(parts, collapse = "/")
    if (!nzchar(path) || endsWith(target, "/"))
      path <- paste0(if (nzchar(path)) paste0(path, "/") else "", "index.html")
    path
  }
  failures <- character()
  for (page in pages) {
    html <- paste(readLines(file.path(output, page), warn = FALSE, encoding = "UTF-8"), collapse = "\n")
    # Quarto emits quoted href attributes; include both quote styles and wrapping.
    attrs <- regmatches(html, gregexpr("\\bhref\\s*=\\s*(\"[^\"]*\"|'[^']*')", html, perl = TRUE, ignore.case = TRUE))[[1]]
    for (attr in attrs) {
      href <- sub("^href\\s*=\\s*", "", attr, perl = TRUE, ignore.case = TRUE)
      href <- substring(href, 2L, nchar(href) - 1L)
      if (!nzchar(href) || startsWith(href, "#") || startsWith(href, "?") ||
          startsWith(href, "//") || grepl("^[A-Za-z][A-Za-z0-9+.-]*:", href)) next
      target <- URLdecode(sub("[?#].*$", "", href))
      if (!nzchar(target)) next
      path <- resolve(page, target)
      if (grepl("\\.qmd$", target, ignore.case = TRUE)) {
        failures <- c(failures, paste(page, "has an unresolved Quarto source link"))
      } else if (is.na(path) || !path %in% files) {
        failures <- c(failures, paste(page, "has a missing or incorrectly cased local target:", path))
      }
    }
  }
  if (length(failures)) stop(paste(unique(failures), collapse = "\n"), call. = FALSE)
  cat(length(pages), "HTML pages passed case-sensitive internal-link validation.\n")
  invisible(TRUE)
}

if (sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly = TRUE)
  check_internal_links(if (length(args)) args[1] else "_site")
}
