# Verse of the Day

## Edit the book once

Change `current-bible-book: "Isaiah"` in the YAML at the top of `index.qmd`.
The On my heart card uses `{{< meta current-bible-book >}}`, and the retrieval
script reads that same field. Use the full book names listed in
`data/curated-passages.json` (for example, `Psalms`, `1 Corinthians`).
Do not replace the shortcode with a second hard-coded name.

## Review the passage list

`data/curated-passages.json` has an explicit list for every book. Isaiah starts
with six selections (ten distinct verses); the other books deliberately have
empty lists. A missing/empty list displays unavailable, without an API request.
Add entries only after reviewing them in their full chapter:

```json
{"reference": "Isaiah 40:28-29", "context": "A complete description of the Creator and his care for the weary, in comfort addressed to Israel."}
```

Use whole verses, one chapter, and one to three verses per entry. Keep a context
note explaining the speaker, audience, and why the passage can stand alone.
Avoid applying promises to a different audience, removing conditions, or
isolating pronouns without their referent. These editorial notes are not
Scripture and are not added to the quotation. Only Crossway supplies verse text.
Do not add verse text to the catalog, source pages, or tests.

The deterministic index is `(New York date - 2026-01-01).days % passage_count`.
Consecutive days move through the list in order and repeat after its end;
rebuilding on the same day selects the same passage unless you edit the list.
Ordering or changing the list intentionally changes the rotation. The API's
canonical reference is displayed unchanged (including Psalm/Psalms naming).

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

Local checks:

```sh
python3 -m unittest discover -s tests -v
quarto render
python3 scripts/verse_of_day.py verify-output
```

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
- Allow GitHub Actions, the official checkout/Python/Quarto actions, and workflow
  permissions for `contents: write` and `pages: write`. Branch rules must allow
  Quarto's generated-output updates to `gh-pages`; retain protection on `main`.
- After pushing the reviewed files to `main`, select **Actions → Publish KyleVerse
  → Run workflow** for the first authenticated check. A successful ESV retrieval
  prints only the reference and date. Unavailable retrievals emit a workflow
  warning and still publish the unavailable card; they do not keep a cached verse.
- The schedule runs daily at **06:17 UTC** (**1:17 a.m. EST / 2:17 a.m. EDT**), as
  well as on pushes to `main` and manual runs from `main`. Jobs are serialized.
  The token is passed only to the retrieval step, not Quarto or publishing.
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
