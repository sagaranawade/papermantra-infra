# SEO Strategy — PaperMantra & NeelMind

Goal: rank for education and exam-paper keywords in India and globally.

| Domain | App | Role in SEO |
|--------|-----|-------------|
| **neelmind.com** | Next.js (robofume) | **Primary marketing site** — Google indexes this best (SSR + sitemap) |
| **papermantra.com** | React CRA portal | **Product login/portal** — limited indexing; brand + login pages only |

---

## Target keywords (priority)

### High intent (product)
- question paper generator
- AI question paper generator
- automatic question paper generation
- exam paper maker for schools
- coaching institute question bank software
- LaTeX question paper generator
- PaperMantra

### Brand
- NeelMind Technologies
- NeelMind PaperMantra
- neelmind exam software

### Service (NeelMind)
- EdTech solutions India
- custom education software
- AI exam automation

---

## Phase 1 — Technical SEO (implemented in code)

### NeelMind (robofume) — done in repo
- [x] Per-page `metadata` via Next.js App Router
- [x] Dynamic `app/sitemap.js` (all marketing pages + blogs + services)
- [x] Dynamic `app/robots.js`
- [x] Open Graph + Twitter cards
- [x] JSON-LD: Organization, WebSite, SoftwareApplication (PaperMantra), Article (blogs)
- [x] Google Search Console verification file in `public/`
- [x] Removed stale `public/robots.txt` and `public/sitemap.xml`
- [x] Fixed page titles and keyword-rich descriptions
- [x] Redirect `/privacy` → `/privacy-policy`

### PaperMantra (portal) — done in repo
- [x] `public/index.html` — meta, OG, Twitter, JSON-LD
- [x] `SeoHead` component on login/signup routes
- [x] `robots.txt` — allow login/signup, disallow app paths
- [x] `sitemap.xml` — portal + links to NeelMind marketing pages
- [x] `manifest.json` description

### Deploy after merge
```bash
# Tag and deploy both apps
# papermantra → v1.0.17+ (portal SEO)
# robofume → v1.0.12+ (marketing SEO)
```

---

## Phase 2 — Google Search Console (you must do manually)

Do this for **both** domains:

1. Go to [Google Search Console](https://search.google.com/search-console)
2. **Add property** → `https://www.neelmind.com`
3. Verify via file: `https://www.neelmind.com/google8094b326f2607817.html` (already in robofume `public/`)
4. Submit sitemap: `https://www.neelmind.com/sitemap.xml`
5. Repeat for `https://www.papermantra.com` (add new verification in GSC → DNS TXT in Cloudflare, or HTML file in `papermantra/public/`)
6. Submit sitemap: `https://www.papermantra.com/sitemap.xml`

**Bing Webmaster Tools** (optional): same sitemap URLs.

---

## Phase 3 — Content SEO (highest impact for rankings)

Google won't rank a login page. **Content on neelmind.com drives traffic.**

### Blog strategy (weekly)
Publish articles targeting long-tail searches, e.g.:
- "How to create a question paper in 10 minutes with AI"
- "CBSE board exam paper format guide 2026"
- "Best question paper generator for coaching classes in Pune"
- "LaTeX math equations in exam papers — complete guide"

Each post should:
- 800–1500 words
- Link to `/products`, `/pricing`, and `https://www.papermantra.com/login`
- Include images with `alt` text
- Use H1/H2 with keywords naturally

### Landing page improvements
- **neelmind.com/products** — feature PaperMantra prominently with screenshots
- **neelmind.com/single-product** — detailed feature list, FAQs, testimonials
- Add FAQ schema (JSON-LD) on product page — future task

### PaperMantra public landing (future — high impact)
CRA portal cannot rank well. Options:
1. **Recommended:** Add marketing sections on neelmind.com; keep papermantra.com as login only
2. **Medium effort:** Prerender login page with `react-snap`
3. **Long term:** Migrate portal to Next.js or add SSR landing at `papermantra.com`

---

## Phase 4 — Off-page SEO

- Google Business Profile for NeelMind (Pune)
- List on education directories (IndiaMART, JustDial — with website link)
- YouTube demos: "PaperMantra question paper demo" → link to neelmind.com
- Backlinks from institute partners (`/partners` page)
- Social profiles in `organizationJsonLd` `sameAs` (LinkedIn, Facebook, Twitter URLs in `.env`)

---

## Phase 5 — Monitor & iterate

| Tool | What to check |
|------|----------------|
| Google Search Console | Impressions, clicks, indexed pages, crawl errors |
| Google Analytics 4 | Traffic sources, landing pages |
| PageSpeed Insights | Core Web Vitals for neelmind.com |
| mail-tester.com | Email deliverability (neelmind mail) |

Review monthly:
- Which queries get impressions but no clicks → improve titles/descriptions
- Pages not indexed → fix in Search Console URL inspection
- New blog posts → request indexing in GSC

---

## Why you see nothing on Google today

1. **New domains / low authority** — takes 3–12 months for new sites
2. **Search Console not submitted** — Google may not know your sitemap
3. **PaperMantra is a login app** — almost no indexable content
4. **DNS issues until recently** — Hostinger parking blocked crawlers intermittently
5. **Thin content** — need blogs and product pages with real text

**Fastest path to visibility:** Submit neelmind.com to Search Console + publish 4–8 blog posts targeting question-paper keywords.

---

## Canonical domain policy

| Domain | Canonical |
|--------|-----------|
| neelmind.com | `https://www.neelmind.com` |
| papermantra.com | `https://www.papermantra.com` |

Set in Cloudflare: redirect `neelmind.com` → `www.neelmind.com` and same for papermantra (Page Rule or Bulk Redirect).

---

## Files changed (reference)

**robofume:** `src/lib/seo.js`, `app/sitemap.js`, `app/robots.js`, `app/layout.js`, page metadata, `src/components/JsonLd/`, `public/google8094b326f2607817.html`

**papermantra:** `public/index.html`, `public/robots.txt`, `public/sitemap.xml`, `src/lib/seo.js`, `src/components/SeoHead.jsx`, login/signup pages
