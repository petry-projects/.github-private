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
3. **Scam signals:** Any of the following redirect patterns → skip immediately, do not contact:
   - "Messenger broken" / "my messenger doesn't work" / "can't receive messages"
   - "Contact me at [email]" or "email only" when posted on a platform with messaging
   - Asks to text an out-of-platform number as the only contact method with urgency
   - Price is dramatically below market for no stated reason (e.g., "selling quick, moving")

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

| # | Make/Model | Year | Trim | Dr | Trans | Miles | Price | CPM | Life% | Dist | Posted | Location | Dealer | Flags | Link |
|---|-----------|------|------|----|-------|-------|-------|-----|-------|------|--------|----------|--------|-------|------|
| 1 | Honda Civic | 2021 | EX-L | 4 | Auto | 42,000 | $21,500 | $0.103 | 17% | ~12 mi | Apr 20 | Birmingham, AL | Dealer | — | [link] |
| 2 | Toyota Camry | 2019 | XLE | 4 | Auto | 68,000 | $21,000 | $0.091 | 23% | ~172 mi | Apr 18 | Atlanta, GA | CarMax | — | [link] |
| 3 | Honda Accord | 2018 | Sport | 4 | Auto | 89,000 | $19,500 | $0.121 | 36% | ~8 mi | Apr 10 | Hoover, AL | Private 🏠 | ⚠️ CAUTION YEAR | [link] |
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

### E. VIN Lookup (user provides VIN)

1. **NHTSA VIN decode** (free — verifies the car matches what's advertised):
   ```
   GET https://vpic.nhtsa.dot.gov/api/vehicles/decodevin/{VIN}?format=json
   ```
   Verify: make, model, year, trim match listing. Flag any mismatch.

2. **VehicleHistory.com** (paid — ~$2/report):
   - Prompt user: "For a full accident/ownership history, run a VIN check at vehiclehistory.com or carfax.com. Want me to open the link?"
   - Do NOT automate paid lookups — present the VIN and URL for the user to run manually.

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

## Step 6: Export to Google Sheet

After presenting results, always offer to export:

> "Want me to save these results to a Google Sheet?"

### Update Mode vs. New Sheet

The skill maintains a **single persistent tracking sheet** across runs. On each run:

1. Check memory (`/Users/dj/.claude/projects/-Users-dj-repos-self/memory/project_car_hunt_skill.md`) for the current sheet ID.
2. If a sheet ID exists, **update it** — download existing rows, merge with new results (deduplicate by Link URL), and rewrite the sheet.
3. If no sheet ID exists, **create a new sheet**, then save its ID to memory for future runs.

**Deduplication logic:**
- Match rows by `Link` URL — same URL = same listing
- If a listing appears again with a different price, update the row and note "Price changed: was $X" in Notes
- Mark listings that were in a prior run but are not found this run as `STALE — may be sold` in Notes (do not delete them)
- New listings not in the prior run get added as new rows

### Column Order

```
Date | Make | Model | Year | Package | Doors | Trans | Miles | Cost | CPM | Life | Dist | Posted | Location | Dealer | Link | Notes
```

- **Date** — `DD Mon YYYY` format (e.g., `25 Apr 2026`) — date this row was last updated
- **Package** — trim level (e.g., `LX`, `EX`, `LE`)
- **Doors** — `2` or `4`
- **Trans** — `Auto` or `Manual`
- **Posted** — date the listing was first posted (e.g., `Apr 20`) — omit year if current year; use `Unknown` if not found
- **Miles** — numeric, no commas (e.g., `53000`)
- **Cost** — formatted as `$4750`
- **CPM** — formatted as `$0.019` (3 decimal places)
- **Life** — formatted as `18%`
- **Notes** — include emoji flags (✅ BEST YEAR / ⚠️ CAUTION / 🚫 AVOID / ★ BEST PICK) and the specific reason

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
