"""Job / RFP sources.

Every source is a function that takes (session, config) and returns a list of
raw item dicts with these keys (missing values may be empty strings):

    title, url, company, location, description, posted (ISO date or ""), source

Sources never raise: failures are logged and an empty list is returned, so one
broken site never stops the daily run.
"""

from __future__ import annotations

import html
import logging
import os
import re
import urllib.parse
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime

log = logging.getLogger("scraper")

TIMEOUT = 25


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #

_TAG_RE = re.compile(r"<[^>]+>")
_WS_RE = re.compile(r"\s+")


def clean_text(value: str | None, limit: int = 600) -> str:
    """Strip HTML tags/entities and collapse whitespace."""
    if not value:
        return ""
    text = html.unescape(_TAG_RE.sub(" ", str(value)))
    text = _WS_RE.sub(" ", text).strip()
    return text[:limit]


def to_iso_date(value) -> str:
    """Best-effort conversion of a date-ish value to YYYY-MM-DD."""
    if value in (None, ""):
        return ""
    if isinstance(value, (int, float)):
        try:
            return datetime.fromtimestamp(value, tz=timezone.utc).date().isoformat()
        except (OverflowError, OSError, ValueError):
            return ""
    s = str(value).strip()
    try:
        return parsedate_to_datetime(s).date().isoformat()
    except (TypeError, ValueError, IndexError):
        pass
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).date().isoformat()
    except ValueError:
        pass
    try:
        return datetime.strptime(s, "%m/%d/%Y").date().isoformat()
    except ValueError:
        pass
    m = re.match(r"(\d{4}-\d{2}-\d{2})", s)
    return m.group(1) if m else ""


def _get(session, url, **kwargs):
    resp = session.get(url, timeout=TIMEOUT, **kwargs)
    resp.raise_for_status()
    return resp


def parse_rss(xml_text: str, source: str) -> list[dict]:
    """Parse an RSS 2.0 or Atom document into raw items."""
    items: list[dict] = []
    try:
        root = ET.fromstring(xml_text.encode("utf-8") if isinstance(xml_text, str) else xml_text)
    except ET.ParseError as exc:
        log.warning("%s: could not parse feed (%s)", source, exc)
        return items

    # RSS 2.0
    for it in root.iter("item"):
        src_el = it.find("source")
        items.append(
            {
                "title": clean_text(it.findtext("title"), 300),
                "url": (it.findtext("link") or "").strip(),
                "company": clean_text(src_el.text if src_el is not None else ""),
                "location": "",
                "description": clean_text(it.findtext("description")),
                "posted": to_iso_date(it.findtext("pubDate")),
                "source": source,
            }
        )

    # Atom
    atom = "{http://www.w3.org/2005/Atom}"
    for entry in root.iter(f"{atom}entry"):
        link_el = entry.find(f"{atom}link")
        items.append(
            {
                "title": clean_text(entry.findtext(f"{atom}title"), 300),
                "url": (link_el.get("href") if link_el is not None else "") or "",
                "company": clean_text(entry.findtext(f"{atom}author/{atom}name")),
                "location": "",
                "description": clean_text(
                    entry.findtext(f"{atom}summary") or entry.findtext(f"{atom}content")
                ),
                "posted": to_iso_date(
                    entry.findtext(f"{atom}published") or entry.findtext(f"{atom}updated")
                ),
                "source": source,
            }
        )
    return items


# --------------------------------------------------------------------------- #
# keyless sources: search-engine RSS (best for public RFP notices)
# --------------------------------------------------------------------------- #


def google_news(session, config) -> list[dict]:
    """Google News RSS search. Surfaces RFP notices posted by cities, schools,
    agencies and newspapers' public-notice sections."""
    out: list[dict] = []
    queries = config["search_queries"]["rfp"] + config["search_queries"]["jobs"]
    for q in queries:
        url = "https://news.google.com/rss/search?" + urllib.parse.urlencode(
            {"q": f"{q} when:{config['max_age_days']}d", "hl": "en-US", "gl": "US", "ceid": "US:en"}
        )
        try:
            out += parse_rss(_get(session, url).text, "Google News")
        except Exception as exc:  # noqa: BLE001
            log.warning("Google News query %r failed: %s", q, exc)
    return out


def bing_web(session, config) -> list[dict]:
    """Bing web search RSS. Picks up RFP PDFs/pages on government & school
    procurement portals, plus job pages on smaller boards."""
    out: list[dict] = []
    queries = config["search_queries"]["rfp"] + config["search_queries"]["jobs"]
    for q in queries:
        url = "https://www.bing.com/search?" + urllib.parse.urlencode(
            {"q": q, "format": "rss", "count": "50", "qft": "+filterui:age-lt43200"}
        )
        try:
            out += parse_rss(_get(session, url).text, "Bing")
        except Exception as exc:  # noqa: BLE001
            log.warning("Bing query %r failed: %s", q, exc)
    return out


def extra_rss(session, config) -> list[dict]:
    """User-supplied feeds (e.g. Google Alerts RSS, a job board's RSS)."""
    out: list[dict] = []
    for feed in config.get("extra_rss_feeds", []):
        url = feed["url"] if isinstance(feed, dict) else feed
        name = feed.get("name", "RSS") if isinstance(feed, dict) else urllib.parse.urlparse(url).netloc
        try:
            out += parse_rss(_get(session, url).text, name)
        except Exception as exc:  # noqa: BLE001
            log.warning("Feed %s failed: %s", url, exc)
    return out


# --------------------------------------------------------------------------- #
# keyless sources: public job-board APIs
# --------------------------------------------------------------------------- #


def remotive(session, config) -> list[dict]:
    out: list[dict] = []
    for kw in config["job_board_keywords"]:
        try:
            data = _get(session, "https://remotive.com/api/remote-jobs", params={"search": kw}).json()
        except Exception as exc:  # noqa: BLE001
            log.warning("Remotive %r failed: %s", kw, exc)
            continue
        for j in data.get("jobs", []):
            out.append(
                {
                    "title": clean_text(j.get("title"), 300),
                    "url": j.get("url", ""),
                    "company": clean_text(j.get("company_name")),
                    "location": clean_text(j.get("candidate_required_location")) or "Remote",
                    "description": clean_text(j.get("description")),
                    "posted": to_iso_date(j.get("publication_date")),
                    "source": "Remotive",
                }
            )
    return out


def remoteok(session, config) -> list[dict]:
    try:
        data = _get(session, "https://remoteok.com/api").json()
    except Exception as exc:  # noqa: BLE001
        log.warning("RemoteOK failed: %s", exc)
        return []
    out = []
    for j in data:
        if not isinstance(j, dict) or "position" not in j:
            continue  # first element is a legal notice
        out.append(
            {
                "title": clean_text(j.get("position"), 300),
                "url": j.get("url") or j.get("apply_url", ""),
                "company": clean_text(j.get("company")),
                "location": clean_text(j.get("location")) or "Remote",
                "description": clean_text(j.get("description")),
                "posted": to_iso_date(j.get("date") or j.get("epoch")),
                "source": "RemoteOK",
            }
        )
    return out


def jobicy(session, config) -> list[dict]:
    out: list[dict] = []
    for tag in ("video", "cinematographer", "videographer"):
        try:
            data = _get(session, "https://jobicy.com/api/v2/remote-jobs", params={"count": 50, "tag": tag}).json()
        except Exception as exc:  # noqa: BLE001
            log.warning("Jobicy %r failed: %s", tag, exc)
            continue
        for j in data.get("jobs", []):
            out.append(
                {
                    "title": clean_text(j.get("jobTitle"), 300),
                    "url": j.get("url", ""),
                    "company": clean_text(j.get("companyName")),
                    "location": clean_text(j.get("jobGeo")) or "Remote",
                    "description": clean_text(j.get("jobExcerpt") or j.get("jobDescription")),
                    "posted": to_iso_date(j.get("pubDate")),
                    "source": "Jobicy",
                }
            )
    return out


def arbeitnow(session, config) -> list[dict]:
    out: list[dict] = []
    for page in (1, 2, 3):
        try:
            data = _get(session, "https://www.arbeitnow.com/api/job-board-api", params={"page": page}).json()
        except Exception as exc:  # noqa: BLE001
            log.warning("Arbeitnow page %d failed: %s", page, exc)
            break
        for j in data.get("data", []):
            out.append(
                {
                    "title": clean_text(j.get("title"), 300),
                    "url": j.get("url", ""),
                    "company": clean_text(j.get("company_name")),
                    "location": clean_text(j.get("location")),
                    "description": clean_text(j.get("description")),
                    "posted": to_iso_date(j.get("created_at")),
                    "source": "Arbeitnow",
                }
            )
    return out


# --------------------------------------------------------------------------- #
# optional sources: free API keys, enabled by setting GitHub secrets
# --------------------------------------------------------------------------- #


def sam_gov(session, config) -> list[dict]:
    """U.S. federal contract opportunities (SAM.gov). Needs SAM_API_KEY."""
    key = os.environ.get("SAM_API_KEY")
    if not key:
        log.info("SAM.gov skipped (no SAM_API_KEY)")
        return []
    today = datetime.now(timezone.utc).date()
    start = today - timedelta(days=config["max_age_days"])
    base = {
        "api_key": key,
        "postedFrom": start.strftime("%m/%d/%Y"),
        "postedTo": today.strftime("%m/%d/%Y"),
        "limit": 100,
    }
    searches = [{"title": kw} for kw in config["sam_gov"]["keywords"]]
    searches += [{"ncode": n} for n in config["sam_gov"]["naics"]]
    out: list[dict] = []
    for extra in searches:
        try:
            data = _get(session, "https://api.sam.gov/opportunities/v2/search", params={**base, **extra}).json()
        except Exception as exc:  # noqa: BLE001
            log.warning("SAM.gov %r failed: %s", extra, exc)
            continue
        for o in data.get("opportunitiesData", []) or []:
            place = o.get("placeOfPerformance") or {}
            loc = ", ".join(
                filter(None, [(place.get("city") or {}).get("name"), (place.get("state") or {}).get("code")])
            )
            out.append(
                {
                    # Prefix so federal notices always satisfy the RFP pattern.
                    "title": clean_text(f"{o.get('type', 'Solicitation')}: {o.get('title', '')}", 300),
                    "url": o.get("uiLink", ""),
                    "company": clean_text(o.get("fullParentPathName") or o.get("department")),
                    "location": loc,
                    "description": clean_text(
                        f"Solicitation {o.get('solicitationNumber', '')}. NAICS {o.get('naicsCode', '')}. "
                        f"Responses due {o.get('responseDeadLine') or 'n/a'}."
                    ),
                    "posted": to_iso_date(o.get("postedDate")),
                    "deadline": to_iso_date(o.get("responseDeadLine")),
                    "source": "SAM.gov",
                }
            )
    return out


def usajobs(session, config) -> list[dict]:
    """U.S. federal jobs. Needs USAJOBS_API_KEY and USAJOBS_EMAIL."""
    key, email = os.environ.get("USAJOBS_API_KEY"), os.environ.get("USAJOBS_EMAIL")
    if not (key and email):
        log.info("USAJOBS skipped (no USAJOBS_API_KEY / USAJOBS_EMAIL)")
        return []
    headers = {"Host": "data.usajobs.gov", "User-Agent": email, "Authorization-Key": key}
    out: list[dict] = []
    for kw in config["job_board_keywords"]:
        try:
            data = _get(
                session,
                "https://data.usajobs.gov/api/search",
                params={"Keyword": kw, "ResultsPerPage": 100, "DatePosted": config["max_age_days"]},
                headers=headers,
            ).json()
        except Exception as exc:  # noqa: BLE001
            log.warning("USAJOBS %r failed: %s", kw, exc)
            continue
        for r in data.get("SearchResult", {}).get("SearchResultItems", []):
            d = r.get("MatchedObjectDescriptor", {})
            out.append(
                {
                    "title": clean_text(d.get("PositionTitle"), 300),
                    "url": d.get("PositionURI", ""),
                    "company": clean_text(d.get("OrganizationName")),
                    "location": clean_text(d.get("PositionLocationDisplay")),
                    "description": clean_text((d.get("UserArea", {}).get("Details") or {}).get("JobSummary")),
                    "posted": to_iso_date(d.get("PublicationStartDate")),
                    "deadline": to_iso_date(d.get("ApplicationCloseDate")),
                    "source": "USAJOBS",
                }
            )
    return out


def adzuna(session, config) -> list[dict]:
    """Large aggregator (covers many company career pages and boards).
    Needs ADZUNA_APP_ID and ADZUNA_APP_KEY. ADZUNA_COUNTRY defaults to 'us'."""
    app_id, app_key = os.environ.get("ADZUNA_APP_ID"), os.environ.get("ADZUNA_APP_KEY")
    if not (app_id and app_key):
        log.info("Adzuna skipped (no ADZUNA_APP_ID / ADZUNA_APP_KEY)")
        return []
    country = os.environ.get("ADZUNA_COUNTRY", "us")
    out: list[dict] = []
    for kw in config["job_board_keywords"]:
        try:
            data = _get(
                session,
                f"https://api.adzuna.com/v1/api/jobs/{country}/search/1",
                params={
                    "app_id": app_id,
                    "app_key": app_key,
                    "what_phrase": kw,
                    "results_per_page": 50,
                    "max_days_old": config["max_age_days"],
                    "content-type": "application/json",
                },
            ).json()
        except Exception as exc:  # noqa: BLE001
            log.warning("Adzuna %r failed: %s", kw, exc)
            continue
        for j in data.get("results", []):
            out.append(
                {
                    "title": clean_text(j.get("title"), 300),
                    "url": j.get("redirect_url", ""),
                    "company": clean_text((j.get("company") or {}).get("display_name")),
                    "location": clean_text((j.get("location") or {}).get("display_name")),
                    "description": clean_text(j.get("description")),
                    "posted": to_iso_date(j.get("created")),
                    "source": "Adzuna",
                }
            )
    return out


def jooble(session, config) -> list[dict]:
    """Large aggregator. Needs JOOBLE_API_KEY."""
    key = os.environ.get("JOOBLE_API_KEY")
    if not key:
        log.info("Jooble skipped (no JOOBLE_API_KEY)")
        return []
    out: list[dict] = []
    for kw in config["job_board_keywords"]:
        try:
            resp = session.post(f"https://jooble.org/api/{key}", json={"keywords": kw}, timeout=TIMEOUT)
            resp.raise_for_status()
            data = resp.json()
        except Exception as exc:  # noqa: BLE001
            log.warning("Jooble %r failed: %s", kw, exc)
            continue
        for j in data.get("jobs", []):
            out.append(
                {
                    "title": clean_text(j.get("title"), 300),
                    "url": j.get("link", ""),
                    "company": clean_text(j.get("company")),
                    "location": clean_text(j.get("location")),
                    "description": clean_text(j.get("snippet")),
                    "posted": to_iso_date(j.get("updated")),
                    "source": "Jooble",
                }
            )
    return out


ALL_SOURCES = [
    google_news,
    bing_web,
    extra_rss,
    remotive,
    remoteok,
    jobicy,
    arbeitnow,
    sam_gov,
    usajobs,
    adzuna,
    jooble,
]
