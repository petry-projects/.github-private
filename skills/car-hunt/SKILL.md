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
> 2. Year range? (e.g., 2017–2023)
> 3. Max price? (e.g., $25,000)
> 4. Your zip code and search radius? (e.g., 35242, 200 miles)
> 5. Max miles? (optional — leave blank to not filter)
> 6. Min trim? (optional — e.g., 'EX or above')"

Store as:
- `MAKES_MODELS` — list of (make, model) pairs
- `YEAR_MIN`, `YEAR_MAX`
- `MAX_PRICE`
- `ZIP`, `RADIUS`
- `MAX_MILES` (optional)
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

### CarGurus URL Pattern

```
https://www.cargurus.com/Cars/new/nl-Used-{Make}-{Model}?zip={ZIP}&distance={RADIUS}&maxPrice={MAX_PRICE}&minYear={YEAR_MIN}&maxYear={YEAR_MAX}
```

Examples:
- `https://www.cargurus.com/Cars/new/nl-Used-Honda-Civic?zip=35242&distance=200&maxPrice=25000&minYear=2017&maxYear=2023`
- `https://www.cargurus.com/Cars/new/nl-Used-Toyota-Camry?zip=35242&distance=200&maxPrice=25000&minYear=2017&maxYear=2023`

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

Craigslist search pages use simple HTML and are reliably WebFetchable. Individual listing pages also work. However, **listings expire quickly** — always use the exact URL returned by search, never construct or guess a listing URL.

**Search URL pattern:**
```
https://huntsville.craigslist.org/search/cta?query={make}+{model}&max_price={MAX_PRICE}&auto_miles_max={MAX_MILES}
```

Regional Craigslist sites covering the 35243 area (use all of these):
- `https://bham.craigslist.org/search/cta` — Birmingham (primary)
- `https://huntsville.craigslist.org/search/cta` — Huntsville
- `https://chattanooga.craigslist.org/search/cta` — Chattanooga
- `https://atlanta.craigslist.org/search/cta` — Atlanta

Full example URL:
```
https://bham.craigslist.org/search/cta?query=toyota+camry&max_price=6000&auto_miles_max=100000&sort=priceasc
```

WebFetch the search results page — Craigslist HTML is parseable and returns real listing data including title, price, mileage (when listed), and the direct listing URL (`/cto/d/...`). Extract individual listing URLs and WebFetch those for full details.

**Link rule:** Use the exact `bham.craigslist.org/cto/d/{slug}/{id}.html` URL from the page. Never use `craigslist.org` without the full listing path.

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
- `make`, `model`, `year`, `trim`
- `miles` — current odometer
- `price` — asking price in USD
- `location` — city, state
- `dealer` — dealership name, "Private", or "Facebook Marketplace"
- `link` — direct listing URL
- `notes` — any flags (rental history, accidents, new tires, warranty, etc.)

If a field is not found, note it as "—" — it can be filled during deep-dive.

### Parallel Search Strategy

Launch all make/model × source searches simultaneously. Aim for **25+ listings per run**. If results are sparse, widen radius or drop year floor by 1–2 years.

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

| # | Make/Model | Year | Trim | Miles | Price | CPM | Life% | Source | Location | Dealer | Flags | Link |
|---|-----------|------|------|-------|-------|-----|-------|--------|----------|--------|-------|------|
| 1 | Honda Civic | 2021 | EX-L | 42,000 | $21,500 | $0.103 | 17% | AutoTrader | Birmingham, AL | Dealer | — | [link] |
| 2 | Toyota Camry | 2019 | XLE | 68,000 | $21,000 | $0.091 | 23% | CarGurus | Atlanta, GA | CarMax | — | [link] |
| 3 | Honda Accord | 2018 | Sport | 89,000 | $19,500 | $0.121 | 36% | FB Mkt | Hoover, AL | Private 🏠 | ⚠️ CAUTION YEAR | [link] |
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

When confirmed, create a new Google Sheet via the Drive MCP using CSV→Sheets auto-conversion. Do NOT attempt to append to the original template spreadsheet — always create a fresh dated sheet per run so results are preserved separately.

### Column Order (match original template exactly)

```
Date | Make | Model | Year | Package | Miles | Cost | CPM | Life | Location | Dealer | Link | Notes
```

- **Date** — `DD Mon YYYY` format (e.g., `25 Apr 2026`)
- **Miles** — numeric, no commas (e.g., `53000`)
- **Cost** — formatted as `$4750`
- **CPM** — formatted as `$0.019` (3 decimal places)
- **Life** — formatted as `18%`
- **Notes** — include emoji flags (✅ BEST YEAR / ⚠️ CAUTION / 🚫 AVOID / ★ BEST PICK) and the specific reason

### How to Create the Sheet

**Step 1** — Build the CSV content as a Python string, then base64-encode it:

```python
import base64
csv_content = "Date,Make,Model,Year,Package,Miles,Cost,CPM,Life,Location,Dealer,Link,Notes\n"
# ... one row per listing, sorted by CPM ascending ...
encoded = base64.b64encode(csv_content.encode('utf-8')).decode('utf-8')
```

Run this via Bash to get the base64 string.

**Step 2** — Call `mcp__af7feda1-c109-4c1d-ad7b-0e864ed935d7__create_file` with:
```json
{
  "title": "Car Hunt Results — {Mon DD YYYY} ({makes/models})",
  "mimeType": "text/csv",
  "content": "{base64_encoded_csv}"
}
```

The Drive MCP auto-converts `text/csv` → Google Spreadsheet. No parentId needed — it lands in Drive root.

**Step 3** — The tool returns a file object with an `id`. Construct the share URL:
```
https://docs.google.com/spreadsheets/d/{id}/edit
```

Present this link to the user so they can open it immediately.

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
MAKES_MODELS: Civic, Accord, CR-V, Camry, Corolla, RAV4
ZIP:          35242
RADIUS:       200
MAX_PRICE:    (set by user)
YEAR_MIN:     (set by user)
YEAR_MAX:     current year
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
