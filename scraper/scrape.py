"""Daily scraper for video-production RFPs, cinematographer and
director-of-photography postings.

Usage:
    python scraper/scrape.py            # scrape, update jobs/jobs.json + jobs/feed.xml
    python scraper/scrape.py --dry-run  # scrape and print, write nothing

Writes:
    jobs/jobs.json  - every matching posting seen in the last `retention_days`
    jobs/feed.xml   - RSS feed of the newest postings (subscribe in any reader)

    drafts/<date>/  - application / proposal drafts for new postings (needs
                      ANTHROPIC_API_KEY; see drafter.py). Not published.

Optional email digest of new postings when SMTP_HOST, SMTP_USER,
SMTP_PASSWORD and EMAIL_TO are set (SMTP_PORT defaults to 465, EMAIL_FROM to
SMTP_USER). Drafts are attached to the email.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import os
import re
import smtplib
import sys
import urllib.parse
from datetime import date, datetime, timedelta, timezone
from email.message import EmailMessage
from email.utils import format_datetime
from pathlib import Path
from xml.sax.saxutils import escape

import requests

sys.path.insert(0, str(Path(__file__).resolve().parent))
import drafter  # noqa: E402
import sources  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
CONFIG_PATH = Path(__file__).resolve().parent / "config.json"
DATA_PATH = ROOT / "jobs" / "jobs.json"
FEED_PATH = ROOT / "jobs" / "feed.xml"
DRAFTS_DIR = ROOT / "drafts"
SITE_URL = os.environ.get("SITE_URL", "https://robertjordanfinney.github.io/jobs/")

log = logging.getLogger("scraper")

TRACKING_PARAMS = re.compile(r"^(utm_|ref$|refid$|source$|src$|fbclid$|gclid$|trk)", re.I)


# --------------------------------------------------------------------------- #
# matching
# --------------------------------------------------------------------------- #


class Matcher:
    def __init__(self, config: dict):
        self.categories = {
            key: (cat["label"], [re.compile(p, re.I) for p in cat["require_all"]])
            for key, cat in config["categories"].items()
        }
        self.exclude = [re.compile(p, re.I) for p in config.get("exclude", [])]

    def categorize(self, item: dict) -> list[str]:
        text = f"{item.get('title', '')} {item.get('description', '')}"
        if any(p.search(text) for p in self.exclude):
            return []
        cats = []
        for key, (_label, patterns) in self.categories.items():
            if all(p.search(text) for p in patterns):
                cats.append(key)
        # A role in the *title* is a much stronger signal than one buried in a
        # long description (e.g. "...work with our cinematographer..."), so for
        # job categories require the title to match.
        title = item.get("title", "")
        cats = [
            c
            for c in cats
            if c == "rfp" or any(p.search(title) for p in self.categories[c][1])
        ]
        return cats


# --------------------------------------------------------------------------- #
# normalisation / dedupe
# --------------------------------------------------------------------------- #


def normalize_url(url: str) -> str:
    try:
        parts = urllib.parse.urlsplit(url.strip())
    except ValueError:
        return url.strip()
    query = [
        (k, v)
        for k, v in urllib.parse.parse_qsl(parts.query, keep_blank_values=True)
        if not TRACKING_PARAMS.match(k)
    ]
    return urllib.parse.urlunsplit(
        (parts.scheme.lower(), parts.netloc.lower(), parts.path.rstrip("/"), urllib.parse.urlencode(query), "")
    )


def title_key(item: dict) -> str:
    t = re.sub(r"[^a-z0-9]+", " ", item.get("title", "").lower()).strip()
    c = re.sub(r"[^a-z0-9]+", " ", item.get("company", "").lower()).strip()
    return f"{t}|{c}"


def make_id(item: dict) -> str:
    return hashlib.sha1(title_key(item).encode()).hexdigest()[:16]


def process(raw_items: list[dict], matcher: Matcher, config: dict, today: date) -> list[dict]:
    """Filter, categorize and dedupe raw items from all sources."""
    cutoff = (today - timedelta(days=config["max_age_days"])).isoformat()
    seen_urls: set[str] = set()
    by_id: dict[str, dict] = {}
    for raw in raw_items:
        if not raw.get("title") or not raw.get("url"):
            continue
        if raw.get("posted") and raw["posted"] < cutoff:
            continue
        cats = matcher.categorize(raw)
        if not cats:
            continue
        url = normalize_url(raw["url"])
        if url in seen_urls:
            continue
        seen_urls.add(url)
        item = {
            "id": make_id(raw),
            "title": raw["title"],
            "company": raw.get("company", ""),
            "location": raw.get("location", ""),
            "url": raw["url"],
            "source": raw.get("source", ""),
            "categories": cats,
            "posted": raw.get("posted", ""),
            "deadline": raw.get("deadline", ""),
            "summary": raw.get("description", "")[:400],
        }
        if item["id"] in by_id:
            existing = by_id[item["id"]]
            if item["source"] not in existing["source"].split(", "):
                existing["source"] += f", {item['source']}"
            continue
        by_id[item["id"]] = item
    return list(by_id.values())


def merge(existing: list[dict], fresh: list[dict], config: dict, today: date) -> tuple[list[dict], list[dict]]:
    """Merge today's results into the stored list. Returns (all, new)."""
    stored = {j["id"]: j for j in existing}
    new: list[dict] = []
    for item in fresh:
        if item["id"] in stored:
            stored[item["id"]]["last_seen"] = today.isoformat()
            continue
        item["first_seen"] = item["last_seen"] = today.isoformat()
        stored[item["id"]] = item
        new.append(item)
    keep_after = (today - timedelta(days=config["retention_days"])).isoformat()
    kept = [j for j in stored.values() if j.get("last_seen", j.get("first_seen", "")) >= keep_after]
    kept.sort(key=lambda j: (j.get("first_seen", ""), j.get("posted", "")), reverse=True)
    return kept, new


# --------------------------------------------------------------------------- #
# output
# --------------------------------------------------------------------------- #


def write_feed(items: list[dict], config: dict, path: Path) -> None:
    labels = {k: v["label"] for k, v in config["categories"].items()}
    now = format_datetime(datetime.now(timezone.utc))
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<rss version="2.0"><channel>',
        "<title>Video Production RFPs &amp; Camera Jobs</title>",
        f"<link>{escape(SITE_URL)}</link>",
        "<description>Daily scrape of video production RFPs, cinematographer and director of photography postings.</description>",
        f"<lastBuildDate>{now}</lastBuildDate>",
    ]
    for j in items[:150]:
        first = datetime.fromisoformat(j["first_seen"]).replace(tzinfo=timezone.utc)
        cats = "".join(f"<category>{escape(labels.get(c, c))}</category>" for c in j["categories"])
        meta = " · ".join(filter(None, [j.get("company"), j.get("location"), j.get("source")]))
        parts.append(
            "<item>"
            f"<title>{escape(j['title'])}</title>"
            f"<link>{escape(j['url'])}</link>"
            f'<guid isPermaLink="false">{j["id"]}</guid>'
            f"<pubDate>{format_datetime(first)}</pubDate>"
            f"{cats}"
            f"<description>{escape(meta + (' — ' if meta else '') + j.get('summary', ''))}</description>"
            "</item>"
        )
    parts.append("</channel></rss>")
    path.write_text("\n".join(parts) + "\n", encoding="utf-8")


def send_email(new: list[dict], config: dict, drafts: dict[str, Path] | None = None) -> None:
    host, user, pw, to = (os.environ.get(k) for k in ("SMTP_HOST", "SMTP_USER", "SMTP_PASSWORD", "EMAIL_TO"))
    if not (host and user and pw and to):
        log.info("Email digest skipped (SMTP secrets not set)")
        return
    if not new:
        log.info("Email digest skipped (nothing new)")
        return
    drafts = drafts or {}
    labels = {k: v["label"] for k, v in config["categories"].items()}
    lines = [f"{len(new)} new posting(s) found {date.today():%B %d, %Y}.", f"All postings: {SITE_URL}", ""]
    html_rows = []
    for key, label in labels.items():
        group = [j for j in new if key in j["categories"]]
        if not group:
            continue
        lines += [f"== {label} ({len(group)}) =="]
        html_rows.append(f"<h3>{escape(label)} ({len(group)})</h3><ul>")
        for j in group:
            meta = " · ".join(filter(None, [j.get("company"), j.get("location"), j.get("source")]))
            note = f"Draft attached: {drafts[j['id']].name}" if j["id"] in drafts else ""
            lines += [f"- {j['title']}", f"  {meta}", f"  {j['url']}"] + ([f"  {note}"] if note else []) + [""]
            html_rows.append(
                f'<li><a href="{escape(j["url"])}">{escape(j["title"])}</a><br>'
                f'<small>{escape(meta)}</small>'
                + (f'<br><small><b>{escape(note)}</b></small>' if note else "")
                + "</li>"
            )
        html_rows.append("</ul>")

    msg = EmailMessage()
    msg["Subject"] = f"{len(new)} new video production leads" + (
        f", {len(drafts)} drafts ready" if drafts else ""
    )
    msg["From"] = os.environ.get("EMAIL_FROM") or user
    msg["To"] = to
    msg.set_content("\n".join(lines))
    msg.add_alternative(
        f"<p>{len(new)} new posting(s). <a href=\"{escape(SITE_URL)}\">View all</a></p>" + "".join(html_rows),
        subtype="html",
    )
    for path in drafts.values():
        msg.add_attachment(
            path.read_bytes(), maintype="text", subtype="markdown", filename=path.name
        )
    port = int(os.environ.get("SMTP_PORT") or 465)
    try:
        if port == 465:
            with smtplib.SMTP_SSL(host, port, timeout=30) as s:
                s.login(user, pw)
                s.send_message(msg)
        else:
            with smtplib.SMTP(host, port, timeout=30) as s:
                s.starttls()
                s.login(user, pw)
                s.send_message(msg)
        log.info("Emailed digest of %d new postings to %s", len(new), to)
    except Exception as exc:  # noqa: BLE001
        log.error("Email failed: %s", exc)


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #


def run_sources(config: dict) -> list[dict]:
    session = requests.Session()
    session.headers["User-Agent"] = (
        "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/124.0 Safari/537.36 video-jobs-scraper"
    )
    raw: list[dict] = []
    for fn in sources.ALL_SOURCES:
        try:
            got = fn(session, config)
        except Exception as exc:  # noqa: BLE001 - belt and braces
            log.error("%s crashed: %s", fn.__name__, exc)
            got = []
        log.info("%-12s %4d raw items", fn.__name__, len(got))
        raw += got
    return raw


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="print results, write nothing")
    args = ap.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")

    config = json.loads(CONFIG_PATH.read_text())
    today = datetime.now(timezone.utc).date()
    matcher = Matcher(config)

    raw = run_sources(config)
    fresh = process(raw, matcher, config, today)
    log.info("%d matching postings after filtering/dedupe", len(fresh))

    existing = []
    if DATA_PATH.exists():
        existing = json.loads(DATA_PATH.read_text()).get("jobs", [])
    all_jobs, new = merge(existing, fresh, config, today)
    log.info("%d new today, %d total stored", len(new), len(all_jobs))

    if args.dry_run:
        for j in new:
            print(f"[{','.join(j['categories'])}] {j['title']} — {j.get('company')} ({j['source']})\n    {j['url']}")
        return 0

    DATA_PATH.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "updated": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "categories": {k: v["label"] for k, v in config["categories"].items()},
        "jobs": all_jobs,
    }
    DATA_PATH.write_text(json.dumps(payload, indent=1, ensure_ascii=False) + "\n", encoding="utf-8")
    write_feed(all_jobs, config, FEED_PATH)
    labels = {k: v["label"] for k, v in config["categories"].items()}
    drafted = drafter.draft_new(new, labels, DRAFTS_DIR / today.isoformat())
    if drafted and not os.environ.get("SMTP_HOST") and os.environ.get("GITHUB_ACTIONS"):
        log.warning("%d drafts written but no SMTP secrets set, so they won't reach you", len(drafted))
    send_email(new, config, {job["id"]: path for job, path in drafted})
    return 0


if __name__ == "__main__":
    sys.exit(main())
