#!/usr/bin/env python3
"""Fetch one ESV passage server-side; render only validated, current-day data."""

import argparse
from datetime import date, datetime
from html import escape
from http.client import HTTPException
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import sys
from urllib.error import URLError
from urllib.parse import quote, urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
ENDPOINT = "https://api.esv.org/v3/passage/text/"
TIMEZONE = ZoneInfo("America/New_York")
EPOCH = date(2026, 1, 1)
# Crossway's numeric verse IDs use the traditional 66-book order.
def load_books():
    try:
        books = json.loads((ROOT / "data/bible-books.json").read_text(encoding="utf-8"))
        if (not isinstance(books, list) or len(books) != 66
                or any(not isinstance(book, str) or not book.strip() for book in books)
                or len(set(books)) != 66):
            raise ValueError
        return tuple(books)
    except (OSError, ValueError, TypeError):
        raise RuntimeError("The canonical Bible-book list is missing or invalid.") from None


BOOKS = load_books()
UNAVAILABLE = "Today's passage is unavailable. Please check back later."


class Unavailable(ValueError):
    """A fixed, safe reason for withholding a passage; never contains API text."""


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        # Do not forward Authorization to any redirect destination.
        raise Unavailable("The ESV endpoint redirected the request.")


def today():
    return datetime.now(TIMEZONE).date()


def require_canonical_book(book):
    if not isinstance(book, str) or book not in BOOKS:
        raise Unavailable("Use a canonical book name from data/bible-books.json.")
    return book


def current_book(root=ROOT):
    source = (root / "index.qmd").read_text(encoding="utf-8")
    frontmatter = re.match(r"\A---\s*\n(.*?)\n---\s*\n", source, re.S)
    if not frontmatter:
        raise Unavailable("Homepage metadata is missing.")
    fields = re.findall(r"^current-bible-book:[ \t]*(.*?)[ \t]*$", frontmatter[1], re.M)
    if len(fields) != 1:
        raise Unavailable("Set exactly one current-bible-book field in index.qmd.")
    book = fields[0]
    if book.startswith('"'):
        try:
            book = json.loads(book)
        except ValueError:
            raise Unavailable("The homepage book field is invalid.") from None
    elif book.startswith("'") and book.endswith("'"):
        book = book[1:-1]
    return require_canonical_book(book)


def reference_range(reference, book):
    require_canonical_book(book)
    if not isinstance(reference, str):
        raise Unavailable("A curated reference is invalid.")
    book_pattern = r"(?:Psalm|Psalms)" if book == "Psalms" else re.escape(book)
    match = re.fullmatch(book_pattern + r" ([1-9]\d*):([1-9]\d*)(?:[-–]([1-9]\d*))?", reference)
    if not match:
        raise Unavailable("References must name one chapter and one to three whole verses.")
    chapter, first = int(match[1]), int(match[2])
    last = int(match[3] or match[2])
    if not (1 <= last - first + 1 <= 3 and chapter < 1000 and last < 1000):
        raise Unavailable("References must contain one to three whole verses.")
    prefix = (BOOKS.index(book) + 1) * 1_000_000 + chapter * 1000
    return [prefix + first, prefix + last], chapter


def selected_reference(book, day, root=ROOT):
    require_canonical_book(book)
    catalog = json.loads((root / "data/curated-passages.json").read_text(encoding="utf-8"))
    if not isinstance(catalog, dict):
        raise Unavailable("The curated catalog must be an object keyed by book name.")
    for name in catalog:
        require_canonical_book(name)
    entries = catalog.get(book, [])
    if not isinstance(entries, list) or not entries:
        raise Unavailable("The current book has no curated passages.")
    approved = []
    seen = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise Unavailable("A curated entry is invalid.")
        status = entry.get("status", "suggested")
        if status not in ("suggested", "approved", "rejected"):
            raise Unavailable("A curated approval status is invalid.")
        if status != "approved":
            continue
        if entry.get("approval_source") not in ("user-confirmed", "existing-active-collection"):
            raise Unavailable("An approved entry is missing its approval source.")
        if entry.get("approval_source") == "user-confirmed" and not entry.get("reviewed_at"):
            raise Unavailable("A user-approved entry is missing its review timestamp.")
        if not isinstance(entry.get("context"), str) or not entry["context"].strip():
            raise Unavailable("Each curated passage needs a reference and context note.")
        bounds, _ = reference_range(entry.get("reference"), book)
        identity = tuple(bounds)
        if identity in seen:
            raise Unavailable("The curated list contains duplicate references.")
        seen.add(identity)
        approved.append(entry)
    if not approved:
        raise Unavailable("The current book has no approved curated passages.")
    return approved[(day - EPOCH).days % len(approved)]["reference"]


def validate_response(payload, reference, book):
    expected, chapter = reference_range(reference, book)
    if not isinstance(payload, dict) or payload.get("query") != reference:
        raise Unavailable("The ESV response does not match the requested query.")
    canonical = payload.get("canonical")
    if reference_range(canonical, book)[0] != expected:
        raise Unavailable("The canonical reference does not match the requested verses.")
    if payload.get("parsed") != [expected]:
        raise Unavailable("The API returned a different verse range.")
    passages, metadata = payload.get("passages"), payload.get("passage_meta")
    if not isinstance(passages, list) or len(passages) != 1 or not isinstance(passages[0], str):
        raise Unavailable("The API did not return exactly one text passage.")
    text = passages[0]
    # Keep the entire returned string, including whitespace and the API's ESV notice.
    if not text.strip() or not text.rstrip().endswith("(ESV)") or len(text) > 20_000:
        raise Unavailable("The API passage is empty, oversized, or missing its ESV notice.")
    if any(ord(char) < 32 and char not in "\n\r\t" for char in text):
        raise Unavailable("The passage contains unexpected control characters.")
    if not isinstance(metadata, list) or len(metadata) != 1 or not isinstance(metadata[0], dict):
        raise Unavailable("The API passage metadata is missing.")
    meta = metadata[0]
    if meta.get("canonical") != canonical:
        raise Unavailable("The API canonical references disagree.")
    for key in ("chapter_start", "chapter_end"):
        bounds = meta.get(key)
        if (not isinstance(bounds, list) or len(bounds) != 2
                or any(type(number) is not int for number in bounds)
                or not bounds[0] <= expected[0] <= expected[1] <= bounds[1]
                or bounds[0] // 1000 != expected[0] // 1000
                or bounds[1] // 1000 != expected[1] // 1000):
            raise Unavailable("The API chapter metadata does not match the passage.")
    return canonical, text, f"https://www.esv.org/{quote(f'{book} {chapter}', safe='')}/"


def fetch_response(reference, token):
    params = {
        "q": reference,
        "include-passage-references": "false",
        "include-verse-numbers": "false",
        "include-first-verse-numbers": "false",
        "include-headings": "false",
        "include-footnotes": "false",
        "include-footnote-body": "false",
        "include-short-copyright": "true",
        "include-copyright": "false",
        "include-selahs": "true",
        "line-length": "0",
        "indent-paragraphs": "0",
        "indent-poetry": "false",
        "indent-declares": "0",
    }
    request = Request(ENDPOINT + "?" + urlencode(params), headers={
        "Authorization": "Token " + token,
        "Accept": "application/json",
        "User-Agent": "KyleVerse-VerseOfTheDay/1.0",
    })
    with build_opener(NoRedirects()).open(request, timeout=20) as response:
        if response.status != 200 or response.headers.get_content_type() != "application/json":
            raise Unavailable("Crossway returned an unexpected response.")
        raw = response.read(65_537)
        if len(raw) > 65_536:
            raise Unavailable("Crossway returned an oversized response.")
    return json.loads(raw.decode("utf-8"))


def write_state(state, root=ROOT):
    directory = root / "_verse"
    directory.mkdir(exist_ok=True)
    temporary = directory / "state.tmp"
    temporary.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
    temporary.replace(directory / "state.json")


def fetch(day, root=ROOT):
    # Erase any previous success BEFORE attempting a new request. Never serve stale data on failure.
    state = {"date": day.isoformat(), "available": False}
    write_state(state, root)
    try:
        book = current_book(root)
        reference = selected_reference(book, day, root)
        token = os.environ.get("ESV_API_TOKEN", "").strip()
        if not token:
            raise Unavailable("ESV_API_TOKEN is missing; publishing the unavailable card.")
        payload = fetch_response(reference, token)
        validate_response(payload, reference, book)
        if token in json.dumps(payload, ensure_ascii=False):
            raise Unavailable("The response contains sensitive data; withholding the passage.")
        state.update(available=True, book=book, reference=reference, response=payload)
    except Unavailable as error:
        print(f"Verse of the Day: {error}")
    except (URLError, HTTPException, TimeoutError, OSError, ValueError, TypeError):
        # Never print a response body, request, exception, or token.
        print("Verse of the Day: retrieval or configuration validation failed; publishing the unavailable card.")
    else:
        print(f"Verse of the Day: verified {reference} (ESV) for {day.isoformat()}.")
    write_state(state, root)
    if not state["available"] and os.environ.get("GITHUB_ACTIONS") == "true":
        print("::warning::Verse of the Day is unavailable. Check the secret, curated references, and ESV service.")
    return state


def verified_state(day, root=ROOT):
    try:
        state = json.loads((root / "_verse/state.json").read_text(encoding="utf-8"))
        book = current_book(root)
        reference = selected_reference(book, day, root)
        if (not isinstance(state, dict) or state.get("available") is not True
                or state.get("date") != day.isoformat() or state.get("book") != book
                or state.get("reference") != reference):
            raise Unavailable("No verified passage exists for today's book and date.")
        return validate_response(state.get("response"), reference, book)
    except (OSError, ValueError, TypeError):
        return None


def card_html(day, passage):
    heading = '<span class="verse-accent" aria-hidden="true">❧</span><h2 id="verse-of-the-day">Verse of the Day</h2>'
    if passage is None:
        body = f'<p class="verse-support">{UNAVAILABLE}</p>'
    else:
        canonical, text, chapter_url = passage
        body = (f'<blockquote class="verse-text">{escape(text)}</blockquote>'
                f'<p class="verse-reference">{escape(canonical)} · ESV</p>'
                f'<p class="verse-support"><a href="{escape(chapter_url, quote=True)}">Read the full chapter on ESV.org</a></p>')
    return (f'<div class="verse-card" role="region" aria-labelledby="verse-of-the-day">{heading}'
            f'<p class="verse-date">For <time datetime="{day.isoformat()}">{day.strftime("%B %d, %Y")}</time></p>'
            f'{body}<p class="verse-attribution">Scripture from the <a href="https://www.esv.org/">ESV® Bible</a>, '
            '© 2001 Crossway. <a href="copyright.html">Copyright and permissions</a>.</p></div>')


def render(day, root=ROOT):
    passage = verified_state(day, root)
    directory = root / "_verse"
    directory.mkdir(exist_ok=True)
    # The Lua filter inserts raw HTML after pre-render, avoiding Markdown transformations.
    (directory / "card.html").write_text(card_html(day, passage), encoding="utf-8")
    return passage


class VerseParser(HTMLParser):
    """Extract decoded text from the published blockquote without normalizing it."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.in_verse = False
        self.text = []
        self.count = 0
        self.all_text = []
        self.links = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "blockquote" and "verse-text" in attrs.get("class", "").split():
            self.in_verse = True
            self.count += 1
        if tag == "a":
            self.links.append(attrs.get("href"))

    def handle_endtag(self, tag):
        if tag == "blockquote":
            self.in_verse = False

    def handle_data(self, text):
        self.all_text.append(text)
        if self.in_verse:
            self.text.append(text)


def verify_output(output, day, root=ROOT):
    parser = VerseParser()
    parser.feed((output / "about.html").read_text(encoding="utf-8"))
    passage = verified_state(day, root)
    if passage:
        canonical, text, chapter_url = passage
        if (parser.count != 1 or "".join(parser.text) != text
                or canonical + " · ESV" not in "".join(parser.all_text)
                or chapter_url not in parser.links):
            raise Unavailable("Rendered Scripture or reference differs from the verified API response.")
    elif parser.count or UNAVAILABLE not in "".join(parser.all_text):
        raise Unavailable("The rendered page must show unavailable rather than an unverified passage.")
    if not (output / "copyright.html").is_file():
        raise Unavailable("The ESV copyright page is missing.")
    # The build must not publish retrieval scripts, test fixtures, or the API response cache.
    if any((output / folder).exists() for folder in ("_verse", "scripts", "tests", "data", "docs")):
        raise Unavailable("Private build files were copied into the website output.")
    print("Verse of the Day: rendered HTML matches verified data or the safe unavailable state.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("fetch", "render", "verify-output"))
    parser.add_argument("--output", type=Path, default=ROOT / "_site")
    args = parser.parse_args()
    day = today()
    if args.command == "fetch":
        fetch(day)
    elif args.command == "render":
        render(day)
    else:
        try:
            verify_output(args.output, day)
        except (Unavailable, OSError):
            print("Verse of the Day: output verification failed; do not publish this build.", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
