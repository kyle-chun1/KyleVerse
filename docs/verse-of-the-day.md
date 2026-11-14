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

New R tools require `jsonlite`; email additionally uses `curl`. Install the
tested versions with R 4.6.2:

```sh
Rscript scripts/install_dependencies.R
```

All four workflows use R **4.6.2** and the public Posit CRAN snapshot
`https://packagemanager.posit.co/cran/2026-11-12`, which provides `jsonlite`
**2.0.0** and `curl` **8.1.0**. The shared installer checks the R version and
installed package versions, uses source packages consistently, and never falls
back to a moving repository. Source installation requires a C compiler and
libcurl development headers. Each Ubuntu workflow explicitly installs
`libcurl4-openssl-dev` and `pkg-config` before the shared R dependency installer;
the runner's curl command or runtime library alone does not provide the headers.
PR validation and publication retain Python **3.12** and Quarto **1.11.9**.
Python uses only the standard library and system timezone data; no pip packages
or dependency lockfiles are needed.

To update dependencies, first verify the chosen dated snapshot's package index
and package downloads. Update the snapshot and R version in the installer and
the same R pin in all four workflows; update these documented versions too.
Install into a clean library with the selected R release, run
`Rscript scripts/validate.R`, and check workflow syntax before review. Keep
Python and Quarto versions aligned between PR validation, publication, and local
release checks. Review dependency updates separately from site-content changes.
The runner image, action major tags, system libraries, and Python patch releases
can still change; no generated-site or dependency caches are introduced.

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

Book names are validated by both R and Python against the single ordered list
in `data/bible-books.json`. Use exact spelling and capitalization, including
`Psalms`, `Song of Solomon`, and spaces in numbered names such as `1 Samuel`.
Abbreviations, misspellings, and unsupported names are rejected even if added
as catalog keys. Do not reorder the shared list: its order determines the
ESV API’s numeric book IDs. The existing singular `Psalm` reference alias is
still accepted within a passage when the selected book is `Psalms`. Canonical
name checks do not replace independent verification of the API response.

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

## Journaled new-book email

Reading notifications run in their own **Reading-book notifications** workflow,
independently of website publishing. It runs on `main` pushes, manual dispatch,
and a daily check at 06:17 UTC. The Scripture publishing schedule is unchanged.
Only the notification workflow calls the normal email sender; publication no
longer sends mail. The isolated one-time test remains unchanged.

The source of events is committed `index.qmd` history, not successful Actions
runs or the current book pair alone. `data/notification-origin.json` pins the
existing commit from which tracking begins. Do not edit that boundary after
activation: the state branch checks it for consistency. Earlier notification
history is unknown and is not automatically replayed.

Each main-line commit is checked in order from the durable cursor. A transition
is identified by its commit SHA and parent SHA. Thus `Isaiah → Romans → John`
produces two events even if no deployment happened between commits; `A → B → A`
also produces two, even though the endpoints match. Commit each reading change
if each should receive an email: uncommitted changes, squashed-away intermediate
states, and lost Git history cannot be recovered or invented. Retain full Git
history. The workflow checks out the exact triggering revision; older runs do
not move a newer cursor backward.

### Durable storage and concurrency

The dedicated `notification-state` branch holds only `journal.json`, outside
the website and main branch. It records a discovery cursor, event commit IDs,
statuses, workflow attempt IDs, timestamps, and review reason codes. It stores
no recipient, credentials, Scripture, contextual notes, or message bodies.
Book names and candidate notes for email are read from the event’s Git revision.
Collections and personal approval decisions are not modified.

The branch uses atomic non-force ref updates. Every proposed state commit has
the expected state head as its sole parent; a stale competing commit cannot
fast-forward the branch. A distinct GitHub run ID/attempt is persisted in the
claim before SMTP, so two concurrent runs cannot both claim a pending event.
GitHub workflow concurrency also serializes normal runs, but the journal claim
is the actual duplicate-send safeguard. Lost or rejected claim acknowledgments
prevent SMTP. A later run can discover new events without resending old ones.

States and their meaning:

- `pending`: no SMTP attempt; configuration/preflight failures leave it pending.
- `sending`: a durable claim exists; the process may still be running or may
  have stopped before/during/after SMTP. Never automatically retry it.
- `smtp_accepted`: the sender returned a positive SMTP result; **inbox delivery
  remains unconfirmed**. No retry on workflow rerun.
- `uncertain`: SMTP raised an error or did not return positive acceptance.
  Gmail may still have accepted it. Held for manual review, not automatic retry.
- `manual_review`: the event’s historical notification data could not be safely
  interpreted. No invented event or message is sent.

If finalizing an SMTP result encounters a concurrent state update, only the
state update is retried (at most three times), never SMTP. If recording still
fails, the durable `sending` claim remains held. Missing credentials are checked
with an inert transport before claiming; no test mail is sent by this preflight.

Unreadable metadata, missing/divergent history, and discontinuous parent chains
are held in the journal’s `review` record. A merge is allowed only when the
first-parent book, merge result, every newly reachable side-branch commit, and
their parent boundaries all have the same valid `current-bible-book`. Traversal
includes nested branches and requires full Git history. Matching endpoints alone
are insufficient: a side branch that changes books and then reverts stays held.
Book-changing or unverifiable merges require manual reconciliation; no transition
is invented. Keep reading changes as separate linear main commits when practical.
Discovery stops at the last verified commit and sending pauses for history review.
Existing holds are never automatically cleared. Already uncertain attempts remain
visible while later reliably established transitions can still be processed.

### Activation after reviewing and publishing this implementation

No remote state branch is created by local tests or validation. After approving
and pushing the implementation:

1. Keep existing Actions secrets `GMAIL_SMTP_USER`, `GMAIL_SMTP_APP_PASSWORD`,
   and `KYLEVERSE_NOTIFICATION_EMAIL`. No new secrets or packages are required.
   The sender uses certificate-verified Gmail SMTPS with diagnostics disabled.
2. Allow the notification job’s `contents: write` permission to create/update
   `notification-state`. The publishing job retains its existing Pages rights;
   it no longer needs `actions: read` for notification-run history.
3. Run **Reading-book notifications → Run workflow** on **main**, entering
   **INITIALIZE NOTIFICATION JOURNAL** in the optional initialization field.
   Review the pinned origin before this first activation. This initializes the
   journal and can send any verified pending transitions since that origin.
4. Protect the state branch from deletion, force pushes, and unrelated edits,
   while permitting normal notification-bot fast-forward updates. It is source
   control metadata, not a Pages deployment branch. Its history is public if
   the repository is public, so keep personal data out of manual edits.

Normal scheduled/push runs will **not recreate a missing journal**. A missing
branch may mean state was lost, so they fail closed and require operator review.
Do not use initialization to recover a previously used deleted branch: restore
its last state instead, or receipts would be lost and old events could replay.

### Manual review and delivery limits

Check Actions failures and `notification-state:journal.json`. An accepted SMTP
response is not proof of inbox delivery. For `sending`/`uncertain`, inspect the
mailbox and workflow timing before any separately approved resolution; do not
blindly reset records to pending. If inbox delivery cannot be established, a
retry risks a duplicate and must be an explicit human decision. The journal has
no automatic expiry/reclaim mechanism for attempts. Do not reset the origin,
rewrite the cursor, or delete events as a shortcut. Review/reconcile ambiguous
history against actual commits before clearing a history hold. Schema validation
prevents falsely labeling automated records as confirmed inbox delivery.

A crash after claiming can leave zero emails sent; an ACK lost after acceptance
can leave an email delivered but unresolved. Exactly-once delivery cannot be
guaranteed over Gmail SMTP. This design favors durable unresolved records over
silent loss or automatic duplicates. First activation does not certify unknown
old deliveries. Candidate-only edits and unchanged reading books create no new
transition emails. Replying to an email does not approve Scripture or edit files.

The previous two-revision preview CLI remains a dry run: set
`READING_PREVIOUS_SHA`/`READING_CURRENT_SHA` and run `Rscript scripts/reading_email.R`
without `--send`. Local checks use mocked GitHub/SMTP only:
`Rscript tests/test_notifications.R` or the complete `Rscript scripts/validate.R`.

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

Pull requests targeting `main` run the same command in the **Validate pull
request** workflow with read-only permissions and no repository secrets.
All 12 stages run, including Quarto rendering, links, and verification of the
safe unavailable card on a fresh checkout. The check does not fetch Scripture,
publish, send email, or restore generated-site caches.

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
  permissions for `contents: write` and `pages: write`. Branch rules must allow
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

The R command-line tools suppress warning details and replace exceptions with
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

## Notification failure categories

The normal notification CLI logs a fixed allowlisted category instead of raw
exceptions. `HISTORY_REVIEW` means inspect the journal's existing review record;
`HISTORY_UNAVAILABLE` means Git history could not be read. Journal failures use
`JOURNAL_MISSING`, `JOURNAL_INVALID`, `JOURNAL_ORIGIN_MISMATCH`,
`JOURNAL_ACCESS_DENIED`, or `JOURNAL_REQUEST_FAILED`. Other categories are
`CONFIGURATION_INVALID`, `STATE_CONFLICT`, `EVENT_REVIEW`,
`SMTP_PREFLIGHT_FAILED`, `JOURNAL_FINALIZATION_FAILED`, and `DELIVERY_REVIEW`.
Unexpected errors or unrecognized categories log only `UNEXPECTED`. Messages,
warnings, response bodies, addresses, credentials, and email bodies from caught
exceptions are not printed. Tests use private-data markers to verify this.
`DELIVERY_REVIEW` does not mean inbox delivery succeeded; inspect held attempts
without resending. The one-time email test and other CLI error handling are unchanged.

## Proposed reconciliation of the harmless PR #1 merge

This is a maintenance procedure for separate review, not an automatic recovery
command. Do not use journal initialization to clear this hold. First publish the
reviewed merge-handling code, use a trusted full-history checkout containing
`df0c139206eb3daabdc8354a260a11ad0ce075cf`, and ensure no notification job is
running. Perform maintenance under the same `kyleverse-reading-notifications`
concurrency group (or temporarily pause notification runs). Any pause is a
separately approved operational action. Use the existing `GH_TOKEN` with
`contents: write`; no Gmail secrets or SMTP calls are needed.

Prepare and inspect the following **in memory only**. The expected state head
is the one inspected during the incident; any intervening change must stop this
procedure and be reviewed again. Do not replace it blindly with the newest SHA.

```r
source("scripts/reading_email.R") # Defines functions; does not send mail.
merge <- "df0c139206eb3daabdc8354a260a11ad0ce075cf"
origin <- jsonlite::read_json("data/notification-origin.json")$baseline_sha
store <- github_notification_store(origin, repo = "kyle-chun1/KyleVerse")
before <- store$load() # initialize defaults to FALSE
stopifnot(
  before$head == "d9a1f33486298338d3e5c1e00064c47a2d33b540",
  before$state$origin == "f373e13b8e86f6f7b34330b670cf0b8c260a43a4",
  before$state$cursor == "fbdcc285b247b5cffa9f6baf91e0b163b65f08d5",
  identical(before$state$review, list(
    reason = "merge_or_discontinuous_history", commit = merge)),
  length(before$state$events) == 0L)
candidate <- before$state
candidate["review"] <- list(NULL) # Retain the required JSON null field locally.
candidate <- journal_reading_events(candidate, merge)
validate_notification_state(candidate)
stopifnot(is.null(candidate$review), candidate$cursor == merge,
  identical(candidate$events, before$state$events),
  identical(candidate$origin, before$state$origin),
  identical(candidate$version, before$state$version))
```

Review that only `cursor` and `review` differ. The verified side commits
`4ae4a68` and `77b2975`, the first parent, and the merge all retain Isaiah.
After separate approval of the actual write, in the same maintenance session:

```r
saved <- store$save(before, candidate) # Atomic non-force update; never calls SMTP.
if (is.null(saved)) stop("Journal changed; stop and re-review.")
after <- store$load()
stopifnot(identical(after$state, candidate), after$head == saved$head)
```

This appends a state commit while retaining the previous hold in branch history;
it preserves the origin and all event records and creates no notification event.
A conflict or lost API acknowledgment requires reading the actual state before
any further action, not initialization, force-pushing, or blind retry. Keep the
previous journal commit SHA as the audit record. Resume normal scheduling only
after verification. No SMTP retry or notification workflow rerun is part of this
procedure; a later scheduled run can continue from the reconciled merge.
