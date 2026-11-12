# Verse of the Day

## Prepare one new book

Ask Codex: **“Help me prepare a curated passage list for Romans.”** Repository
instructions in `AGENTS.md` make Codex inspect the collection first, suggest
approximately 10–15 meaningful references with speaker/audience/context notes,
and import them as **suggested**, never approved. No Scripture text is generated
or stored. Preparing a book does not change your current reading or send email.
Only the requested book is prepared; other collections remain untouched.

All collections remain in `data/curated-passages.json`, keyed by book. Entries
retain `reference` and `context`, with optional `theme`, a `status` of `suggested`,
`approved`, or `rejected`, and approval provenance when applicable. No entry is
deleted when rejected or when you leave a book. The six previously active Isaiah
entries retain `existing-active-collection` provenance; this migration does not
claim a new personal review. Future imports always start unapproved.

New R tools require `jsonlite`; email additionally uses `curl`:

```r
install.packages(c("jsonlite", "curl"))
```

The examples below run from the repository root. The curation and both email
CLIs can also be invoked by absolute script path from another directory,
including paths containing spaces. Repository files resolve relative to the
script; relative candidate-file paths resolve relative to your calling directory.
To import Codex’s reviewable JSON draft:

```sh
Rscript scripts/curation.R prepare Romans /path/to/romans-candidates.json
Rscript scripts/curation.R show Romans
```

A draft is an array of objects with `reference`, `context`, and optional `theme`.
Do not include status, approval metadata, or Scripture text. Use 1–3 whole verses
in one chapter. The importer normalizes reference dashes, rejects malformed or
duplicate ranges (including alternate dash spelling), appends without replacing
existing entries, and validates the full batch before writing. Actual canonical
book/chapter/verse existence remains verified against the ESV API at publication.
The JSON file and `show` output let you inspect and edit every contextual note.

## Approve or reject after reviewing Scripture

Read each passage in its full chapter, checking speaker, audience, conditions,
and surrounding argument. Then explicitly tell Codex which references you
approve, or run the equivalent command yourself:

```sh
Rscript scripts/curation.R approve Romans "Romans 8:38-39" --confirm-reviewed
Rscript scripts/curation.R reject Romans "Romans 12:9-11"
```

Approval requires the explicit confirmation flag and records a review timestamp
and `user-confirmed` provenance. Notes and themes are preserved. Rejection keeps
the reference and notes but excludes it from selection. Rejecting the last
approved passage makes the card unavailable. Missing statuses never count as
approval. Do not toggle approval fields merely to bypass the review step.

## Add a reference later

Ask: **“Add Romans 8:38–39 to my approved collection. Theme: God’s inseparable
love.”** This explicitly approves that named reference, not the whole book.
Codex checks for an existing entry, preserves contextual notes, and adds your
theme. If it is new, the equivalent command is:

```sh
Rscript scripts/curation.R append Romans "Romans 8:38-39" \
  --context "Paul reassures believers in Rome about God’s love in Christ, within his argument about suffering and salvation." \
  --theme "God’s inseparable love" --confirm-reviewed
```

Without `--confirm-reviewed`, append creates a suggestion. If the reference
already exists, approve it instead; duplicates are rejected. Edit/add its theme
in the JSON while preserving existing notes. Collections are retained indefinitely.

## Change the current reading book

Once you have approved references, ask Codex to start the new book, or run:

```sh
Rscript scripts/curation.R switch Romans
```

The command refuses a book without approved references and changes only the
`current-bible-book` field in `index.qmd`. The homepage’s **On my heart** card
uses `{{< meta current-bible-book >}}`, and daily selection reads that same field.
Review and publish normally when ready. The next build uses the new book; no
passages are substituted from another book. If the field is edited by hand to
an empty/unapproved collection, the card safely displays unavailable.

## Daily rotation and checks

Only entries explicitly marked approved with valid provenance can enter the
rotation. The original formula is preserved:
`(New York date - 2026-01-01).days % approved_count`, using approved entries in
catalog order. An unchanged collection cycles through all approved references
before repeating. Suggestions/rejections do not consume rotation positions.
Approving, rejecting, or reordering entries recalculates the modulo immediately
and predictably; this can shift that day’s selection or repeat a recent passage.
There is no manual workflow adjustment or random selection.

```sh
Rscript scripts/validate.R
```

The R checks exercise approval gates and the actual Python selector together.
The existing API-response and rendered-output safeguards remain in place.
Unapproved candidates never reach the API query or the published card. The
Python adapter is retained to preserve the working system; new curation and
notification tools use R rather than duplicating its ESV retrieval code.

## New-book email

After a successful Pages deployment, the workflow compares that publication’s
book with the **last successful publishing run** and sends a reference-only
email to the address configured by `KYLEVERSE_NOTIFICATION_EMAIL` when they differ. It asks whether you want
to add references from the book you just finished and lists the new book’s
non-rejected candidates with status, context, and theme. Unapproved suggestions
are clearly labeled. If no candidates were prepared, it says so; it never
invents or auto-approves any. Normal daily builds and candidate-only edits do not
send emails when the reading book is unchanged.

Configure these **GitHub Actions repository secrets**, in addition to the
existing `ESV_API_TOKEN`:

- `KYLEVERSE_NOTIFICATION_EMAIL`: the destination address (for example, `recipient@example.invalid`).
- `GMAIL_SMTP_USER`: the Gmail account sending the email (can be your own account).
- `GMAIL_SMTP_APP_PASSWORD`: a Gmail app password for that account, **not** its
  normal login password. Google requires 2-Step Verification for app passwords;
  some managed accounts cannot use them. See [Google’s app-password guide](https://support.google.com/accounts/answer/185833).

Delivery uses `curl` over authenticated, certificate-verified SMTPS on Gmail
port 465 with SMTP diagnostics disabled. Credentials are scoped to the email
step, never stored in the catalog, email, published HTML, or command arguments.
No email is sent by the curation commands or local render.

To preview using two existing commit SHAs, set `READING_PREVIOUS_SHA` and
`READING_CURRENT_SHA` in your environment, then run the default **dry run**:

```sh
Rscript scripts/reading_email.R
```

Only `--send` enables delivery; do not use it for local testing. The workflow
uses `actions: read` to find the last successful publication via the existing
GitHub CLI. A missing SMTP secret, history lookup error, or delivery error fails
the email step **after** Pages publication, with a sanitized error. The next
scheduled/manual run retries while the last successful run still has the old
book. Check Actions failures. Initial publication with no known previous book
does not invent a finished book or send a misleading reminder.

SMTP is not an exactly-once queue: rerunning an already successful transition,
or a lost delivery acknowledgment, can produce a duplicate. A stable Message-ID
helps mail clients identify repeats but is not a delivery guarantee. The first
successful run after a change records the new baseline automatically through
GitHub’s run history. Multiple edits before publication produce one reminder
for the final published transition. Replying to the email never auto-approves a
reference or modifies a file; review and explicitly approve with Codex/the CLI.

## Build and verification

1. `python3 scripts/verse_of_day.py fetch` reads `ESV_API_TOKEN` from its process
   environment, makes one HTTPS request to Crossway, and saves the response in
   ignored `_verse/state.json`. No token is stored or logged. Redirects are
   refused so credentials cannot be forwarded to another host. No retries,
   whole-book downloads, or third-party Scripture services are used.
2. `quarto render` runs the Python `render` pre-render command. It revalidates
   the current book, current date, selected reference, numeric verse IDs,
   canonical reference, chapter bounds, single passage, and API ESV notice.
   It writes ignored `_verse/card.html`. Without a current validated response,
   including a normal local build without credentials, it creates an
   unavailable card. It does not reuse yesterday's passage.
3. `scripts/verse-of-day.lua` inserts that card as raw HTML beneath the portrait.
   The exact API text is HTML-escaped, never Markdown-parsed, rewritten,
   normalized, transcribed, or passed to an LLM. The API is asked to omit headings,
   verse numbers, and footnotes, and retains its `(ESV)` copyright marker.
4. `python3 scripts/verse_of_day.py verify-output` compares decoded rendered text
   character-for-character with the response and checks the canonical reference,
   ESV designation, chapter link, copyright page, and build-file exclusions.
   Any mismatch blocks publication. With an alternative output directory, use
   `--output /path/to/rendered/site`.

Local checks use the single entry point: `Rscript scripts/validate.R`.

Offline tests use unmistakable non-Scripture strings solely in temporary test
folders. They test punctuation and HTML escaping without inventing Bible text.
The authenticated Isaiah end-to-end check runs in Actions, where the repository
secret is available. GitHub repository secrets cannot be read back locally.
Never paste the token into a source file, command-line argument, URL, or chat.
If you provide it locally, inject it securely into the process environment.

## GitHub setup after reviewing and pushing

- Keep `main` as the default source branch and `gh-pages` for generated output.
- Under **Settings → Pages**, use **Deploy from a branch**, **gh-pages**, **/(root)**.
  The workflow checks these settings and does not change them automatically.
- Keep `ESV_API_TOKEN` under **Settings → Secrets and variables → Actions →
  Repository secrets**. No personal GitHub token is needed.
- Allow GitHub Actions, the official checkout/Python/R/Quarto actions, and workflow
  permissions for `contents: write`, `pages: write`, and `actions: read`. Branch rules must allow
  Quarto's generated-output updates to `gh-pages`; retain protection on `main`.
- After pushing the reviewed files to `main`, select **Actions → Publish KyleVerse
  → Run workflow** for the first authenticated check. A successful ESV retrieval
  prints only the reference and date. Unavailable retrievals emit a workflow
  warning and still publish the unavailable card; they do not keep a cached verse.
- The schedule runs daily at **06:17 UTC** (**1:17 a.m. EST / 2:17 a.m. EDT**), as
  well as on pushes to `main` and manual runs from `main`. Jobs are serialized.
  The ESV token is passed only to retrieval; Gmail credentials only to the email step.
- The official Quarto setup/publish actions render and update `gh-pages`.
  GitHub does not trigger a branch-based Pages build for a `GITHUB_TOKEN` push,
  so the workflow explicitly requests the Pages build and checks that the
  expected `gh-pages` commit reaches `built`. Failures/timeouts fail the workflow;
  enable GitHub Actions failure notifications. No deployment is run locally.

GitHub may delay or drop scheduled jobs during heavy load. Public-repository
schedules can be disabled after 60 days without activity; re-enable the workflow
if that happens. A static page cannot update if Actions or Pages is unavailable;
the card displays its intended date so an older deployment is identifiable.

## Crossway terms and storage

The copyright page contains Crossway's standard notice, every quotation retains
`(ESV)`, and each card links to ESV.org, the full chapter, and copyright details.
The site must remain non-commercial and comply with Crossway's current terms.

Each run requests only one to three verses. There is no persistent Actions cache
or response artifact; `_verse/` is overwritten and ignored by Git, and excluded
from published resources. Only the current card is shown on the website.
As with existing Quarto publishing, historical generated HTML can remain in
`gh-pages` Git history. The initial catalog contains only ten distinct verses,
well below the storage/display limits and half of Isaiah. When expanding or
replacing the curated lists, account for historical quotations too: never store
more than 500 distinct verses or half of any book (whichever is less), and keep
quoted text below 50% of the work. Do not turn this into a book archive. If future
historical output would exceed the limits, arrange compliant retention or
licensing before expanding the lists.

Official references:

- [ESV API terms and attribution](https://api.esv.org/)
- [Crossway passage/text API](https://api.esv.org/docs/passage-text/)
- [Quarto GitHub Pages publishing](https://quarto.org/docs/publishing/github-pages.html)
- [GitHub schedule limitations](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)
- [GitHub Pages build API](https://docs.github.com/en/rest/pages/pages#request-a-github-pages-build)

Both R command-line tools suppress warning details and replace exceptions with
fixed error messages and a nonzero exit status. Personal notes, parser excerpts,
and credentials are never included in error output. Intentional `show`/dry-run
commands still display contextual notes for local review; dry runs do not print
the configured recipient. Missing or invalid recipient configuration blocks
delivery rather than falling back to a hardcoded address.

## One-time email delivery test (manual only)

After reviewing and approving the implementation, commit/push it to `main` when
ready. No email or remote marker is created by preparing or locally testing it.
The separate **One-time email delivery test** workflow has no push or scheduled
trigger and does not invoke publishing or normal book-change notification logic.
It does not read/change your reading book or passage collection.

1. Verify the existing repository secrets `GMAIL_SMTP_USER`,
   `GMAIL_SMTP_APP_PASSWORD`, and `KYLEVERSE_NOTIFICATION_EMAIL` are configured.
   No new secrets are needed; the recipient cannot be entered as workflow input.
2. Open **Actions → One-time email delivery test → Run workflow**.
3. Select **main** and type **SEND ONE TEST EMAIL** in the confirmation input.
4. Run it once. Look for the subject **[TEST ONLY] KyleVerse email delivery check**
   in the configured recipient's inbox/spam folder. Logs contain only generic
   status messages, never recipient addresses, email bodies, or SMTP diagnostics.

The workflow needs `contents: write` solely to create the fixed marker tag
`kyleverse-email-delivery-test-v1` pointing to an existing commit. Repository tag
rules must permit its creation. This creates no new commit, changes no branch,
and contains no personal information. The marker must be created successfully
before SMTP; the [GitHub create-reference API](https://docs.github.com/en/rest/git/refs#create-a-reference)
rejects a duplicate creation. Serialized workflow runs plus this persistent
atomic claim block repeat sends, including separate manual dispatches. The
script also rejects rerun attempts and requires the exact manual confirmation.

**At most one SMTP attempt, not guaranteed delivery:** there are no send retries.
The marker stays consumed after SMTP failure, cancellation, or a lost delivery
acknowledgment. A claimed marker can therefore result in zero delivered emails.
Do not delete/reset the marker or rerun to try again: inspect the inbox and run
status first, and request a separately reviewed retry if needed. Gmail acceptance
does not itself prove inbox delivery. Routine daily publication and normal
book-change emails do not consult or modify this test marker.

Local safety checks (mocked API and SMTP only):

```sh
Rscript tests/test_email.R
Rscript scripts/test_email.R
```

The second command is a dry run by default. Never pass `--send-test` locally as
a check; sending is permitted only by the guarded, confirmed manual workflow.

## Internal navigation checks

Use lowercase page filenames consistently. Keep Quarto source links such as
`photography.qmd` in the navbar and Markdown; Quarto resolves these to
`photography.html` during rendering when the source filename matches exactly.

After `quarto render`, run `Rscript scripts/check_links.R` (or pass an alternative
output directory as its first argument). This base-R check compares local href
paths with the exact directory-entry names, so it catches casing errors even
on a case-insensitive Mac. It also rejects unresolved `.qmd` links, missing files,
and paths outside the output directory. External URLs and fragment-only links
are skipped; fragment IDs and image `src` attributes are outside its scope.
The publishing workflow runs it before deployment. Regression fixtures can be
checked with `Rscript tests/test_links.R`.

## Validate the whole project locally

Run `Rscript scripts/validate.R` from the repository root. It also works with
an absolute script path from another working directory. Prerequisites are R,
Python 3, Quarto, and the existing R packages `jsonlite` and `curl`; the validator
does not install dependencies automatically.

It validates the catalog, discovers and runs every `tests/test_*.R` suite in a
separate R process, runs the Python Scripture tests, renders the website, checks
generated internal links, and verifies the ESV output using the existing scripts.
The first failure stops the run with a nonzero exit status and the failed step
name. Success is reported only after all checks pass. Subprocess diagnostics are
not printed because they can contain private data. Individual checks remain
available for deliberate local troubleshooting.

No credentials are required: credential environment variables are removed from
child processes and restored in the invoking process afterward. No retrieval,
SMTP delivery, GitHub mutation, or publishing command is run. A local render
uses an already valid current-day response if present, otherwise the existing
unavailable card; passing does not certify live ESV or Gmail connectivity.
Rendering updates only the usual generated `_site`, `_verse`, and Quarto caches.
GitHub Actions workflows are unchanged by this consolidation.

The three R CLIs load `scripts/shared.R` directly for shared catalog validation,
sanitized CLI handling, and SMTP delivery; they no longer source each other’s
command implementations. No new R packages are required.
