source("scripts/curation.R")
count <- 0L
check <- function(label, code) { force(code); count <<- count + 1L; cat("PASS:", label, "\n") }
fails <- function(code) stopifnot(tryCatch({ force(code); FALSE }, error = function(error) TRUE))
invalid <- c("Isiah", "isaiah", "Romans ", "1Samuel", "Psalm", "Tobit", "", "Unknown")
check("All canonical books are accepted in R metadata and references", {
  stopifnot(length(BIBLE_BOOKS) == 66L, !anyDuplicated(BIBLE_BOOKS))
  for (book in BIBLE_BOOKS) {
    require_canonical_book(book)
    stopifnot(reading_book(paste0('---\ncurrent-bible-book: "',book,'"\n---\n')) == book)
    normalize_reference(paste0(book," 1:1"), book)
  }
})
check("Misspellings and unsupported names are rejected at every R boundary", {
  catalog <- load_catalog()
  for (book in invalid) {
    fails(require_canonical_book(book))
    fails(reading_book(paste0('---\ncurrent-bible-book: "',book,'"\n---\n')))
    fails(normalize_reference(paste0(book," 1:1"),book))
    key <- if (nzchar(book)) book else "INVALID-EMPTY"
    catalog[[key]] <- list()
    fails(validate_catalog(catalog))
    fails(require_book(catalog,book))
    catalog <- load_catalog()
  }
  fails(require_canonical_book(NULL)); fails(require_canonical_book(c("Isaiah","Romans")))
})
check("R and Python accept and reject the same names and share numeric book order", {
  input <- tempfile(fileext=".json")
  jsonlite::write_json(list(valid=BIBLE_BOOKS,invalid=invalid),input,auto_unbox=FALSE)
  code <- paste0("import sys,json; sys.path.insert(0,sys.argv[1]); import verse_of_day as v; ",
    "d=json.load(open(sys.argv[2])); assert list(v.BOOKS)==d['valid']; ",
    "\nfor i,b in enumerate(d['valid'],1):\n assert v.require_canonical_book(b)==b; assert v.reference_range(b+' 1:1',b)[0][0]==i*1000000+1001",
    "\nfor b in d['invalid']:\n try: v.require_canonical_book(b)\n except v.Unavailable: pass\n else: raise AssertionError('Invalid book accepted')")
  result <- system2(Sys.which("python3"),shQuote(c("-B","-c",code,normalizePath("scripts"),input)),stdout=TRUE,stderr=TRUE)
  unlink(input)
  stopifnot(is.null(attr(result,"status")))
})
check("Switching rejects a fake approved book without changing the homepage", {
  root <- tempfile("book-validation-"); dir.create(file.path(root,"data"),recursive=TRUE)
  file.copy("index.qmd",file.path(root,"index.qmd"))
  catalog <- load_catalog()
  catalog$Isiah <- list(list(reference="Isiah 1:1",context="Reference-only test note",status="approved",approval_source="existing-active-collection"))
  jsonlite::write_json(catalog,file.path(root,"data/curated-passages.json"),auto_unbox=TRUE)
  original <- read_homepage(root)
  fails(switch_book("Isiah",root))
  stopifnot(identical(original,read_homepage(root)))
  unlink(root,recursive=TRUE)
})
cat(count,"shared Bible-book checks passed.\n")
