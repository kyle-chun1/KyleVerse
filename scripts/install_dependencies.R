# Shared local/CI dependencies; never fall back to a moving repository.
if (getRversion() != "4.6.2") stop("Use the tested R version 4.6.2.", call. = FALSE)
snapshot <- "https://packagemanager.posit.co/cran/2026-11-12"
packages <- c("jsonlite", "curl")
available <- available.packages(repos = snapshot, type = "source")
if (!all(packages %in% rownames(available)))
  stop("Required packages are missing from the dated snapshot.", call. = FALSE)

install.packages(packages, repos = snapshot, type = "source")
if (!all(vapply(packages, requireNamespace, logical(1), quietly = TRUE)))
  stop("Required packages could not be loaded.", call. = FALSE)
versions <- vapply(packages, function(package) as.character(packageVersion(package)), character(1))
if (!identical(unname(versions), unname(available[packages, "Version"])))
  stop("Installed package versions do not match the dated snapshot.", call. = FALSE)
cat("Verified dependencies:", paste(packages, versions, collapse = ", "), "\n")
