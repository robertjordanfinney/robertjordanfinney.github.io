# Video production lead scraper

Runs every morning via GitHub Actions (`.github/workflows/scrape-jobs.yml`), finds
**video production RFPs**, **cinematographer/videographer** and **director of
photography** postings, and publishes them to:

- `https://robertjordanfinney.github.io/jobs/` – searchable dashboard
- `https://robertjordanfinney.github.io/jobs/feed.xml` – RSS feed (subscribe in any reader / Slack / Feedly)
- optional daily email digest of new postings

Run it now: GitHub → **Actions → Scrape video production leads → Run workflow**.

## Sources

Works out of the box (no keys):

| Source | What it finds |
| --- | --- |
| Google News RSS search | Public RFP notices (cities, schools, agencies), hiring news |
| Bing web search RSS | RFP pages/PDFs on procurement portals, smaller job boards |
| Remotive, RemoteOK, Jobicy, Arbeitnow | Job-board APIs (mostly remote roles) |
| `extra_rss_feeds` in `config.json` | Any RSS you add (e.g. Google Alerts set to "deliver to RSS feed") |

Turn on more by adding free API keys as repo secrets
(**Settings → Secrets and variables → Actions**):

| Secret(s) | Source | Sign up |
| --- | --- | --- |
| `SAM_API_KEY` | SAM.gov federal contract RFPs (NAICS 512110 + keywords) | sam.gov → Account Details → API key |
| `ADZUNA_APP_ID`, `ADZUNA_APP_KEY` (opt. `ADZUNA_COUNTRY`) | Large US job aggregator — best coverage | developer.adzuna.com |
| `JOOBLE_API_KEY` | Large job aggregator | jooble.org/api/about |
| `USAJOBS_API_KEY`, `USAJOBS_EMAIL` | Federal videographer/camera jobs | developer.usajobs.gov |

Email digest: set `SMTP_HOST`, `SMTP_USER`, `SMTP_PASSWORD`, `EMAIL_TO`
(optional `SMTP_PORT`, default 465, and `EMAIL_FROM`). For Gmail use
`smtp.gmail.com` and an App Password.

## Tuning

Edit `config.json`: search queries, job-board keywords, the regexes that decide
each category, exclusions, and how long postings are kept. For job categories
the role must appear in the posting **title**; RFPs need both a
solicitation term (RFP/RFQ/bid/…) and a video term.

## Local use

```
pip install -r scraper/requirements.txt
python scraper/scrape.py --dry-run   # print what it finds, write nothing
python -m unittest discover -s scraper/tests
```
