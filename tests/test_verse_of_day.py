"""Offline tests use visibly non-Scripture fixtures, never fabricated Bible text."""

from contextlib import redirect_stdout
from datetime import date, datetime, timedelta, timezone
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import URLError

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import verse_of_day as verse

DAY = date(2026, 11, 10)
# Test arbitrary punctuation/markup preservation without transcribing Scripture.
FIXTURE_TEXT = '\n  NOT SCRIPTURE: test-only <markup> & “punctuation”—[123].\n\t(ESV)'


def response(reference="Isaiah 40:28-29"):
    bounds, _ = verse.reference_range(reference, "Isaiah")
    chapter = bounds[0] // 1000 * 1000
    return {
        "query": reference,
        "canonical": reference,
        "parsed": [bounds],
        "passage_meta": [{
            "canonical": reference,
            "chapter_start": [chapter + 1, chapter + 100],
            "chapter_end": [chapter + 1, chapter + 100],
        }],
        "passages": [FIXTURE_TEXT],
    }


class VerseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "data").mkdir()
        (self.root / "index.qmd").write_text('---\ncurrent-bible-book: "Isaiah"\n---\n')
        self.catalog = {book: [] for book in verse.BOOKS}
        self.catalog["Isaiah"] = [
            {"reference": "Isaiah 25:1", "context": "Reference-only fixture.", "status": "approved", "approval_source": "existing-active-collection"},
            {"reference": "Isaiah 40:28-29", "context": "Reference-only fixture.", "status": "approved", "approval_source": "existing-active-collection"},
        ]
        self.save_catalog()

    def save_catalog(self):
        (self.root / "data/curated-passages.json").write_text(json.dumps(self.catalog))

    def selection(self, day=DAY):
        return verse.selected_reference("Isaiah", day, self.root)

    def test_invalid_book_keys_cannot_bypass_canonical_validation(self):
        for book in ("Isiah", "isaiah", "Romans ", "1Samuel", "Psalm", "Tobit", "", None):
            with self.subTest(book=book):
                with self.assertRaises(verse.Unavailable):
                    verse.require_canonical_book(book)
                with self.assertRaises(verse.Unavailable):
                    verse.reference_range("Isaiah 1:1", book)
        self.catalog["Isiah"] = []
        self.save_catalog()
        with self.assertRaises(verse.Unavailable):
            self.selection()

    def test_actual_homepage_source_of_truth(self):
        self.assertIn(verse.current_book(), verse.BOOKS)
        source = (verse.ROOT / "index.qmd").read_text()
        self.assertIn("{{< meta current-bible-book >}}", source)
        self.assertNotIn("\n" + verse.current_book() + "\n", source)

    def test_deterministic_daily_rotation(self):
        entries = self.catalog["Isaiah"]
        expected = {entry["reference"] for entry in entries}
        actual = {self.selection(DAY + timedelta(days=i)) for i in range(len(entries))}
        self.assertEqual(actual, expected)
        self.assertEqual(self.selection(), self.selection(DAY + timedelta(days=len(entries))))

    def test_each_book_has_an_explicit_reviewable_list(self):
        catalog = json.loads((verse.ROOT / "data/curated-passages.json").read_text())
        self.assertEqual(set(catalog), set(verse.BOOKS))
        for book, entries in catalog.items():
            for entry in entries:
                verse.reference_range(entry["reference"], book)
                self.assertTrue(entry["context"])

    def test_empty_book_never_selects_an_arbitrary_verse(self):
        with self.assertRaises(verse.Unavailable):
            verse.selected_reference("Genesis", DAY, self.root)

    def test_book_change_immediately_invalidates_previous_passage(self):
        ref = self.selection()
        verse.write_state({"available": True, "date": DAY.isoformat(), "book": "Isaiah",
                           "reference": ref, "response": response(ref)}, self.root)
        (self.root / "index.qmd").write_text('---\ncurrent-bible-book: "Genesis"\n---\n')
        self.assertIsNone(verse.verified_state(DAY, self.root))

    def test_no_fuzzy_or_duplicate_homepage_fields(self):
        for field in ["Isiah", "Isaiah\ncurrent-bible-book: Isaiah", ""]:
            with self.subTest(field=field):
                (self.root / "index.qmd").write_text(f"---\ncurrent-bible-book: {field}\n---\n")
                with self.assertRaises(verse.Unavailable):
                    verse.current_book(self.root)

    def test_reference_scope_is_one_to_three_whole_verses(self):
        for ref in ["Isaiah 40", "Isaiah 40:1-4", "Isaiah 40:1-41:1", "Isaiah 40:0", "Isaiah 40:4-2", "John 1:1"]:
            with self.subTest(ref=ref), self.assertRaises(verse.Unavailable):
                verse.reference_range(ref, "Isaiah")

    def test_context_notes_and_unique_references_required(self):
        for entries in [[{"reference": "Isaiah 25:1"}], [self.catalog["Isaiah"][0]] * 2]:
            self.catalog["Isaiah"] = entries
            self.save_catalog()
            with self.assertRaises(verse.Unavailable):
                self.selection()

    def test_valid_response_preserves_every_character(self):
        canonical, text, chapter = verse.validate_response(response(), "Isaiah 40:28-29", "Isaiah")
        self.assertEqual(text, FIXTURE_TEXT)
        self.assertEqual(canonical, "Isaiah 40:28-29")
        self.assertEqual(chapter, "https://www.esv.org/Isaiah%2040/")

    def test_canonical_en_dash_is_displayed_unchanged(self):
        payload = response()
        payload["canonical"] = payload["passage_meta"][0]["canonical"] = "Isaiah 40:28–29"
        self.assertEqual(verse.validate_response(payload, "Isaiah 40:28-29", "Isaiah")[0], "Isaiah 40:28–29")

    def test_invalid_api_responses_are_rejected(self):
        payloads = [None, [], {}, response()]
        payloads[-1]["parsed"] = [[23040028, 23040030]]
        for key, value in [("query", "Isaiah 25:1"), ("canonical", "John 1:1"),
                           ("passages", []), ("passages", [""]), ("passages", ["Unverified text"]),
                           ("passages", [FIXTURE_TEXT, FIXTURE_TEXT]), ("passage_meta", [])]:
            payload = response()
            payload[key] = value
            payloads.append(payload)
        payload = response()
        payload["passage_meta"][0]["chapter_start"] = [23041001, 23041029]
        payloads.append(payload)
        payload = response()
        payload["passage_meta"][0]["canonical"] = "Isaiah 25:1"
        payloads.append(payload)
        for payload in payloads:
            with self.subTest(payload=payload), self.assertRaises(verse.Unavailable):
                verse.validate_response(payload, "Isaiah 40:28-29", "Isaiah")

    def test_html_escaping_is_lossless_not_markdown(self):
        html = verse.card_html(DAY, verse.validate_response(response(), "Isaiah 40:28-29", "Isaiah"))
        parser = verse.VerseParser()
        parser.feed(html)
        self.assertEqual("".join(parser.text), FIXTURE_TEXT)
        self.assertIn("&lt;markup&gt;", html)
        self.assertNotIn("<markup>", html)

    def test_stale_and_changed_rotation_data_are_unavailable(self):
        ref = self.selection()
        state = {"available": True, "date": DAY.isoformat(), "book": "Isaiah", "reference": ref, "response": response(ref)}
        verse.write_state(state, self.root)
        self.assertIsNotNone(verse.verified_state(DAY, self.root))
        self.assertIsNone(verse.verified_state(DAY + timedelta(days=1), self.root))
        state["reference"] = "Isaiah 1:1"
        verse.write_state(state, self.root)
        self.assertIsNone(verse.verified_state(DAY, self.root))

    def test_fetch_success_is_validated_before_storage(self):
        ref = self.selection()
        with patch.dict(os.environ, {"ESV_API_TOKEN": "TEST-ONLY-TOKEN"}), patch.object(verse, "fetch_response", return_value=response(ref)), redirect_stdout(io.StringIO()):
            state = verse.fetch(DAY, self.root)
        self.assertTrue(state["available"])
        self.assertIsNotNone(verse.render(DAY, self.root))
        self.assertNotIn("TEST-ONLY-TOKEN", (self.root / "_verse/state.json").read_text())

    def test_missing_secret_and_network_failures_clear_previous_success(self):
        for error in [None, URLError("TEST-ONLY-TOKEN"), TimeoutError("TEST-ONLY-TOKEN"), ValueError("TEST-ONLY-TOKEN")]:
            ref = self.selection()
            verse.write_state({"available": True, "date": DAY.isoformat(), "book": "Isaiah", "reference": ref, "response": response(ref)}, self.root)
            output = io.StringIO()
            with patch.dict(os.environ, {"ESV_API_TOKEN": "" if error is None else "TEST-ONLY-TOKEN"}), patch.object(verse, "fetch_response", side_effect=error) as fetcher, redirect_stdout(output):
                state = verse.fetch(DAY, self.root)
            self.assertFalse(state["available"])
            if error is None:
                fetcher.assert_not_called()
            self.assertNotIn("TEST-ONLY-TOKEN", output.getvalue())
            self.assertIsNone(verse.render(DAY, self.root))
            self.assertNotIn("NOT SCRIPTURE", (self.root / "_verse/card.html").read_text())

    def test_malformed_cache_never_reaches_the_card(self):
        verse.write_state({}, self.root)
        (self.root / "_verse/state.json").write_text("{broken")
        self.assertIsNone(verse.render(DAY, self.root))
        self.assertIn(verse.UNAVAILABLE, (self.root / "_verse/card.html").read_text())

    def test_redirects_cannot_forward_the_token(self):
        with self.assertRaises(verse.Unavailable):
            verse.NoRedirects().redirect_request(None, None, 302, "", {}, "https://example.com")

    def test_network_request_is_official_bounded_and_server_side(self):
        class Reply:
            status = 200
            def __enter__(self): return self
            def __exit__(self, *args): pass
            def read(self, limit):
                self.limit = limit
                return json.dumps(response()).encode()
        reply = Reply()
        reply.headers = type("Headers", (), {"get_content_type": lambda self: "application/json"})()
        with patch.object(verse, "build_opener") as opener:
            opener.return_value.open.return_value = reply
            verse.fetch_response("Isaiah 40:28-29", "TEST-ONLY-TOKEN")
        request = opener.return_value.open.call_args.args[0]
        self.assertTrue(request.full_url.startswith(verse.ENDPOINT + "?"))
        self.assertNotIn("TEST-ONLY-TOKEN", request.full_url)
        self.assertEqual(request.get_header("Authorization"), "Token TEST-ONLY-TOKEN")
        self.assertEqual(reply.limit, 65_537)
        self.assertEqual(opener.return_value.open.call_args.kwargs["timeout"], 20)

    def test_output_verifier_rejects_changed_text_and_reference(self):
        ref = self.selection()
        payload = response(ref)
        verse.write_state({"available": True, "date": DAY.isoformat(), "book": "Isaiah", "reference": ref, "response": payload}, self.root)
        output = self.root / "output"
        output.mkdir()
        (output / "copyright.html").write_text("copyright")
        html = verse.card_html(DAY, verse.validate_response(payload, ref, "Isaiah"))
        with redirect_stdout(io.StringIO()):
            (output / "about.html").write_text(html)
            verse.verify_output(output, DAY, self.root)
        for altered in [html.replace("NOT SCRIPTURE", "CHANGED"), html.replace(ref + " · ESV", "WRONG REFERENCE")]:
            (output / "about.html").write_text(altered)
            with self.assertRaises(verse.Unavailable):
                verse.verify_output(output, DAY, self.root)

    def test_psalm_canonical_name_uses_the_same_numeric_book_id(self):
        self.assertEqual(verse.reference_range("Psalm 23:1-3", "Psalms"),
                         verse.reference_range("Psalms 23:1-3", "Psalms"))

    def test_sensitive_response_is_never_saved_or_rendered(self):
        ref = self.selection()
        payload = response(ref)
        payload["passages"] = ["TEST-ONLY-TOKEN (ESV)"]
        output = io.StringIO()
        with patch.dict(os.environ, {"ESV_API_TOKEN": "TEST-ONLY-TOKEN"}), patch.object(verse, "fetch_response", return_value=payload), redirect_stdout(output):
            state = verse.fetch(DAY, self.root)
        self.assertFalse(state["available"])
        self.assertNotIn("TEST-ONLY-TOKEN", output.getvalue())
        self.assertNotIn("TEST-ONLY-TOKEN", (self.root / "_verse/state.json").read_text())

    def test_mismatched_response_is_never_saved_as_success(self):
        with patch.dict(os.environ, {"ESV_API_TOKEN": "TEST-ONLY-TOKEN"}), patch.object(verse, "fetch_response", return_value={}), redirect_stdout(io.StringIO()):
            state = verse.fetch(DAY, self.root)
        self.assertFalse(state["available"])
        self.assertIsNone(verse.render(DAY, self.root))

    def test_new_york_date_at_utc_midnight(self):
        instant = datetime(2026, 11, 10, 2, tzinfo=timezone.utc)
        with patch.object(verse, "datetime") as clock:
            clock.now.return_value = instant.astimezone(verse.TIMEZONE)
            self.assertEqual(verse.today(), date(2026, 11, 9))


if __name__ == "__main__":
    unittest.main()
