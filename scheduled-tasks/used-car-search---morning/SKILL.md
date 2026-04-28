---
name: used-car-search---morning
description: Find the best used car deals
---

/car-hunt Honda Civic, Honda Accord, Acura TLX, Lexus ES250, Lexus ES350, Toyota Camry, Toyota Scion TC | 2002+ | ≤$6,000 | ZIP 35243 | 100mi radius | ≤225,000 miles | private sellers only

Skip Step 1 (reliability research already done). Search FB Marketplace only for listings posted in the last 24 hours.

For the active tracking sheet ID, read it from memory: `/Users/dj/.claude/projects/-Users-dj-repos-self/memory/project_car_hunt_skill.md` (do NOT hardcode a sheet ID — Drive MCP creates a new ID on each update, so memory is the source of truth). Compare against that sheet — only surface listings with Link URLs not already in it.

**Apply Location Quality Tier scoring (per SKILL.md Step 3 — Birmingham AL metro table).** Tag every candidate with its tier (A/B/C/D), compute Adj.CPM, and **prioritize Tier A and Tier B listings to the top of the run summary** even if their raw CPM is slightly worse than a Tier D candidate. When a Tier A or B listing surfaces (rare in this price band), explicitly call it out at the top of the report with: *"⭐ TIER A/B FIND — base-rate odds favor this listing; act fast."* Continue to surface and contact Tier C and D listings normally; tier is a ranking modifier, never a filter.

Then run Step 7: check message history, and for new listings send the outreach message below and mark Contacted in the sheet.

Use this message: " Hi -- we are interested!  Can I stop by today or tomorrow to test drive?  Looking for a replacement car for a 17yo foster kid that got rear ended.  Thanks!"