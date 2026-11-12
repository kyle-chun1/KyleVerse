# KyleVerse

Use R and R packages for new tools and scripts wherever practical. Keep the
existing tested ESV retrieval/verification adapter and Quarto filter in place
unless a migration is explicitly requested. Never generate, copy into the
catalog, paraphrase, or repair Scripture text; published text comes only from
Crossway's official ESV API.

## Personally curated Scripture

Read `docs/verse-of-the-day.md` and inspect the requested book in
`data/curated-passages.json` before curation work. Use
`Rscript scripts/curation.R show "BOOK"` to see its review status and notes.

When asked to prepare a book (for example, "Help me prepare a curated passage
list for Romans"):

1. Suggest approximately 10–15 meaningful references from that book, each limited
   to 1–3 whole verses in one chapter. Explain speaker, audience, historical
   context, conditions, and why the thought stands alone when relevant. Clearly
   label these as editorial suggestions, not Scripture or personal approvals.
2. Inspect existing entries first. Do not duplicate or overwrite them. Keep new
   draft references/context/optional theme in a temporary JSON array and import
   with `Rscript scripts/curation.R prepare "BOOK" /path/to/draft.json`. All imports
   become `suggested`; imports cannot carry approval fields. If fewer new suitable
   passages remain, explain rather than padding the list with duplicates.
3. Present the suggestions for review. Do not approve, switch the current book,
   send email, commit, push, or publish merely because candidates were generated.
   Prepare one requested book at a time; never auto-populate all books.

Approve only specific references explicitly approved by the user after review.
Use `approve ... --confirm-reviewed`. A request such as "Add Romans 8:38–39 to
my approved collection. Theme: God's inseparable love" explicitly authorizes
that reference; it does not approve other suggestions. Use `append` for a new
reference, or `approve` for an existing suggestion; preserve existing context
and notes. Add the requested theme to the existing entry without erasing notes.
Without explicit approval, append as `suggested`. Never label a model suggestion
as personally reviewed. Rejecting a reference changes its status; retain it and
its notes instead of deleting the collection.

Use `switch "BOOK"` only when the user asks to start that book. The command
requires an approved collection and updates only `current-bible-book` in
`index.qmd`; the homepage display uses that same field. The existing active
Isaiah list is retained with `existing-active-collection` provenance, not a claim
of a newly completed personal review.

Email notifications process a durable Git-history journal independently of
publication, never during preparation or local testing. Never print credentials or invoke `reading_email.R --send` as a
test. Use its default dry-run mode or a mocked transport. SMTP setup is documented
in the curation guide. Do not approve passages based on an email reply unless
the user actually gives that instruction in the active conversation.

Run the R curation checks, existing Python ESV tests, Quarto render, and existing
output verification for relevant changes. Keep secrets out of code and logs.
