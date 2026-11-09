import json
import sys
import tempfile
import unittest
from datetime import date
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import scrape  # noqa: E402
import sources  # noqa: E402

CONFIG = json.loads((Path(__file__).resolve().parent.parent / "config.json").read_text())
TODAY = date(2026, 11, 9)

RSS = """<?xml version="1.0"?><rss version="2.0"><channel>
<item><title>City of Springfield issues RFP for video production services</title>
<link>https://example.gov/rfp/123?utm_source=x</link>
<description>&lt;b&gt;Request for proposals&lt;/b&gt; for promotional video production.</description>
<pubDate>Fri, 06 Nov 2026 10:00:00 GMT</pubDate><source url="https://n.example">Springfield News</source></item>
<item><title>Director of Photography - Indie Feature</title>
<link>https://jobs.example.com/dp-1</link><description>Seeking a DP.</description>
<pubDate>Sat, 07 Nov 2026 10:00:00 GMT</pubDate></item>
<item><title>Marketing Manager</title><link>https://jobs.example.com/mm</link>
<description>Work closely with our videographer.</description></item>
<item><title>Old cinematographer job</title><link>https://jobs.example.com/old</link>
<pubDate>Mon, 01 Jun 2026 10:00:00 GMT</pubDate></item>
<item><title>RFP for IT network upgrade</title><link>https://example.gov/it</link></item>
</channel></rss>"""

ATOM = """<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom">
<entry><title>Videographer needed for corporate events</title>
<link href="https://atom.example/v1"/><updated>2026-11-08T12:00:00Z</updated>
<summary>Freelance videographer.</summary></entry></feed>"""


class ScrapeTests(unittest.TestCase):
    def setUp(self):
        self.matcher = scrape.Matcher(CONFIG)

    def test_parse_rss_and_atom(self):
        items = sources.parse_rss(RSS, "Test")
        self.assertEqual(len(items), 5)
        self.assertEqual(items[0]["posted"], "2026-11-06")
        self.assertEqual(items[0]["company"], "Springfield News")
        self.assertNotIn("<b>", items[0]["description"])
        atom = sources.parse_rss(ATOM, "A")
        self.assertEqual(atom[0]["url"], "https://atom.example/v1")
        self.assertEqual(atom[0]["posted"], "2026-11-08")

    def test_bad_feed_returns_empty(self):
        self.assertEqual(sources.parse_rss("<html>nope", "X"), [])

    def test_process_filters_and_categorizes(self):
        raw = sources.parse_rss(RSS, "Test") + sources.parse_rss(ATOM, "A")
        out = {j["title"]: j["categories"] for j in scrape.process(raw, self.matcher, CONFIG, TODAY)}
        self.assertEqual(out["City of Springfield issues RFP for video production services"], ["rfp"])
        self.assertEqual(out["Director of Photography - Indie Feature"], ["dp"])
        self.assertEqual(out["Videographer needed for corporate events"], ["cinematographer"])
        self.assertNotIn("Marketing Manager", out)  # role only in description
        self.assertNotIn("Old cinematographer job", out)  # too old
        self.assertNotIn("RFP for IT network upgrade", out)  # not video

    def test_dedupe_across_sources(self):
        a = {"title": "Cinematographer", "company": "Acme", "url": "https://a.com/1", "source": "A"}
        b = {"title": "Cinematographer!", "company": "ACME", "url": "https://b.com/1", "source": "B"}
        out = scrape.process([a, b, dict(a)], self.matcher, CONFIG, TODAY)
        self.assertEqual(len(out), 1)
        self.assertEqual(out[0]["source"], "A, B")

    def test_normalize_url_strips_tracking(self):
        self.assertEqual(
            scrape.normalize_url("HTTPS://Ex.com/a/?utm_source=x&id=5#frag"), "https://ex.com/a?id=5"
        )

    def test_merge_tracks_new_and_prunes(self):
        old = {"id": "old", "title": "x", "first_seen": "2026-01-01", "last_seen": "2026-01-01"}
        kept = {"id": "k", "title": "y", "first_seen": "2026-11-01", "last_seen": "2026-11-01"}
        fresh = [{"id": "k", "title": "y"}, {"id": "n", "title": "z"}]
        all_jobs, new = scrape.merge([old, kept], fresh, CONFIG, TODAY)
        self.assertEqual([j["id"] for j in new], ["n"])
        self.assertEqual({j["id"] for j in all_jobs}, {"k", "n"})
        self.assertEqual(next(j for j in all_jobs if j["id"] == "k")["first_seen"], "2026-11-01")

    def test_feed_is_valid_xml(self):
        import xml.etree.ElementTree as ET

        raw = sources.parse_rss(RSS, "Test")
        jobs, _ = scrape.merge([], scrape.process(raw, self.matcher, CONFIG, TODAY), CONFIG, TODAY)
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "feed.xml"
            scrape.write_feed(jobs, CONFIG, p)
            self.assertEqual(len(ET.parse(p).getroot().findall("./channel/item")), len(jobs))

    def test_to_iso_date(self):
        self.assertEqual(sources.to_iso_date("2026-11-08T12:00:00Z"), "2026-11-08")
        self.assertEqual(sources.to_iso_date("11/08/2026"), "2026-11-08")
        self.assertEqual(sources.to_iso_date(1794182400), "2026-11-09")
        self.assertEqual(sources.to_iso_date("garbage"), "")

    def test_sources_never_raise_offline(self):
        class Boom:
            headers = {}
            def get(self, *a, **k):
                raise ConnectionError("offline")
            post = get
        for fn in sources.ALL_SOURCES:
            self.assertEqual(fn(Boom(), CONFIG), [], fn.__name__)


if __name__ == "__main__":
    unittest.main()
