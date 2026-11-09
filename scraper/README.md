# Video production lead scraper

Runs every morning via GitHub Actions (`.github/workflows/scrape-jobs.yml`), finds
**video production RFPs**, **cinematographer/videographer** and **director of
photography** postings, and publishes them to:

- `https://robertjordanfinney.github.io/jobs/` – searchable dashboard
- `https://robertjordanfinney.github.io/jobs/feed.xml` – RSS feed (subscribe in any reader / Slack / Feedly)
- optional daily email digest of new postings, with **drafted applications /
  RFP responses attached** (see below)

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

## Application & proposal drafts

For every new posting, Claude opens the posting (and any linked RFP or
solicitation documents), lists **every** submission requirement, and drafts a
response to each from your profile. Each draft is a Markdown file with:

- a fit check (eligibility, location, dealbreakers)
- a submission checklist table (answers, documents, forms, pricing, deadlines)
- a draft response per requirement, in the order and format the posting asks for
- open questions: everything marked `[NEEDS INPUT: ...]` where your profile
  had no answer. Claude is told never to invent credits, gear, insurance,
  references or prices.

Setup:

1. Add a repository secret `ANTHROPIC_API_KEY` (from console.anthropic.com).
2. Fill in `scraper/profile.md`, then paste it into a repository secret named
   `APPLICANT_PROFILE` (this repo is public, so keep rates, insurance and tax
   details in the secret only). Drafting stays off while the template still
   has `<<FILL IN` markers and no secret is set.
3. Set the SMTP secrets above. Drafts arrive as attachments to the daily email.
   They are never committed to the public site.

Options (Settings → Secrets and variables → Actions → **Variables**):

- `MAX_DRAFTS_PER_RUN` (default 15). RFPs are drafted first, then DP, then
  cinematographer roles, newest first.
- `UPLOAD_DRAFTS=true` also saves drafts as a workflow artifact. **Only set
  this on a private repo**: anyone can download artifacts on a public repo.

Cost: drafts use Claude Opus 5.5 with web fetch, roughly $0.10–0.40 per
posting depending on how long the RFP documents are.

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
