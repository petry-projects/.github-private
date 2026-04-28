---
name: car-hunt
description: Find, research, and rank used Honda/Toyota vehicles (Civic, Accord, CR-V, Camry, Corolla, RAV4) by CPM (cost per remaining mile). Researches reliability by model year, searches AutoTrader/CarGurus/Facebook Marketplace, calculates value score, ranks candidates, and optionally runs VIN history/recall lookups.
argument-hint: [make model year-range max-price zip radius]
user-invocable: true
allowed-tools: Read, Grep, Glob, Bash, Agent, AskUserQuestion, WebFetch, WebSearch, mcp__af7feda1-c109-4c1d-ad7b-0e864ed935d7__search_files, mcp__af7feda1-c109-4c1d-ad7b-0e864ed935d7__read_file_content, mcp__af7feda1-c109-4c1d-ad7b-0e864ed935d7__create_file, mcp__af7feda1-c109-4c1d-ad7b-0e864ed935d7__get_file_metadata, mcp__af7feda1-c109-4c1d-ad7b-0e864ed935d7__download_file_content
---

# Car Hunt — Used Vehicle Finder & Ranker

Search, score, and rank used Honda/Toyota vehicles by Cost Per Mile (CPM) — the core value metric. Lower CPM = more remaining useful life per dollar spent.

---

## Core Formula

```
CPM      = Price / (Expected_Miles − Current_Miles)
Life_Pct = Current_Miles / Expected_Miles   (lower = more life left)
```

**Remaining miles** is the denominator — you are buying future utility, not past metal.

---

## Static Vehicle Reference Table

Baseline data — augmented each run by Step 1 (live reliability research). Do NOT ask the user to re-explain these.

### Expected Lifetime Miles

| Make   | Model   | Expected Miles | Notes                              |
|--------|---------|---------------|------------------------------------|
| Honda  | Civic   | 250,000       | One of the most reliable small cars |
| Honda  | Accord  | 250,000       | 10th gen (2018+) best              |
| Honda  | CR-V    | 250,000       | Avoid 2017–2018 1.5T if cold climate |
| Toyota | Camry   | 300,000       | Exceptional longevity              |
| Toyota | Corolla | 300,000       | Extremely durable drivetrain       |
| Toyota | RAV4    | 250,000       | 5th gen (2019+) excellent          |

### Baseline Reliable/Caution Years

| Make   | Model   | Caution Years        | Preferred Years | Reason                                  |
|--------|---------|---------------------|-----------------|-----------------------------------------|
| Honda  | Civic   | 2012–2015 (9th gen) | 2016+           | 9th gen had engine/AC issues            |
| Honda  | Accord  | 2013–2017 (9th gen) | 2018+           | CVT issues in 4-cyl variants            |
| Honda  | CR-V    | 2017–2018           | 2019+           | Oil dilution with 1.5T in cold climates |
| Toyota | Camry   | 2007–2011           | 2012+           | Oil consumption issues pre-2012         |
| Toyota | Corolla | —                   | 2014+           | Generally very reliable across gens     |
| Toyota | RAV4    | —                   | 2013+           | 2019+ (5th gen) preferred               |

### Trim Hierarchy (low → high)

| Make   | Model   | Trim Order (low → high)                                              |
|--------|---------|----------------------------------------------------------------------|
| Honda  | Civic   | LX → Sport → EX → EX-L → Sport Touring → Touring                    |
| Honda  | Accord  | LX → Sport → EX → EX-L → Sport 2.0T → Touring                      |
| Honda  | CR-V    | LX → EX → SE → EX-L → Touring                                       |
| Toyota | Camry   | L → LE → SE → XLE → XSE → TRD → XSE V6 → XLE V6                    |
| Toyota | Corolla | L → LE → SE → XLE → XSE → Apex                                      |
| Toyota | RAV4    | LE → XLE → XLE Premium → TRD → Adventure → Limited → Platinum       |

---

## Search Parameters

If `$0` is provided, parse it for any of: make, model, year range, max price, zip, radius.

Otherwise ask (combine into one prompt):

> "Let's set up your search. Answer any you know:
> 1. Which makes/models? (default: Civic, Accord, CR-V, Camry, Corolla, RAV4)
> 2. Year range? (e.g., 2002–2023)
> 3. Max price? (e.g., $10,000)
> 4. Your zip code? (e.g., 35242)
> 5. Search radius — how many miles from your zip to search? (e.g., 200)
> 6. Max odometer — the highest mileage you'll consider on the car itself? (e.g., 150,000 — leave blank to include all)
> 7. Min trim? (optional — e.g., 'EX or above')"

Store as:
- `MAKES_MODELS` — list of (make, model) pairs
- `YEAR_MIN`, `YEAR_MAX`
- `MAX_PRICE`
- `ZIP`
- `RADIUS` — search radius in miles from zip (how far away the car can be)
- `MAX_ODOMETER` — max miles on the car's odometer (optional; defaults to expected lifetime per model)
- `MIN_TRIM` (optional)

---

## Step 1: Reliability Research

**Run this before searching listings.** The goal is to produce a per-model reliability card — best years to buy, years to avoid, and known problem patterns — sourced from live data rather than static knowledge. This step takes ~2 minutes and pays for itself by preventing bad purchases.

### Sources to Query (run all in parallel via WebSearch)

For each make/model in `MAKES_MODELS`, run these searches simultaneously:

| Source | Search query |
|--------|-------------|
| Consumer Reports | `"{make} {model} reliability by year" site:consumerreports.org` |
| JD Power | `"{make} {model} dependability rating" site:jdpower.com` |
| Edmunds | `"{year_min}-{year_max} {make} {model} long-term reliability" site:edmunds.com` |
| RepairPal | `"{make} {model} reliability rating common problems" site:repairpal.com` |
| CarComplaints | `"{make} {model} worst years problems" site:carcomplaints.com` |
| Owner forums | `"{make} {model} years to avoid reddit OR forum"` |

For each source hit, WebFetch the top result and extract:
- **Best model years** (rated reliable / low complaint rate)
- **Worst model years** (high complaints / known defects / TSBs)
- **Top 3 recurring issues** (e.g., "transmission shudder," "oil consumption," "AC compressor failure")
- **Generation boundaries** (e.g., "10th gen Civic = 2016–2021")

### Output — Reliability Card Per Model

After research, output one card per make/model before proceeding to listing search:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  RELIABILITY CARD: {Make} {Model}
  Sources: Consumer Reports · JD Power · RepairPal · CarComplaints
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✅ BEST YEARS TO BUY (within {year_min}–{year_max}):
  {year_a}, {year_b}, {year_c} — {reason, e.g. "10th gen refresh, highest CR score"}

⚠️  YEARS TO APPROACH WITH CAUTION:
  {year_x} — {specific issue, e.g. "transmission shudder reported above 60k miles"}
  {year_y} — {specific issue}

🚫 YEARS TO AVOID (if any in range):
  {year_z} — {reason, e.g. "first model year of gen — high TSB rate"}

🔧 COMMON PROBLEMS (any year):
  1. {problem} — {how common, severity}
  2. {problem}
  3. {problem}

📊 RELIABILITY SCORE:
  RepairPal: {X}/5.0 | JD Power: {X}/100 | CR: [Recommended / Not Recommended]

💡 BUYING TIP:
  {1 sentence: e.g. "Skip 2017, prioritize 2019–2021 — post-recall fix and strong resale"}
```

### How Research Feeds into Scoring

After producing reliability cards, build an **adjusted caution list** that merges:
- Static baseline caution years (from reference table above)
- Any additional years flagged by live research

Use this merged list — not just the static table — when applying flags in Step 3.

If research contradicts the static table (e.g., a year previously flagged is now cleared by updated data), note the discrepancy and use the live data.

---

## Step 2: Search for Listings

Search AutoTrader, CarGurus, and Facebook Marketplace in parallel for each make/model combination.

### AutoTrader

AutoTrader search result pages are JavaScript-rendered and return no usable listing data via WebFetch. **Do not attempt to WebFetch AutoTrader search pages** — always use the WebSearch approach below.

**Reliable approach — WebSearch to find individual listing pages:**

```
WebSearch: site:autotrader.com used {year_min}-{year_max} {make} {model} under ${max_price} Birmingham OR Alabama OR "{nearest city}"
```

Examples:
```
site:autotrader.com used 2002-2015 honda accord under $6000 Birmingham Alabama
site:autotrader.com used 2002-2015 toyota camry under $6000 Alabama
site:autotrader.com used 2002-2015 honda civic 100000 miles Birmingham
```

From WebSearch results, collect individual AutoTrader listing URLs (format: `autotrader.com/cars-for-sale/vehicledetails.xhtml?listingId=...`). Then WebFetch each listing page — individual pages have price, mileage, trim, and dealer info embedded in the HTML. Extract those fields.

**Run 2–3 WebSearch queries per model** (vary location terms and year ranges) to maximize coverage. Individual listing pages are far more reliable than search results pages.

**AutoTrader outage handling:** If AutoTrader returns 503 / "currently unavailable" for multiple fetch attempts, note the outage in the results summary and continue with other sources. Do NOT skip the whole search — fall back to WebSearch for any individual listing URLs that may still be cached in search indexes.

### CarGurus

CarGurus search page URL structure changes frequently — the `nl-Used-{Make}-{Model}?zip=...` pattern often 404s. Use WebSearch to find the current working URL:

```
WebSearch: site:cargurus.com used {make} {model} {year_min}-{year_max} Birmingham Alabama under ${max_price}
```

From results, collect individual listing URLs (format: `cargurus.com/Cars/new/nl-Used-{Make}-{Model}-d{id}#listing={listingId}`). WebFetch each listing page — CarGurus individual listing pages contain price, mileage, trim, dealer, and posted date in page metadata.

Run 2–3 WebSearch queries per model varying year ranges. If search results surface a working CarGurus search page URL, WebFetch it to extract multiple listings at once.

### Facebook Marketplace

Facebook Marketplace is login-gated. **Individual listing URLs (`facebook.com/marketplace/item/...`) are not publicly accessible** — WebFetch will hit a login wall and return no data. Never put a generic `facebook.com/marketplace` placeholder URL in the output. The link column must contain either a real item URL or "Search manually."

**What actually works:**

**Option A — Google indexes some public listings:**
```
WebSearch: site:facebook.com/marketplace/item {make} {model} {year_range} {city}
```
Example:
```
site:facebook.com/marketplace/item "Toyota Camry" "2012" OR "2013" Birmingham Alabama
```
If real `facebook.com/marketplace/item/{id}` URLs appear in search results, record them. Attempt WebFetch — if it returns listing data, extract it. If it redirects to a login page, still record the URL in the Link column so the user can open it themselves.

**Option B — Provide the search URL for manual browsing:**
If Google returns no results, include one row in the output table:
```
| — | Facebook Marketplace | — | — | — | — | — | — | — | {city} | — | https://www.facebook.com/marketplace/{city_id}/vehicles?minYear={YEAR_MIN}&maxPrice={MAX_PRICE} | Manual search required — FB Marketplace not publicly scrapeable |
```
This tells the user exactly where to look without fabricating listings.

**Why FB Marketplace matters:** Private-party listings often appear only here at prices well below dealer, with CPM 20–40% better than comparable dealer listings. Always attempt it and always report the outcome honestly.

**Option C — drive a logged-in Chrome session via the Claude in Chrome MCP (preferred when the extension is connected):**

This is what actually works for Birmingham AL searches. Use the numeric city ID directly and apply all filters in the URL:

```
https://www.facebook.com/marketplace/{CITY_ID}/search?query={make}+{model}&daysSinceListed={N}&maxPrice={MAX_PRICE}&minPrice={MIN_PRICE}&maxMileage={MAX_ODO}&minYear={YEAR_MIN}&radiusKM={RADIUS_KM}&sortBy=creation_time_descend
```

Then via JS in the tab, scroll to load lazy results and extract `<a href="/marketplace/item/{id}/">` URLs plus the brief preview text from each card.

**Critical operational facts (learned the hard way):**

- **`/marketplace/birmingham/...` resolves to Birmingham, UK**, not Birmingham, AL. The slug-based path uses your IP/cookies for disambiguation and gets it wrong. **Always use the numeric city ID:** Birmingham AL = `107739635926718`. Look up the numeric ID for any other metro by visiting the city's marketplace page in a logged-in browser once and reading it from the URL after FB redirects.
- **The `query=` parameter on `/marketplace/{cityId}/vehicles?...` URLs is silently dropped by the redirect.** Use `/marketplace/{cityId}/search?query=...` instead — same filters, query is honored. The URL gets rewritten to `/marketplace/category/search/?...` after page render, but the actual filtered results respect the query.
- **`daysSinceListed=1`** filters to last 24 hours and is honored.
- **The `radiusKM` parameter takes kilometers, not miles** — 100mi ≈ 160km.
- The `[BLOCKED: Cookie/query string data]` error from `javascript_tool` happens when your return value contains a URL with query parameters. Strip URLs from returned strings, or write the URL to `window.__foo` and inspect via a separate call.

**Inline message composer (Step 7 outreach) — what actually works:**

After clicking the listing's "Message" button, the composer appears as an inline `<textarea>` to the right of the listing details (typically `top:~798, left:~1180, width:~406`). The default text is "Hi, is this available?". To replace it:

1. Find via `document.querySelectorAll('textarea')`, filter for visible (`r.width > 50 && r.height > 10`).
2. **The textarea is React-controlled — `el.value = msg` does NOT work.** Use the prototype setter: `Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value').set.call(ta, msg)`, then dispatch `new Event('input', {bubbles: true})` and `new Event('change', {bubbles: true})`.
3. The send button is `document.querySelector('[aria-label^="Send message to"]')` (its label is `"Send message to {Seller Name}"`). Click it.
4. Confirm send by checking `/Message again/.test(document.body.innerText)` after a 2.5s delay.

**Seller name extraction for personalization:** The seller's full name appears in the page text after the literal string `"Seller details "`. Match `/Seller details ([^()\n]+?)(?:\(|Joined|Profile|Message|$)/` and split the captured name on whitespace — first whitespace-delimited token is the first name. If that match fails, fall back to `[aria-label^="Send message to"]` and parse the suffix after `"to "`.

**Already-messaged detection:** `Message again` appearing on the listing page means a prior message was sent in this account. Always check this before opening the composer; never message twice. Also cross-check the sheet's `Contacted` column.

**Stale composer state:** If a prior listing's composer is still floating in the page, you may see its `aria-label` ("Write to Donald · 2008 Honda Accord") on the contenteditable element. That's a different, dismissible chat panel — the inline `<textarea>` for the *current* listing is the one to target. Don't be misled by the contenteditable.

### Craigslist

**Primary approach — direct WebFetch of regional search pages:**

WebFetch each regional search URL for every make/model combination. These pages return plain HTML with real listing URLs and brief details. Paginate through all pages until exhausted (increment `s=` by 120 per page):

```
https://atlanta.craigslist.org/search/cta?query={make}+{model}&max_price={MAX_PRICE}&auto_miles_max={MAX_ODOMETER}&sort=priceasc
https://huntsville.craigslist.org/search/cta?query={make}+{model}&max_price={MAX_PRICE}&auto_miles_max={MAX_ODOMETER}&sort=priceasc
https://bham.craigslist.org/search/cta?query={make}+{model}&max_price={MAX_PRICE}&auto_miles_max={MAX_ODOMETER}&sort=priceasc
https://chattanooga.craigslist.org/search/cta?query={make}+{model}&max_price={MAX_PRICE}&auto_miles_max={MAX_ODOMETER}&sort=priceasc
```

From the search page HTML, extract all individual listing URLs in the format `{region}.craigslist.org/{sub}/cto/d/{slug}/{id}.html` or `{sub}/ctd/d/{slug}/{id}.html`. Then WebFetch each individual page — individual listing pages are plain HTML with full details: price, odometer, year, description, post date.

**Secondary approach — WebSearch (use if regional WebFetch returns empty/gated results):**

`site:craigslist.org "{make} {model}" "{year}" "{city}" -"wanted"` — but note this often returns category search pages, not individual listings; prefer regional WebFetch above.

**Exhaustive coverage — do NOT stop at first page.** Check the total result count returned by the search page (e.g., "1–120 of 340 results"). If more pages exist, fetch subsequent pages by adding `&s=120`, `&s=240`, etc. until all results are retrieved.

**Link rule:** Use only the exact URL scraped from the page. Never construct or guess a Craigslist listing URL — IDs are not predictable and a wrong ID is a 404.

### WebSearch Fallback (any source)

If a source's page is unreachable or returns no data, fall back to WebSearch:

```
used {year_min}-{year_max} {make} {model} under ${max_price} Birmingham Alabama site:autotrader.com
used {make} {model} {year_range} ${max_price} Birmingham site:cargurus.com
used {make} {model} {year_range} Alabama craigslist.org
```

Then WebFetch individual listing URLs surfaced by the search results.

### Data to Extract Per Listing

For each listing found, extract:
- `date_found` — today's date
- `date_posted` — the date the listing was originally posted (shown on the listing page as "posted" or "listed on")
- `make`, `model`, `year`, `trim`
- `miles` — current odometer
- `price` — asking price in USD
- `doors` — `2` or `4` (coupe vs. sedan/hatchback); extract from listing text or body style
- `transmission` — `Auto` or `Manual`; extract from listing text or specs
- `location` — city, state
- `distance_mi` — estimated driving distance from user's ZIP to listing city (see Distance Estimation below)
- `dealer` — dealership name, "Private", or "Facebook Marketplace"
- `link` — direct listing URL
- `notes` — any flags (rental history, accidents, new tires, warranty, etc.)

If a field is not found, note it as "—" — it can be filled during deep-dive.

### Distance Estimation

After collecting all unique listing cities, geocode them in bulk using the free Nominatim API (no key required) and compute driving distance estimates.

**Step 1 — Geocode user ZIP:**
```
GET https://nominatim.openstreetmap.org/search?postalcode={ZIP}&countrycodes=us&format=json
```
Extract `lat` and `lon` for the user's home location.

**Step 2 — Geocode each unique listing city (run in parallel):**
```
GET https://nominatim.openstreetmap.org/search?q={city},{state}&countrycodes=us&format=json&limit=1
```
Extract `lat` and `lon` for each city. Cache results — if two listings share the same city, only geocode once.

**Step 3 — Compute distance via Haversine, then apply road correction:**
```python
import math

def haversine(lat1, lon1, lat2, lon2):
    R = 3958.8  # Earth radius in miles
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = math.sin(dlat/2)**2 + math.cos(math.radians(lat1)) * math.cos(math.radians(lat2)) * math.sin(dlon/2)**2
    return R * 2 * math.asin(math.sqrt(a))

straight_line = haversine(user_lat, user_lon, listing_lat, listing_lon)
driving_est   = round(straight_line * 1.3)  # 1.3 correction factor for road routing
```

Display as `~{driving_est} mi`. If geocoding fails for a city, use `—`.

**Add `Distance` column to the output table and sheet** — sort remains CPM ascending, but distance helps the user weigh travel cost against CPM savings.

**Staleness filter:** If `date_posted` is more than 21 days before today, **skip the listing entirely** — it has almost certainly sold or the seller is unresponsive. If `date_posted` cannot be determined, include the listing but note "Post date unknown" in Notes.

**Hard disqualification filters — skip any listing that matches ANY of these:**

1. **Dealer/finance language:** Any mention of "down payment," "monthly payment," "buy here pay here," "BHPH," "in-house financing," or "we finance" → skip. These are dealer tactics, not private party.
2. **Title problems:** Any mention of "no title," "lost title," "salvage," "rebuilt title," "lien," or "lien release" → skip. Clean title is required.
3. **Non-running / major mechanical:** Any mention of "won't crank," "will not crank," "won't start," "doesn't start," "no start," "needs motor," "needs engine," "needs transmission," "blown head gasket," "blown motor," "seized engine," "knocking," "rod knock," "needs to be towed," "must be towed," "as is" + non-running context, "for parts" → skip. The buyer needs a running car.
4. **Scam signals:** Any of the following redirect patterns → skip immediately, do not contact:
   - "Messenger broken" / "my messenger doesn't work" / "can't receive messages"
   - "Contact me at [email]" or "email only" when posted on a platform with messaging
   - Asks to text an out-of-platform number as the only contact method with urgency
   - Price is dramatically below market for no stated reason (e.g., "selling quick, moving")
5. **Mileage/data inconsistency:** Mileage that is implausibly low for the model year (e.g., <30K mi on a vehicle 10+ years old) without explicit explanation (low-mileage garage queen, second car with documented service history) → flag as potential typo or rollback and skip auto-contact. Log for human review.

**Description scraping is mandatory before disqualification.** The structured "About this vehicle" block (mileage, trim, transmission) is not enough — scam, title, and non-running disclosures live almost exclusively in the seller's free-form description. On FB Marketplace, the description appears under "Seller's description" and may be truncated behind a "See more" link; expand and capture the full text before running disqualification regexes.

The non-running scan must run on the **full concatenated text** of: listing title + structured fields + seller's description + any visible "Condition" or "Notes" fields. Do not rely on a single regex against partial text.

Log all disqualified listings in a separate "Disqualified" section at the end of output with the reason — do not silently drop them.

### Parallel Search Strategy

Launch all make/model × source searches simultaneously. Target **50+ raw candidates** before filtering — after disqualification and staleness filtering, 15 is not enough survivors for a useful comparison.

**Exhaustive coverage is mandatory.** Do NOT stop at the first page of results, declare success after a few listings, or give up on a source after one failure. For each source:
- Paginate all result pages until no more listings exist (Craigslist: `&s=120`, `&s=240`, etc.)
- If a fetch fails, retry once then fall back to WebSearch — but always report the fallback
- Every in-scope vehicle must be evaluated; none may be silently skipped
- Note at the end of Step 2 exactly how many pages/results were checked per source

**Batch listing-page fetches efficiently.** After extracting all URLs from a search results page, do NOT fetch each listing page one at a time sequentially. Instead:
1. Extract ALL listing URLs from a search page in a single read
2. Score candidates based on the brief preview data (price, mileage, year) shown in the search results — this is enough to disqualify ~60% of listings without fetching their pages
3. Only WebFetch individual listing pages for candidates that pass the price/mileage preview filter
4. This keeps total fetches manageable while still covering all in-scope listings

**Why results are often ~15:** A single Craigslist search page has 120 results but only a fraction pass price/mileage/year filters. Working through all 4 regional sites × 3 models = 12 searches, each potentially paginating, is the only way to find 50+ qualifying candidates. Do not stop early.

---

## Step 3: Calculate CPM and Score Each Listing

For each listing, compute:

```python
expected_miles = EXPECTED_MILES[make][model]  # from reference table
remaining      = expected_miles - current_miles
cpm            = price / remaining             # dollars per remaining mile
life_pct       = current_miles / expected_miles  # 0.0 to 1.0
```

**Flag rules** (use merged caution list from Step 1 research):
- `life_pct > 0.75` → mark as ⚠️ HIGH CONSUMPTION
- Year in merged caution list → mark as ⚠️ CAUTION YEAR + include the specific issue from the reliability card
- Year in "avoid" list from research → mark as 🚫 AVOID YEAR
- `remaining < 50,000` → mark as ⚠️ LOW REMAINING LIFE
- Source is Facebook Marketplace → mark as 🏠 PRIVATE SELLER (neutral, just informational)

**Trim score** (for tiebreaking, not ranking):
- Assign a numeric rank from the trim hierarchy table (higher = better)
- Display trim rank alongside trim name

### Location Quality Tier

The seller's location is a real value signal. Used cars from higher-income areas correlate (statistically, not deterministically) with: more frequent dealer service, more single-owner histories, gentler use patterns (shorter commutes, more multi-car households spreading miles, fewer hard-loaded trips), and sellers who are less price-sensitive (i.e., more flexibility in negotiation since the asking price isn't load-bearing for their finances). Cars from lower-income areas are not categorically worse — there are well-maintained gems in every zip — but the base-rate odds are different, and that's worth a small modifier in ranking.

**Tier the listing by city/neighborhood**, not by ZIP — Census-tract income data per ZIP is noisy and ZIPs cross municipal boundaries. Use the table below for the Birmingham AL metro; for any new metro, build a comparable table on first run and save it inline.

#### Birmingham AL metro — Location Quality Tiers

| Tier | Locations (city / neighborhood) | Median HHI ~ | Notes |
|---|---|---|---|
| **A** (preferred) | Mountain Brook, Vestavia Hills, Greystone, Indian Springs Village, Cahaba Heights, Liberty Park, Brook Highland, Inverness | $100K–$163K | Highest base-rate odds of single-owner, dealer-serviced car. Sellers often replace cars on cosmetic schedule, not mechanical. Good negotiation flexibility. |
| **B** (good) | Homewood, Hoover (most), Helena, Trussville, Chelsea, Riverchase | $75K–$100K | Solid maintenance habits common. Mixed dealer/independent service. Negotiation typical. |
| **C** (neutral) | Pelham, Alabaster, Pinson, Gardendale, Clay, Moody, Leeds, McCalla, Calera, Columbiana | $55K–$75K | No directional signal. Treat at face value. |
| **D** (caution) | Birmingham city (most neighborhoods), Bessemer, Center Point, Tarrant, Fairfield, Adamsville, Warrior, Ensley, Pratt City, Roebuck, Wylam | <$55K | Higher base-rate of deferred maintenance, harder use patterns, tighter price negotiation (seller may need the cash). Not a disqualifier — just verify maintenance with extra rigor. |

**How tier affects scoring (apply during Step 3):**

- Tier A: subtract $0.005/mi from the CPM as a "quality-adjusted CPM" for ranking purposes — e.g., a real $0.044/mi from Mountain Brook ranks against other cars at $0.039/mi.
- Tier B: subtract $0.002/mi.
- Tier C: no adjustment.
- Tier D: add $0.003/mi to the quality-adjusted CPM.

This is a **ranking modifier only** — the displayed CPM remains the real number. The adjusted CPM is used for sort order and for the comparison tables in Step 5.25 (head-to-head). Always show both: real CPM and tier-adjusted CPM.

**Tier-aware scoring rules:**
- Tier A or B + listing description is sparse → still ⚠️ flag, but assume "maybe just terse seller, not hiding issues."
- Tier D + sparse description → escalate to ⚠️⚠️ — sparse + likely-tighter-finances combination is the highest-risk group.
- Tier A or B + price seems high → that's the negotiation opportunity; sellers in these tiers often accept 8–12% off ask without pushback.
- Tier D + price below market → verify scam signals and title with extra rigor before celebrating CPM.

**Display the Tier in:**
- The ranked listings table (new column: `Tier`)
- The Google Sheet (new column after `Location`: `Tier`)
- The head-to-head comparison table (new row: `Location tier`)
- The test-drive PDF header line (e.g., "Location: Mountain Brook AL · Tier A")
- The skill's recommendation: a Tier A car at slightly worse CPM should still be presented as the leading candidate over a Tier D car at slightly better CPM, with the why explicit.

**Extending to other metros:** when the user runs `/car-hunt` from a ZIP outside Birmingham, the skill should ask once: *"What ZIP are you searching from? I'll build a location-quality tier table for that metro on the first run and reuse it."* Then research median household income by city in that metro (Census, Wikipedia, BestPlaces.net) and build a 4-tier table with the same income thresholds. Save the table inline in this skill (under a new sub-heading per metro) so it persists across runs.

**Honest framing in the user-facing output:**

When you cite tier in a recommendation or warning, name the actual mechanism, not the demographic. Good: *"Sellers in Mountain Brook tend to be less price-sensitive — there's room to negotiate $300–500 off ask."* Bad: *"Mountain Brook is a rich neighborhood."* The signal is economic and behavioral, not identity-based; keep the language objective.

---

## Step 4: Rank and Present Results

Sort all candidates by **CPM ascending** (best value first).

Present reliability cards first, then the ranked table:

```
═══════════════════════════════════════════════════════════════════
  CAR HUNT RESULTS — {N} candidates — {date}
  Search: {makes/models} | {year_min}–{year_max} | ≤${max_price} | {zip} +{radius}mi
  Sources: AutoTrader · CarGurus · Facebook Marketplace
═══════════════════════════════════════════════════════════════════

[Reliability cards from Step 1 — one per model — displayed here]

─── RANKED LISTINGS (by CPM) ───────────────────────────────────

| # | Make/Model | Year | Trim | Dr | Trans | Miles | Price | CPM | Adj.CPM | Life% | Dist | Posted | Location | Tier | Dealer | Flags | Link |
|---|-----------|------|------|----|-------|-------|-------|-----|---------|-------|------|--------|----------|------|--------|-------|------|
| 1 | Honda Civic | 2021 | EX-L | 4 | Auto | 42,000 | $21,500 | $0.103 | $0.098 | 17% | ~12 mi | Apr 20 | Mountain Brook, AL | **A** | Dealer | — | [link] |
| 2 | Toyota Camry | 2019 | XLE | 4 | Auto | 68,000 | $21,000 | $0.091 | $0.089 | 23% | ~172 mi | Apr 18 | Homewood, AL | **B** | CarMax | — | [link] |
| 3 | Honda Accord | 2018 | Sport | 4 | Auto | 89,000 | $19,500 | $0.121 | $0.124 | 36% | ~8 mi | Apr 10 | Center Point, AL | **D** | Private 🏠 | ⚠️ CAUTION YEAR | [link] |
...

⚠️  FLAGS:
  #3: Accord 2018 — CVT shudder reported at 70k+ miles (per CarComplaints); confirm transmission service history
  #N: [any other flags]

📊 SUMMARY:
  Best CPM overall:  #N — {make/model/year} @ ${cpm}/mi
  Best local deal:   #N — within 50 miles of {zip}
  Best private seller: #N — {make/model} via FB Marketplace
  Best Toyota:       #N — {model/year} @ ${cpm}/mi
  Best Honda:        #N — {model/year} @ ${cpm}/mi
  ✅ Best reliability year in results: {year} {make} {model} (per Step 1 research)
  Skipped (no data): {count} listings where miles/price were missing
```

Then ask:
> "Want to dig deeper on any of these? I can pull NHTSA recall/complaint data and check the VIN for any you're seriously considering. Just give me the numbers (e.g., '#1, #3') or say 'all top 5'."

---

## Step 5: Deep-Dive (Optional — user-initiated)

When the user selects specific candidates, run in parallel for each:

### A. NHTSA Recalls (free API)

```
GET https://api.nhtsa.gov/recalls/recallsByVehicle?make={make}&model={model}&modelYear={year}
```

Report: number of open recalls, brief descriptions, whether they are safety-critical.

### B. NHTSA Complaints (free API)

```
GET https://api.nhtsa.gov/complaints/complaintsByVehicle?make={make}&model={model}&modelYear={year}
```

Report: total complaints, top 3 complaint categories, any patterns matching the reliability card from Step 1.

### C. NHTSA Safety Ratings (free API)

```
GET https://api.nhtsa.gov/SafetyRatings/modelyear/{year}/make/{make}/model/{model}
```

Report: overall safety rating (stars out of 5).

### D. Market Comparison (WebSearch)

Search: `"KBB {year} {make} {model} {trim} {miles} miles value"` to find if ask price is above/below market.

```
Market Context — {year} {make} {model} {trim} @ {miles}mi:
  Ask price:    ${price}
  KBB estimate: ~${kbb_range} (fair purchase price)
  Verdict:      [Below market / At market / Above market by ~${delta}]
```

### E. VIN Lookup (user provides VIN — image, sticker photo, or string)

When the user gives you a VIN (or a photo of one — read it from the image), run these in parallel:

#### E1. NHTSA VIN decode — free, always works
```
GET https://vpic.nhtsa.dot.gov/api/vehicles/decodevin/{VIN}?format=json
```
Verify: model year, make, model, trim, body class, engine displacement, cylinders, transmission, drive type, plant city all match the listing. **Flag any mismatch as 🚫 — possible fraud, salvage rebuild, or wrong sticker.**

#### E2. NHTSA per-VIN remedy status — automate via browser, not API
The public NHTSA recall API (`api.nhtsa.gov/recalls/recallsByVin`) returns "Missing Authentication Token" — it's not a real public endpoint. Per-VIN remedy status is only exposed through the NHTSA web UI. Drive it via the Chrome MCP:

1. Navigate the tab to `https://www.nhtsa.gov/recalls`
2. Find input `#ymm-vin-recalls-search-input`, focus it, set value via the prototype setter, dispatch `InputEvent('input')` with `inputType: 'insertText'` and `data: <VIN>`, then `change`.
3. Walk up ~12 parents from the input to find the enclosing container, then click the visible submit button whose text is "Search".
4. Wait ~6s for the result panel to render. The URL will redirect to `?vymm={VIN}`.
5. Read `document.body.innerText` and parse the result block. Look for the literal pattern:
   ```
   {YEAR} {MAKE} {MODEL} VIN: {VIN}
   Recall data refreshed on {date}
   {N} Unrepaired Recalls associated with this VIN
   ```
   - If `{N} == 0` → **All recalls remedied — strong positive signal.**
   - If `{N} > 0` → Each unrepaired recall is listed below with NHTSA campaign #, component, and "Remedy Available" / "Remedy Not Yet Available". Capture all of these and report them as blocking issues (free dealer fix required before purchase).

**Caution:** the help text on the same page also contains the literal string "0 unrepaired recalls associated with this VIN" as an example — match against the result block (which has `VIN: {VIN}` immediately above), not just the literal phrase, to avoid false positives.

**Do NOT use Honda's owner recall portal (`mygarage.honda.com/s/recall-search`).** Its Salesforce LWC form rejects programmatically-typed VINs as "Incorrect VIN entered" regardless of how the input value is set (prototype setter, InputEvent with data, execCommand insertText, blur-to-commit). NHTSA's site works; Honda's does not.

#### E3. Vehicle history report (Carfax-style accident/ownership data)

Carfax and AutoCheck are **paid** ($45–$100 per report) and require a logged-in user account. Do NOT automate these — point the user to them. There are also **free** alternatives that should be checked first:

| Source | What you get | Cost | Automation |
|---|---|---|---|
| **NICB VINCheck** ([nicb.org/vincheck](https://www.nicb.org/vincheck)) | Theft history; salvage/total-loss declarations from member insurers | Free, 5/day limit | Manual — bot-protected form |
| **NMVTIS** (vehiclehistory.com / clearvin.com / etc.) | Title history across all 50 states (junk, salvage, flood, brand changes) | $2–$5/report | Manual — paid |
| **Manufacturer VIN history** (dealer service records) | Service/maintenance history from any franchise dealer using their factory system | Free if you ask the local dealer service desk politely; they often print it | Manual — phone call |
| **Carfax via dealer trade-in tool** | Full Carfax | Free if any car dealer pulls it for you (they pay flat fee) | Manual |
| **Carfax / AutoCheck direct** | Full report | $45–$100 | Manual — never auto-purchase |

For each candidate the user wants to deep-dive, generate **all** of these as clickable links with the VIN pre-filled where supported:
- `https://www.nicb.org/vincheck` (manual entry — VINCheck doesn't accept query params)
- `https://www.vehiclehistory.com/license-plate-search/{VIN}` 
- `https://www.carfax.com/vehicle/{VIN}`
- `https://www.autocheck.com/vehiclehistory/autocheck/en/vinbasics?vin={VIN}`

Tell the user explicitly: "I won't purchase paid reports automatically — open these links yourself if you want to spend the money. Run NICB and ask the local Honda dealer to pull a Carfax for free first."

Present deep-dive report:

```
══════════════════════════════════════
  DEEP DIVE: #{N} — {year} {make} {model} {trim}
  ${price} | {miles} mi | CPM: ${cpm}/mi | Life: {life_pct}%
══════════════════════════════════════

📋 RELIABILITY (from Step 1 research):
  {year} is a: ✅ Best year / ⚠️ Caution year / 🚫 Avoid year
  Known issues for this year: {from reliability card}

🔧 NHTSA RECALLS ({count} open):
  {recall description} — {date} — [Safety critical? Yes/No]
  (none) if clean

📣 NHTSA COMPLAINTS ({total} total):
  Top categories: {category1} ({n}), {category2} ({n}), {category3} ({n})
  {any pattern matching reliability card issues}

⭐ SAFETY RATING: {N}/5 stars overall

💰 MARKET VALUE:
  Ask: ${price} | KBB fair: ~${kbb} | [{verdict}]

🔑 VIN CHECK:
  Decoded: {year} {make} {model} {trim} — ✅ matches listing / ⚠️ mismatch: {detail}
  Full history: vehiclehistory.com/vin/{VIN}  (run manually)

📋 RECOMMENDATION:
  {1-2 sentence summary: worth pursuing / walk away / negotiate price / inspect specific items}
```

---

## Step 5.25: Head-to-Head Comparison (when user is weighing two cars)

When the user pivots to "what about this one?" with a second listing while a first is already in play (or asks "should I do A or B"), do not just analyze the new listing in isolation. Generate an explicit head-to-head table comparing the two on every dimension that matters, with information asymmetry called out:

| | Car A | Car B |
|---|---|---|
| Price | | |
| Miles | | |
| **CPM** | | |
| **Adj.CPM (tier)** | | |
| Remaining miles | | |
| **Location tier** | A / B / C / D | |
| Title | (verified vs. unknown) | |
| Owners | (stated vs. unknown) | |
| Recall status | (per-VIN result if known) | |
| Description detail | (full vs. one sentence) | |
| Caution year? | | |
| Engine reliability | (specific known issues for this powertrain) | |
| Expected lifetime | | |

**Information asymmetry rule:** when one car has verified data (clean title confirmed in description, VIN-checked recall status, full description with disclosures) and the other has unknowns ("Runs and drives smooth" with no title/owner/issue mention), call this out explicitly. The one with more verified data is the higher-confidence buy even if the unverified one wins on raw CPM. Tell the user: "X is theoretically the better-value car, but you're paying with information asymmetry. Y is the higher-confidence buy at a slightly worse CPM."

**Recommendation should be opinionated:** don't list both cars and let the user choose. Pick one and explain why, with a fallback condition ("test drive A first; if it disqualifies, fall back to B"). Hedging-by-default produces analysis paralysis at the seller's driveway.

---

## Step 5.5: Pre-Test-Drive VIN Finalization

**Trigger:** the user says they'll go look at, test drive, or visit a specific car ("I'll test drive it tomorrow", "I'm going to see the Camry", "set me up for the Accord visit", etc.). This step gates the test drive — do NOT let the user walk into a seller's driveway without it.

**Goal:** convert "this listing looks good" into "this specific VIN is verified, recall-clear, and inspection-ready". The 5 minutes this takes prevents the most expensive failure modes (rebuilt title, salvage, mismatched VIN, open Takata airbag).

### Inputs needed from user

If the user has not provided the VIN, ask for it in one message:

> "Before you drive over, ask the seller for the VIN. Most sellers will share it — if they refuse, that's a red flag worth walking away from. Send the VIN here (text or photo of the door sticker) and I'll run the final checks."

Accept any of: typed VIN string, photo of door-jamb sticker (read it from the image), photo of dashboard windshield VIN.

Always echo the VIN back to the user before running checks — VINs are easy to misread (8/B, 1/I/L, 0/O/Q, 5/S, 2/Z).

### A. NHTSA VIN decode (free, always)

```
GET https://vpic.nhtsa.dot.gov/api/vehicles/decodevin/{VIN}?format=json
```

**Critical fields to verify against the listing:** ModelYear, Make, Model, Trim, BodyClass, EngineHP/Displacement/Cylinders, TransmissionStyle, DriveType, PlantCity, PlantCountry.

**🚫 If ANY field disagrees with the listing → STOP.** Possible causes: salvage rebuild with mismatched parts/body, fraudulent listing, sticker swap on a stolen car, or a typo. Do not let the user proceed until the discrepancy is resolved.

### B. NHTSA per-VIN unrepaired-recall check (browser automation)

Drive `https://www.nhtsa.gov/recalls` via the Chrome MCP using the flow documented in §E2 above. The result block to parse:

```
{YEAR} {MAKE} {MODEL}
VIN: {VIN}
Recall data refreshed on {date}
{N} Unrepaired Recalls associated with this VIN
```

- `N == 0` → safe; report "all recalls remedied"
- `N > 0` → list each unrepaired campaign with NHTSA #, component, and remedy availability. **Tell the user to NOT take delivery until the dealer fixes them — Honda/Toyota fix open recalls for free regardless of buyer.**

### C. Title pre-flight (free)

For Alabama transactions specifically (or whichever state matches the listing), run NICB VINCheck (free, manual — no automation). Provide the link and the VIN. NICB will reveal:
- Theft history
- Total-loss declarations from any participating insurer (most major US insurers participate)

If the user is comfortable spending $3, also offer the NMVTIS lookup ([vehiclehistory.com](https://www.vehiclehistory.com/license-plate-search/{VIN})) for nationwide title brand history — junk, salvage, flood, etc. Critical when a listing description omits title status.

### D. Cross-check against listing claims

Compare:
- VIN-decoded year/trim ↔ listing year/trim
- VIN-decoded plant ↔ "1 owner" / "always Alabama" claims (cars built outside Marysville/USA may have different histories than seller suggests)
- Miles claimed ↔ NHTSA's odometer history (if available via the VIN report)

Flag any inconsistency for the user to ask about face-to-face.

### E. Generate the printable test-drive checklist

After all VIN checks complete, **always** generate a checklist for this specific car. The checklist is the deliverable of Step 5.5 — it's what the user takes with them to the seller. Format it as a single block of clean Markdown that prints/copies cleanly to a phone or paper. Use this template:

```
═══════════════════════════════════════════════════════════════
  TEST-DRIVE CHECKLIST — {YEAR} {MAKE} {MODEL} {TRIM}
  VIN: {VIN}  ·  ${price}  ·  {miles} mi  ·  CPM ${cpm}/mi
  Seller: {first_name}  ·  {city, state}  ·  Listing: {short_url}
  Generated: {YYYY-MM-DD}
═══════════════════════════════════════════════════════════════

┌─ BEFORE YOU LEAVE THE HOUSE ─────────────────────────────────┐
[ ] Cash or cashier's check ready (target: $______, walk-away: $______)
[ ] Bill of sale form printed (Alabama: 2 copies, both signatures)
[ ] Flashlight + magnet (paint/body filler check) + tire-tread gauge
[ ] OBD-II scanner if you own one (clears recent codes = red flag)
[ ] Phone fully charged for photos of damage, VIN, odometer
[ ] Tell the seller: "Don't run it before I get there — I want to do a cold start."
└──────────────────────────────────────────────────────────────┘

┌─ PAPER CHECKS (before keys turn) ────────────────────────────┐
[ ] Title in seller's name, clean, NOT marked "Salvage" / "Rebuilt" / "Junk"
[ ] Title VIN matches dashboard VIN matches door-jamb sticker VIN
    Expected VIN: {VIN}
[ ] Seller's photo ID matches name on title
[ ] Odometer on title matches dashboard reading (within 1000 mi)
[ ] No active liens noted on title
└──────────────────────────────────────────────────────────────┘

┌─ COLD START (most important — only happens once) ────────────┐
[ ] Hood up, key OFF: oil dipstick at FULL line, oil clean honey/light brown
[ ] Coolant reservoir between MIN/MAX, no rust/oil floating in it
[ ] Brake fluid at MAX, light amber not dark
[ ] Power steering fluid at MAX, not foamy or dark
[ ] Transmission dipstick (if equipped): FULL, RED — not brown, not burnt smell
[ ] Now start it. WATCH the tailpipe in the rearview mirror at first key-on:
    [ ] No blue/white smoke (= oil burning)
    [ ] No black smoke (= rich/fuel issue)
    [ ] Smoke clears within 10 seconds in cold weather, immediately in warm
[ ] LISTEN for first 5 seconds:
{IF make=Honda AND model=Civic AND year IN [2012-2015]}
    [ ] No 1-2 second metallic rattle (= VTC actuator, $400-700 fix)
{IF make=Honda AND model=Accord AND year IN [2008-2012]}
    [ ] No metallic rattle on first cold start (= VTC actuator, $400-700)
{IF make=Toyota AND model=Camry AND year IN [2007-2011]}
    [ ] No clattering / valve-train tap (= 2AR-FE oil consumption beginning)
{IF year < 2010}
    [ ] No ticking/knocking from top end (= worn rocker arm or low oil)
[ ] All warning lights illuminate THEN extinguish within 5 seconds
[ ] No CEL (Check Engine), ABS, SRS, or TCS lights stay on
[ ] All gauges sweep and settle in normal range
└──────────────────────────────────────────────────────────────┘

┌─ STATIC INSPECTION (engine off, 5 minutes) ──────────────────┐
[ ] Walk around: panel gaps even, paint matches across panels (rebuild signal)
[ ] Magnet sticks to every steel body panel (no Bondo)
[ ] Tire tread depth ≥ 4/32" all four (penny test: Lincoln's head shows = bad)
[ ] All four tires same brand & size, even wear (uneven = alignment/suspension)
[ ] No rust on rocker panels, frame rails (look UNDER the car with flashlight)
[ ] Check for fluid puddles where it was parked (oil, coolant, transmission)
[ ] Open all 4 doors, hood, trunk — alignment, latches, weatherstripping intact
[ ] All glass: no chips, cracks, repair stars (windshield replacement = $200-400)
[ ] All lights work: headlights low/high, brake, turn (both sides), reverse
[ ] AC: blows COLD at center vent within 60 seconds at idle
[ ] Heat: blows HOT at center vent within 90 seconds (rules out heater core)
[ ] All windows up/down without grinding (regulators are common failure)
[ ] Power locks work all 4 doors
[ ] Driver's seat slides/reclines smoothly; no broken plastics on switches
[ ] All seatbelts retract fully and lock when yanked
[ ] No mildew/cigarette/pet smell (flood/heavy use signal)
[ ] Trunk floor / spare tire well DRY (water damage check)
└──────────────────────────────────────────────────────────────┘

┌─ MODEL-SPECIFIC RED FLAGS (this car's known issues) ─────────┐
{INSERT model-specific items based on year/make/model from reliability card}
{Examples — only emit the rows that match this car's profile:}
[ ] {Honda Accord 2008-2012} Pull dipstick after test drive — oil should still be at FULL
    Ask: "How often do you add oil between changes?" — anything > 0 qt/1000mi = walk
[ ] {Honda Accord 2008-2012 V6} Reject this model — 5AT in V6 had failure rate >25% by 150K. K24 4-cyl only.
[ ] {Honda Civic 2012-2015} Ask if airbag inflator recalls (Takata) have been done — verify on receipts
[ ] {Toyota Camry 2007-2011} 2AR-FE oil consumption: ask about piston-ring TSB (T-SB-0094-11). Untreated cars use 1qt/1000mi.
[ ] {Toyota Camry 2007-2011} Check for rear strut rubbing/clunk over bumps
[ ] {Honda CR-V 2017-2018 1.5T} Walk away — oil dilution issue, especially in cold climates
[ ] {Toyota Camry 2012+} Look for rear stabilizer bar end-link rattle on test drive
[ ] {ANY 8th gen Accord 2008-2012} Verify A/C compressor — failure ~$800
└──────────────────────────────────────────────────────────────┘

┌─ TEST DRIVE — minimum 15 minutes, mixed roads ───────────────┐
[ ] Driveway: smooth take-off from cold, no clunks from suspension
[ ] Parking lot: tight figure-8 left and right, listen for CV joint clicks
[ ] Reverse: 30+ feet straight back, no whine/grinding
[ ] City stop-and-go: smooth 1→2 and 2→3 shifts, no flare or slip (auto)
[ ] Hard braking from 30 mph (in safe spot): straight stop, no pulsation, no pull
[ ] 45-55 mph cruise: no vibration in steering wheel (alignment/balance)
[ ] Highway 65+ mph: no wandering, no death-wobble
[ ] Highway: WOT (wide-open throttle) acceleration to 70 — listen for transmission slip
[ ] Wind down all windows, stereo OFF: listen for whines, ticks, knocks at every speed
[ ] Hot stop: park, leave running 2 min, look under for new leaks
[ ] After drive: pop hood — coolant NOT boiling out of overflow (head gasket check)
[ ] After drive: oil dipstick still at FULL (oil consumption check)
└──────────────────────────────────────────────────────────────┘

┌─ NEGOTIATION LEVERS YOU FOUND (fill in during inspection) ───┐
[ ] Tire tread <4/32 → -$400 (set of 4 budget tires installed)
[ ] AC weak → -$600 to -$1200 (compressor/condenser)
[ ] Brake pulsation → -$200 (rotors + pads)
[ ] Battery >4 yrs old → -$150
[ ] Cracked windshield → -$300
[ ] Each warning light ON → -$200 minimum (codes need scan)
[ ] Cosmetic damage seller already disclosed: $______
[ ] Total deductions: $______
[ ] My ceiling: ${ask_price} − total deductions = $______
└──────────────────────────────────────────────────────────────┘

┌─ RED FLAGS — IF YOU SEE ANY OF THESE, WALK AWAY ─────────────┐
[ ] Title not present at meeting (any reason)
[ ] VIN on title doesn't match dashboard or door
[ ] Seller name on title doesn't match seller's ID
[ ] Engine smokes blue at any point (oil burning)
[ ] Transmission flares or slips on test drive
[ ] Any frame rail rust deeper than surface
[ ] CEL on, seller "doesn't know what it means"
[ ] Coolant in oil cap (mayonnaise) or oil in coolant (sheen)
[ ] Recent paint on a single panel that doesn't match
[ ] Seller pressures you to "decide now" or "two other people coming"
└──────────────────────────────────────────────────────────────┘

┌─ AFTER YOU AGREE TO BUY ─────────────────────────────────────┐
[ ] Sign bill of sale (both copies, both sign, keep one)
[ ] Title: seller signs and dates SELLER section ONLY (do not sign anywhere else
    until you're at the courthouse — Alabama requires courthouse witness for buyer signature)
[ ] Take photo of seller's driver's license next to the title for records
[ ] Pay only after both signatures and physical title in YOUR hand
[ ] Get keys (all keys — most cars have 2; ask for both)
[ ] Drive immediately to nearest courthouse OR home (don't delay registration > 20 days
    in Alabama — late fee accrues)
└──────────────────────────────────────────────────────────────┘
```

**Implementation rules for the checklist generator:**

- Always emit the WHOLE template — every section, every checkbox. Brevity is not a virtue here; the user is going to use this in a stressful negotiation and wants to see the line *before* needing to remember it.
- Substitute `{...}` placeholders with concrete values from the listing + VIN check + reliability card.
- For the `MODEL-SPECIFIC RED FLAGS` section: only emit the rows that match the year+make+model. If none match, emit a single line: `[ ] No known year-specific issues — standard inspection only`. Pull from the static caution table AND any live Step 1 reliability card findings.
- Substitute the price and the `walk-away` line — walk-away should default to ask price minus typical inspection-revealed deductions (~$500 for most listings).

### F. Save the checklist as a PDF (always)

**Every checklist generated in Step 5.5 must also be saved as a printable PDF.** The Markdown is for the chat; the PDF is for the user's pocket — they'll print it or open it on their phone at the seller's driveway.

**Filename:** `~/Downloads/car-hunt-checklist-{YYYY-MM-DD}-{make-lower}-{model-lower}-{last4ofVIN}.pdf`

Example: `car-hunt-checklist-2026-04-28-honda-accord-9855.pdf`

**Implementation:**
- Use Python `reportlab` (Platypus). Install with `pip3 install --quiet reportlab` if it's not already present.
- Page size: US Letter, 0.5" side margins, 0.4" top/bottom.
- Use a header with the model + VIN, a sub-line with price/miles/CPM/seller/listing URL, and a "Verified: 0 unrepaired NHTSA recalls" line if Step B came back clean (or list the open ones if not).
- Every checklist section becomes a `<b>` heading followed by checkbox rows: render checkboxes as the literal Unicode `☐` followed by the item text (a Paragraph). Use `<sub>` / `<super>` tags for any subscripts/superscripts — never Unicode subscript glyphs (built-in fonts don't render them).
- The "Negotiation levers" section should be rendered as a `Table` with three columns (Issue / Deduction / Confirmed?) so the user can fill it in by hand. Bold-row + light-yellow background for the "Total deductions" and "My counter" rows.
- Insert a `PageBreak()` after the static-inspection section so the model-specific + test-drive + negotiation sections start fresh on page 2.
- Set the PDF's `title` and `author` metadata so it's identifiable in Finder/Files.
- Footer: a small italic note acknowledging the cold-start tailpipe + VTC listen as the single most important moment.

After writing the file, tell the user the absolute path and say: "Open it on your phone or AirPrint it. Take it to the seller."

### G. Fraud / paperwork checklist (always emit alongside the test-drive checklist)

Used-car fraud is a multi-billion-dollar industry: forged titles, VIN cloning, curbstoning, title-jumping, odometer rollback, fake cashier's checks. **Every test-drive checklist generated in §F must be paired with a fraud / paperwork checklist** so the user can verify the documents against the car. This is a vehicle-agnostic checklist — it doesn't change based on year/make/model — so generate it once and reuse it across cars in the same hunt session.

**Filename:** `~/Downloads/car-hunt-fraud-paperwork-checklist.pdf` (no date or VIN in filename — it's reusable).

If the file already exists from a prior run within the same week, **skip regeneration** unless the user asks for a refresh; just point them at the existing path. The fraud checklist is generic — there's no need to rebuild it for every car.

**Mandatory sections, in this order:**

1. **⚠️ Walk-away triggers** — single-fail-and-leave items (refused VIN, missing title, mismatched VIN, scratched/laminated title, salvage/rebuilt brand, lien with no release, crypto/wire payment demand, blank-form signing pressure, ID mismatch, location-changing meets, time pressure tactics)
2. **Title document — visual inspection** (original not photocopy, watermarks/security features, no erasures/white-out, single ink color, brand-history field clean, owner name printed not handwritten, odometer field filled in, issue date plausible)
3. **VIN verification — three locations match** (dashboard / door jamb / title — write all three down digit-by-digit; beware 0/O, 1/I/L, 5/S, 2/Z, 8/B; 17 chars post-1981; sticker intact, no fresh adhesive; no paint overspray on plates; NHTSA decode + nhtsa.gov/recalls + nicb.org/vincheck + optional NMVTIS)
4. **Curbstoning detection** (title in seller's name 30+ days; ID matches title and address; ownership story plausible; insurance card present; personal photos in listing not lot/curbside; no multiple cars on same profile; reverse-image search; phone area code local; meeting at home)
5. **Odometer fraud detection** (title odometer matches dash within 1000 mi; no "Not Actual Mileage"; wear consistent — bolster, wheel, pedals, carpet, door handles; service stickers; cluster screws factory; OBD-II ECU mileage)
6. **Bill of sale** (two identical handwritten copies; today's date; both names + addresses; full VIN; odometer; actual sale price; AS-IS WHERE-IS language; both sign and date both copies; photo of seller's ID with bill of sale + VIN visible)
7. **Title transfer mechanics** (state-specific; for Alabama: seller signs SELLER section only in your presence, fills odometer + price, **buyer does NOT sign yet — courthouse witness required**; register within 20 days; bring signed title + bill of sale + ID + insurance + payment ~2% sales tax)
8. **Payment protection** (pay only after title + keys in hand; counterfeit-detector pen for cash; never accept seller's cashier's check; bank-to-bank meet at teller; never crypto/gift cards/wire to remote bank; no deposits; written receipt)
9. **Stolen-vehicle detection** (NICB clean; ignition/locks intact; service records consistent owner; insurance matches title; license plate registered to seller; ask to meet at police station — real sellers say yes)
10. **Title-jumping detection** (seller's name MUST be on title as registered owner, not as prior buyer; walk away from any "I haven't transferred it yet" situation except documented estate sales)
11. **After-purchase (within 7 days)** (register at probate office; new plate; insurance updated; independent mechanic post-purchase inspection $75–100; save all documents 3+ years)

**Implementation notes:**
- Use the same reportlab structure as §F (US Letter, ☐ checkboxes, sections in `<b>` headings, page break after section 4 or 5).
- Header should be in red (`#a83232`) instead of blue to visually distinguish it from the test-drive checklist.
- Add a prominent footer: *"This checklist exists because used-car fraud is a multi-billion-dollar industry. Most sellers are honest; the protective habit is: walk away if anything feels off. There will be another car."*
- A working reference implementation lives at `/Users/dj/.claude/skills/car-hunt/build_fraud_paperwork_pdf.py` — copy and adapt rather than rebuilding from scratch.

After writing the fraud PDF, tell the user: *"Two PDFs are ready — the test-drive checklist (car-specific) and the fraud-paperwork checklist (generic, reusable across all cars). Take both. The fraud one is most useful in the seller's driveway when you're looking at the title document."*

**Sample script structure** (the implementation that worked for the first checklist):

```python
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.colors import HexColor
from reportlab.lib.units import inch
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak
from reportlab.platypus.flowables import HRFlowable

OUT = f'/Users/dj/Downloads/car-hunt-checklist-{date}-{make}-{model}-{vin_last4}.pdf'
doc = SimpleDocTemplate(OUT, pagesize=letter,
    leftMargin=0.5*inch, rightMargin=0.5*inch,
    topMargin=0.4*inch, bottomMargin=0.4*inch,
    title=f'Car Hunt Test-Drive Checklist — {year} {make} {model} (VIN ...{vin_last4})',
    author='car-hunt skill')

# Styles, sections, items, neg-table, etc. (see prior implementation)

doc.build(story)
```

A working reference implementation lives in `/tmp/build_checklist_pdf.py` after the first generation; copy and adapt it for each new car rather than rebuilding from scratch.

---

## Step 6: Export to Google Sheet

After presenting results, always offer to export:

> "Want me to save these results to a Google Sheet?"

### ⚠️ Drive MCP limitation — `create_file` does NOT overwrite

The Drive MCP exposes only `create_file` for writes. **It does not overwrite by title or by ID.** Every call produces a brand-new file at a new sheet ID, regardless of whether a file with the same title already exists. There is no `update_file_content`, no "add tab to existing spreadsheet", no Sheets API write endpoint exposed through this MCP.

Practical consequences:
- The user's bookmarked URL goes stale every run. Each run leaves an orphan sheet behind.
- Memory (`project_car_hunt_skill.md`) must always be updated to point at the **latest** sheet ID, and prior IDs explicitly marked obsolete.
- **Always** print the new sheet URL prominently in the run summary, with explicit text like "⚠️ Sheet ID changed — your bookmark to the prior sheet now shows yesterday's data; here's the new one." Don't bury it.

If a stable URL ever becomes a hard requirement, the only fix is to wire up direct Google Sheets API access via `gspread` + a service account JSON, or call the Sheets `values:update` endpoint via `curl` with an OAuth token. That's outside the Drive MCP. Until then, accept the new-sheet-per-run pattern and surface it loudly.

### Update Mode vs. New Sheet

The skill maintains a **single persistent tracking sheet** across runs. On each run:

1. Check memory (`/Users/dj/.claude/projects/-Users-dj-repos-self/memory/project_car_hunt_skill.md`) for the current sheet ID.
2. If a sheet ID exists, **update it** — download existing rows, merge with new results (deduplicate by Link URL), and rewrite into a new sheet (Drive MCP creates a new file each time — see warning above).
3. If no sheet ID exists, **create a new sheet**, then save its ID to memory for future runs.

**Deduplication logic:**
- Match rows by `Link` URL — same URL = same listing
- If a listing appears again with a different price, update the row and note "Price changed: was $X" in Notes
- Mark listings that were in a prior run but are not found this run as `STALE — may be sold` in Notes (do not delete them)
- New listings not in the prior run get added as new rows

### Column Order

```
Date | Make | Model | Year | Package | Doors | Trans | Miles | Cost | CPM | Adj.CPM | Life | Dist | Posted | Location | Tier | Dealer | Link | Notes | Contacted
```

- **Date** — `DD Mon YYYY` format (e.g., `25 Apr 2026`) — date this row was last updated
- **Package** — trim level (e.g., `LX`, `EX`, `LE`)
- **Doors** — `2` or `4`
- **Trans** — `Auto` or `Manual`
- **Posted** — date the listing was first posted (e.g., `Apr 20`) — omit year if current year; use `Unknown` if not found
- **Miles** — numeric, no commas (e.g., `53000`)
- **Cost** — formatted as `$4750`
- **CPM** — formatted as `$0.019` (3 decimal places) — the *real* cost-per-mile
- **Adj.CPM** — formatted as `$0.014` — the *quality-adjusted* CPM with location-tier modifier applied (this is the column to sort by)
- **Life** — formatted as `18%`
- **Tier** — `A` / `B` / `C` / `D` — Location Quality Tier per the metro table; blank if metro not yet tabled
- **Notes** — include emoji flags (✅ BEST YEAR / ⚠️ CAUTION / 🚫 AVOID / ★ BEST PICK) and the specific reason
- **Contacted** — `YYYY-MM-DD sent` when a message was sent to this seller (e.g., `2026-04-27 sent`); blank if not yet contacted. Updated by Step 7.

### How to Create or Update the Sheet

**Creating a new sheet:**

**Step 1** — Build the CSV content, base64-encode it via Bash:

```python
import base64
csv_content = "Date,Make,Model,Year,Package,Doors,Trans,Miles,Cost,CPM,Life,Posted,Location,Dealer,Link,Notes\n"
# ... one row per listing, sorted by CPM ascending ...
encoded = base64.b64encode(csv_content.encode('utf-8')).decode('utf-8')
```

**Step 2** — Call `mcp__af7feda1-c109-4c1d-ad7b-0e864ed935d7__create_file` with:
```json
{
  "title": "Car Hunt — Active Listings",
  "mimeType": "text/csv",
  "content": "{base64_encoded_csv}"
}
```

The Drive MCP auto-converts `text/csv` → Google Spreadsheet. **IMPORTANT: Do NOT use xlsx MIME type** — it fails with a base64 validation error. Always use `text/csv`.

**Step 3** — The tool returns a file object with an `id`. Construct the share URL:
```
https://docs.google.com/spreadsheets/d/{id}/edit
```

Save this ID to memory (`project_car_hunt_skill.md`) so future runs can update the same sheet.

**Updating an existing sheet:**

**Step 1** — Call `mcp__af7feda1-c109-4c1d-ad7b-0e864ed935d7__download_file_content` with the stored sheet ID to read current rows.

**Step 2** — Merge with new results: deduplicate by Link URL, update prices, mark stale.

**Step 3** — Rebuild the full CSV and call `mcp__af7feda1-c109-4c1d-ad7b-0e864ed935d7__create_file` with the same title — this overwrites the existing sheet content.

### Row Order and Completeness

- Rows sorted by CPM ascending (best value first) — same order as the ranked output
- Include ALL scored listings, even those over the mileage filter — flag over-limit rows in Notes
- Include unscored listings at the bottom with `—` for CPM and Life, and reason in Notes
- Do not drop any listing silently

---

## Scheduling

This skill is designed to run periodically (e.g., daily or weekly via `/schedule`).

When running in scheduled/automated mode:
- **Skip Step 1 (reliability research)** unless the model list has changed — reliability cards don't change week to week; cache the last research output
- Only surface **new** listings not seen before (compare links against prior run output)
- Skip Step 6 (sheet write-back) unless new high-value finds warrant it
- Send a push notification summary if new candidates have CPM below the current best in the tracked sheet

Default search parameters when running unattended (update these after each interactive session):
```
MAKES_MODELS:   Civic, Accord, Camry
ZIP:            35243
RADIUS:         200
MAX_PRICE:      6000
YEAR_MIN:       2002
YEAR_MAX:       current year
MAX_ODOMETER:   250000
```

---

## Step 7: Automatic Outreach (Optional)

After Step 6 (sheet export), offer this option:

> "Want me to message the top uncontacted listings on Facebook Marketplace?"

Only run this step if the user explicitly confirms — either at the start of a run (e.g., "also send messages") or when prompted here.

### Message Template

```
Hey [FIRST_NAME] - Can I meet up tomorrow to test drive? Looking for a replacement car for a foster kid that got rear ended. Thanks!
```

Replace `[FIRST_NAME]` with the seller's actual first name extracted from the listing page. If the name can't be determined, omit the name entirely and open with "Hey -".

### How to Execute

**For each candidate in the top N uncontacted qualified listings (default N=3):**

1. **Open the listing tab** — navigate to the FB Marketplace listing URL in the Chrome extension.

2. **Check message history** — run this JS on the listing page:
   ```javascript
   const text = document.body.innerText;
   const alreadyMessaged = text.includes('Message again');
   const sellerMatch = text.match(/Seller details\s*\n([^\n(]+)/);
   const sellerName = sellerMatch ? sellerMatch[1].trim().split(' ')[0] : null;
   JSON.stringify({ alreadyMessaged, sellerName });
   ```
   - If `alreadyMessaged` is `true` → skip this listing (already contacted), move to next candidate
   - Also check the sheet's `Contacted` column — if it has a date, skip

3. **Show dry run first** — before sending anything, show the user:
   ```
   Proposed messages (dry run):
   1. [Seller name] — [Year Make Model] — "Hey [Name] - Can I meet up..."
   2. ...
   
   Proceed?
   ```
   Wait for explicit confirmation before sending.

4. **Send via modal dialog** (the only reliable method on FB Marketplace):
   - Click the blue "Message" button at the top of the listing (not the inline Send button at the bottom)
   - Wait for the "Message [Seller Name]" modal to appear
   - Click the textarea in the modal
   - Type the personalized message
   - Click "Send message" button in the modal
   - Confirm send by checking for "Sending" button state

5. **Update the sheet** — after successful send, write `YYYY-MM-DD sent` to the `Contacted` column for that listing's row.

### Important Rules

- **Always check history before sending** — use both JS detection (`Message again` text) and the sheet's `Contacted` column to avoid duplicate outreach
- **Never send without dry-run approval** — show proposed messages first; wait for "proceed" / "yes" / "go ahead"
- **Never fabricate a seller name** — if name extraction fails, drop the name from the greeting
- **Skip non-FB listings** — this outreach flow only works on FB Marketplace; other sources require manual contact
- **Skip listings where the modal doesn't open** — some FB profiles block messages; note it and move on
- **Log every send attempt** — update the sheet regardless of whether the send succeeded or failed (note "FAILED" if the modal didn't respond)

---

## Output Format Rules

1. **Always show CPM to 3 decimal places** — `$0.103/mi` not `$0.10/mi`
2. **Always show Life% as integer** — `17%` not `0.17`
3. **Links must be real or explicitly marked manual** — every Link column value must be one of: (a) an exact URL returned by WebFetch/WebSearch that points to a specific listing, or (b) a search URL the user can open manually, labeled "Manual search — [source]". Never use a homepage (`facebook.com/marketplace`, `craigslist.org`) as a listing link. Never construct or guess a listing URL.
4. **Flag before ranking** — flags are informational, not disqualifying; reliability card context appears in flag detail
5. **Never silently drop a listing** — if miles or price are missing, show the row with `—` and note it couldn't be scored
6. **Sort by CPM always** — don't re-sort by price or miles unless user asks
7. **Show source column** — AutoTrader / CarGurus / Craigslist / FB Marketplace — so the user knows where to find the listing

---

## Important Rules

1. **Lower CPM = better value** — always. Never present higher CPM as "better."
2. **Expected miles are model-specific** — never use a flat number across all vehicles.
3. **Flag caution years, hard-flag avoid years** — ⚠️ for caution, 🚫 for avoid; never silently drop either.
4. **Live research overrides static table** — if Step 1 clears or adds a year, use that; note any contradiction.
5. **VIN lookups are user-initiated** — never auto-run paid services.
6. **NHTSA APIs are free and require no key** — always run them for deep-dive candidates.
7. **Life% is consumed life, not remaining** — `17%` means 17% used, 83% left. Make this explicit in output.
8. **Do not filter by CPM threshold** — show all scored candidates ranked; let the user choose the cutoff.
9. **Facebook Marketplace scraping often fails** — always note when it was attempted and whether it succeeded, so the user knows to check manually if needed.
