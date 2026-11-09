import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace as NS
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import drafter  # noqa: E402
import scrape  # noqa: E402

LABELS = {"rfp": "Video Production RFP", "dp": "Director of Photography", "cinematographer": "Cinematographer"}


def msg(stop, *texts):
    return NS(stop_reason=stop, content=[NS(type="text", text=t) for t in texts])


class FakeClient:
    """Mimics client.beta.messages.stream(...) as a context manager."""

    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []
        self.beta = NS(messages=NS(stream=self._stream))

    def _stream(self, **kwargs):
        self.calls.append({**kwargs, "messages": list(kwargs["messages"])})
        resp = self.responses.pop(0)
        cm = mock.MagicMock()
        cm.__enter__.return_value.get_final_message.return_value = resp
        return cm


def job(i, cat, posted="2026-11-08"):
    return {"id": f"id{i}", "title": f"Job {i} {cat}", "categories": [cat], "url": f"https://x/{i}",
            "posted": posted, "company": "Org", "summary": "s", "source": "Test"}


class DrafterTests(unittest.TestCase):
    def test_request_shape_and_profile_in_prompt(self):
        c = FakeClient([msg("end_turn", "# Draft")])
        out = drafter.draft_one(c, job(1, "rfp"), "PROFILE TEXT", LABELS)
        self.assertEqual(out, "# Draft")
        call = c.calls[0]
        self.assertEqual(call["model"], "claude-opus-5-5")
        self.assertEqual(call["fallbacks"], "default")
        self.assertEqual({t["name"] for t in call["tools"]}, {"web_fetch", "web_search"})
        blocks = call["messages"][0]["content"]
        self.assertIn("PROFILE TEXT", blocks[0]["text"])
        self.assertIn("https://x/1", blocks[1]["text"])

    def test_resumes_pause_turn(self):
        c = FakeClient([msg("pause_turn"), msg("end_turn", "done")])
        self.assertEqual(drafter.draft_one(c, job(1, "dp"), "p", LABELS), "done")
        self.assertEqual(len(c.calls), 2)
        self.assertEqual(c.calls[1]["messages"][-1]["role"], "assistant")

    def test_refusal_and_empty_return_none(self):
        self.assertIsNone(drafter.draft_one(FakeClient([msg("refusal")]), job(1, "dp"), "p", LABELS))
        self.assertIsNone(drafter.draft_one(FakeClient([msg("end_turn", " ")]), job(1, "dp"), "p", LABELS))

    def test_truncation_is_flagged(self):
        out = drafter.draft_one(FakeClient([msg("max_tokens", "partial")]), job(1, "dp"), "p", LABELS)
        self.assertIn("cut off", out)

    def test_template_profile_disables_drafting(self):
        with mock.patch.dict(os.environ, {"APPLICANT_PROFILE": ""}):
            self.assertIsNone(drafter.load_profile())  # committed template has placeholders
        with mock.patch.dict(os.environ, {"APPLICANT_PROFILE": "Real profile"}):
            self.assertEqual(drafter.load_profile(), "Real profile")

    def test_draft_new_priority_limit_and_files(self):
        jobs = [job(1, "cinematographer"), job(2, "rfp", "2026-11-01"), job(3, "rfp", "2026-11-07"), job(4, "dp")]
        fake = FakeClient([msg("end_turn", f"draft {i}") for i in range(3)])
        env = {"ANTHROPIC_API_KEY": "x", "APPLICANT_PROFILE": "Real", "MAX_DRAFTS_PER_RUN": "3"}
        with tempfile.TemporaryDirectory() as d, mock.patch.dict(os.environ, env), \
                mock.patch("anthropic.Anthropic", return_value=fake):
            done = drafter.draft_new(jobs, LABELS, Path(d))
            self.assertEqual([j["id"] for j, _ in done], ["id3", "id2", "id4"])
            self.assertTrue(all(p.exists() and "Posting: https://x/" in p.read_text() for _, p in done))

    def test_no_key_skips(self):
        with mock.patch.dict(os.environ, {"ANTHROPIC_API_KEY": ""}):
            self.assertEqual(drafter.draft_new([job(1, "dp")], LABELS, Path("/nonexistent")), [])

    def test_email_attaches_drafts(self):
        config = {"categories": {k: {"label": v} for k, v in LABELS.items()}}
        j = job(1, "dp")
        env = {"SMTP_HOST": "h", "SMTP_USER": "u", "SMTP_PASSWORD": "p", "EMAIL_TO": "t@example.com"}
        with tempfile.TemporaryDirectory() as d, mock.patch.dict(os.environ, env), \
                mock.patch("smtplib.SMTP_SSL") as smtp:
            p = Path(d) / "job-1.md"
            p.write_text("# Draft")
            scrape.send_email([j], config, {"id1": p})
            sent = smtp.return_value.__enter__.return_value.send_message.call_args[0][0]
            self.assertIn("1 drafts ready", sent["Subject"])
            self.assertEqual([a.get_filename() for a in sent.iter_attachments()], ["job-1.md"])


if __name__ == "__main__":
    unittest.main()
