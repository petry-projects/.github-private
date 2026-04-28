from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.colors import HexColor
from reportlab.lib.units import inch
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak
from reportlab.platypus.flowables import HRFlowable

OUT = '/Users/dj/Downloads/car-hunt-fraud-paperwork-checklist.pdf'

doc = SimpleDocTemplate(OUT, pagesize=letter,
    leftMargin=0.5*inch, rightMargin=0.5*inch,
    topMargin=0.4*inch, bottomMargin=0.4*inch,
    title='Car Hunt Fraud / Paperwork Checklist (private-party purchase)',
    author='car-hunt skill')

ss = getSampleStyleSheet()
header_style  = ParagraphStyle('header', parent=ss['Title'], fontSize=14, leading=17, spaceAfter=2, alignment=TA_LEFT, textColor=HexColor('#a83232'))
sub_style     = ParagraphStyle('sub', parent=ss['Normal'], fontSize=9, leading=11, textColor=HexColor('#333333'))
section_style = ParagraphStyle('section', parent=ss['Heading2'], fontSize=11, leading=13, spaceBefore=6, spaceAfter=2, textColor=HexColor('#a83232'))
item_style    = ParagraphStyle('item', parent=ss['Normal'], fontSize=8.5, leading=11, leftIndent=14, firstLineIndent=-12)
note_style    = ParagraphStyle('note', parent=ss['Normal'], fontSize=8, leading=10, leftIndent=14, textColor=HexColor('#555555'))
warn_style    = ParagraphStyle('warn', parent=ss['Normal'], fontSize=9, leading=11, leftIndent=8, textColor=HexColor('#a83232'))

def section(title): return Paragraph(f'<b>{title}</b>', section_style)
def item(text):     return Paragraph(f'☐ {text}', item_style)
def note(text):     return Paragraph(text, note_style)
def hr():           return HRFlowable(width='100%', thickness=0.5, color=HexColor('#cccccc'), spaceBefore=2, spaceAfter=2)

story = []
story.append(Paragraph('Fraud / Paperwork Verification Checklist', header_style))
story.append(Paragraph(
    'For private-party used-vehicle purchases &nbsp;·&nbsp; Run alongside the test-drive checklist<br/>'
    '<b>Use this checklist to detect:</b> title fraud · VIN fraud · curbstoning · stolen vehicles · '
    'odometer rollback · forged signatures · counterfeit payment · jumped titles<br/>'
    '<b>Rule of thumb:</b> if any single check fails and the seller can\'t resolve it on the spot, walk away. '
    'A real seller with clean paperwork answers cleanly. Pressure, hesitation, "trust me" responses = fraud signal.<br/>'
    '<b>Generated:</b> 2026-04-28 by car-hunt skill', sub_style))
story.append(hr())

# Big-picture warning
story.append(section('⚠️ Walk-away triggers (any single one — leave immediately)'))
for t in [
    'Seller refuses to share VIN before you arrive',
    'Title is not present at the meeting (any reason — "wife has it", "in the mail", "office")',
    'VIN on title doesn\'t match dashboard VIN doesn\'t match door-jamb sticker',
    'Seller\'s name on the title is not their name (with no chain-of-ownership paperwork)',
    'Title has erasures, scratch-outs, white-out, ink-color mismatches, or photocopied appearance',
    'Title is laminated (Alabama and most states do not laminate originals)',
    '<b>Title was issued in another state recently</b> AND seller can\'t explain why',
    'Title says "Salvage", "Rebuilt", "Junk", "Flood", "Lemon", "Reconstructed", or "Not Actual Mileage"',
    'Active lien noted on title with no lien-release letter',
    'Seller wants payment in cryptocurrency, gift cards, or wire transfer',
    'Seller asks you to sign a blank bill of sale or sign anything not in front of you',
    'Seller pressures you with "another buyer coming in 30 min" / "decide now"',
    'Seller doesn\'t have a photo ID, or ID doesn\'t match name on title',
    'Meeting location keeps changing or seller refuses to meet at their home',
]:
    story.append(item(t))

# Verify the title document
story.append(section('1. Title document — visual inspection'))
for t in [
    'Title is the <b>original</b> physical document — not a photocopy, scan, or laminated reprint',
    'Watermarks/security features visible (most states use intaglio printing, microprint, color-shifting ink)',
    'Title number and form number printed clearly, not blurry or pixelated',
    'No erasures or white-out anywhere',
    'No mismatched ink colors (one color throughout, except for stamps/seals)',
    'No "Reconstructed", "Salvage", "Rebuilt", "Junk", "Flood", "Lemon", "Total Loss", "Not Actual Mileage" markings',
    'Brand-history field, if shown, is clean (e.g., AL: blank, no boxed brands)',
    'Issued date on title is not in the future or impossibly recent (signal of recent washing)',
    'Title was issued in the same state as where you\'re meeting — or you have a story for the variance',
    'Owner name printed by the state, not handwritten — handwritten owner name = fake',
    'Odometer-reading field on title is filled in (not blank or "EXEMPT" unless 10+ year exempt)',
]:
    story.append(item(t))

# VIN verification
story.append(section('2. VIN verification — all three locations must match'))
for t in [
    '<b>Dashboard VIN</b> (visible through windshield, driver side): write it down digit-by-digit',
    '<b>Door-jamb sticker VIN</b> (driver door, b-pillar): write it down — must match dashboard exactly',
    '<b>Title VIN</b>: write it down — must match the other two',
    'Beware easy-to-confuse characters: 0 vs O, 1 vs I vs L, 5 vs S, 2 vs Z, 8 vs B',
    '<b>VIN must be 17 characters</b> (post-1981 vehicles). Shorter or longer = fraud or pre-\'81 antique',
    '<b>Door VIN sticker is intact</b> — not peeled, replaced, scuffed, or showing fresh adhesive',
    'Dashboard VIN plate shows no rivets that look new/different from neighboring panels',
    'No paint overspray on either VIN plate (rebuild signal)',
    'Run NHTSA decode on the VIN: <b>vpic.nhtsa.dot.gov/api/vehicles/decodevin/{VIN}?format=json</b> — confirms make/model/year/trim',
    'Decoded year/make/model/trim/engine MATCHES the listing description and the car in front of you',
    'NHTSA per-VIN check: <b>nhtsa.gov/recalls?vin={VIN}</b> — note any unrepaired recalls (free dealer fix)',
    'NICB theft check: <b>nicb.org/vincheck</b> — must show "no records found" for theft and salvage',
    'Optional NMVTIS report (~$3): vehiclehistory.com — confirms title-brand history nationwide',
]:
    story.append(item(t))

# Curbstoning detection
story.append(section('3. Curbstoning detection (unlicensed dealer pretending to be private)'))
for t in [
    '<b>Title is in the seller\'s name and registered to them</b> for at least 30+ days (curbstoners "title-jump")',
    'Seller\'s photo ID name and address match the title exactly',
    'Seller can describe owning history in detail: where they bought it, when, why selling',
    'Seller has insurance card / registration in their name',
    'Listing photos are personal (driveway, garage) not parking-lot or curbside',
    'Seller doesn\'t have multiple cars listed under the same FB profile or phone number',
    'Reverse-image-search the listing photos — if they appear on dealer auctions or other listings, it\'s curbstoning',
    'Phone number area code matches the local market (out-of-state = caution)',
    'Meeting at seller\'s home, not a parking lot / convenience store',
    'No "stock number", "VIN tag", "dealer pricing" language anywhere in description or signage on the car',
]:
    story.append(item(t))

# Odometer fraud
story.append(section('4. Odometer fraud detection'))
for t in [
    'Title odometer reading (Alabama: printed in box, signed by seller) matches the dashboard reading within ~1,000 mi',
    'No "Not Actual Mileage" or "Exceeds Mechanical Limits" notation on title',
    'Wear consistent with claimed miles:',
    '&nbsp;&nbsp;&nbsp;&nbsp;• Driver\'s seat side bolster (high-wear if 150K+)',
    '&nbsp;&nbsp;&nbsp;&nbsp;• Steering wheel finish wear',
    '&nbsp;&nbsp;&nbsp;&nbsp;• Pedal rubber — heavily worn pedals on 50K-claimed car = rolled back',
    '&nbsp;&nbsp;&nbsp;&nbsp;• Door-handle interior wear',
    '&nbsp;&nbsp;&nbsp;&nbsp;• Carpet wear under driver\'s feet',
    'Service stickers on windshield/door-jamb show consistent recent miles trail',
    'Oil-change sticker on windshield: date and miles consistent with current odometer',
    'Cluster screws look factory (not scratched/replaced)',
    'No mismatch between dashboard miles and what the listing claimed',
    'OBD-II scan shows odometer reading matches (some scanners pull ECU-stored mileage)',
]:
    story.append(item(t))

story.append(PageBreak())
story.append(Paragraph('Fraud / Paperwork Checklist (cont.)', header_style))
story.append(hr())

# Bill of sale
story.append(section('5. Bill of sale — both parties must complete and keep copy'))
for t in [
    '<b>Two identical copies</b>, both fully filled in with handwritten ink',
    'Date of sale (today\'s date — never backdate, IRS/tax fraud)',
    'Buyer\'s full legal name and address (yours)',
    'Seller\'s full legal name and address (matches their ID)',
    'Vehicle: year, make, model, body style, color',
    'VIN (full 17 characters)',
    'Odometer reading at time of sale',
    'Sale price (the actual amount — never under-report; tax fraud)',
    '"AS-IS, WHERE-IS, WITH ALL FAULTS" language to disclaim seller warranty',
    'Both parties sign and date both copies',
    'Each party keeps one fully-signed copy',
    'Photo of seller\'s ID next to the bill of sale, with VIN visible',
    '(Alabama specific) Notarization not required for bill of sale, but is for title transfer at courthouse',
]:
    story.append(item(t))

# Title transfer
story.append(section('6. Title transfer mechanics (Alabama-specific — adapt for other states)'))
for t in [
    'Seller signs <b>SELLER section only</b> in your presence',
    'Seller fills in odometer reading on title in your presence',
    'Seller fills in sale price (if title has that field)',
    '<b>Buyer DOES NOT sign anything on the title yet</b> — Alabama requires courthouse witness',
    'You take the original title with you (not a copy)',
    'You drive to the county probate / license office within 20 days of sale',
    'Late registration in AL = $15 penalty per 30 days late',
    'Bring: signed title, bill of sale, your ID, proof of insurance, payment for title fee + sales tax (~2% in most AL counties)',
    'Get a temporary tag if you\'re driving home far (most stores will print one for $2)',
]:
    story.append(item(t))

# Payment
story.append(section('7. Payment — protecting yourself from fake-money fraud'))
for t in [
    'Pay <b>only after</b> both signatures + physical title in YOUR hand + keys in YOUR hand',
    'Cash: count it in front of seller; use a counterfeit-detector pen ($3 at office stores) on $100s',
    'Cashier\'s check: <b>only if you wrote it from your bank</b> for this purchase. Never accept a "cashier\'s check" from the seller',
    'Bank-to-bank transfer: meet at one of your banks; have the teller witness',
    'Never pay via wire transfer to a remote bank you can\'t see',
    'Never pay in cryptocurrency, gift cards, or store credit',
    'Never pay a "deposit" before you\'ve seen the car and the title',
    'Don\'t bring more cash than the agreed sale price — leave excess in a bank or hidden in the car',
    'Get a written receipt: "$X received in full, vehicle title transferred, signed, dated"',
]:
    story.append(item(t))

# Stolen vehicle
story.append(section('8. Stolen-vehicle detection'))
for t in [
    'NICB VINCheck (free): no theft records',
    'Dashboard ignition: no signs of forced entry, no shaved key, no broken steering column',
    'Door-lock cylinders intact (no drilled holes or scratched faceplates)',
    'Trunk lock cylinder intact',
    'Glove box not damaged, registration matches title and seller',
    'Service records (if any) show consistent owner name',
    'Insurance card name matches title',
    'License plate registered to seller (run AL plate via DMV if uncertain)',
    'Run a quick Google search of the VIN — sometimes stolen-car databases or auction listings show up',
    'If anything feels off, ask seller to follow you to a police station (real sellers will; thieves won\'t)',
]:
    story.append(item(t))

# Title jumping (intermediate buyer never registered)
story.append(section('9. Title-jumping detection (illegal in all 50 states)'))
for t in [
    '<b>Seller\'s name appears as the BUYER on the title</b> (not the prior seller)',
    'If title shows previous owner\'s signature in the seller field but no current registration to seller = title was jumped',
    'Title-jumping makes you the registered "buyer" of a vehicle the prior owner doesn\'t know was sold; you inherit any liens, tickets, accidents during the gap',
    'Walk away from any title where seller is not the registered owner',
    'Exception: estate sale with executor paperwork — verify the death certificate and probate court order',
]:
    story.append(item(t))

# After purchase
story.append(section('10. After-purchase verification (within 7 days)'))
for t in [
    'Take the title + bill of sale to the county probate office and register the car in YOUR name',
    'Get new license plate (or transfer existing) and registration card',
    'Update insurance policy with new VIN and effective date matching purchase date',
    'Take the car to a trusted mechanic for an independent post-purchase inspection ($75-100)',
    'If the mechanic finds undisclosed major issues, you may have lemon-law / fraud recourse',
    'Save: bill of sale, photo of seller\'s ID, NHTSA recall result, your inspection notes — for at least 3 years',
]:
    story.append(item(t))

story.append(Spacer(1, 8))
story.append(Paragraph(
    '<i>This checklist exists because used-car fraud is a multi-billion-dollar industry. Most private sellers are honest, '
    'but a small minority can cost you the entire purchase price plus thousands in liens or stolen-vehicle recovery. '
    'The whole inspection takes ~20 minutes. The single most protective habit: <b>walk away if anything feels off.</b> '
    'There will be another car. Generated 2026-04-28 by car-hunt skill.</i>', note_style))

doc.build(story)
print(f'Wrote {OUT}')
