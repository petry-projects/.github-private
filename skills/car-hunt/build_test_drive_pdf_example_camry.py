from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.colors import HexColor
from reportlab.lib.units import inch
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak
from reportlab.platypus.flowables import HRFlowable

OUT = '/Users/dj/Downloads/car-hunt-checklist-2026-04-28-toyota-camry-TBD.pdf'

doc = SimpleDocTemplate(OUT, pagesize=letter,
    leftMargin=0.5*inch, rightMargin=0.5*inch,
    topMargin=0.4*inch, bottomMargin=0.4*inch,
    title='Car Hunt Test-Drive Checklist — 2011 Toyota Camry (VIN TBD)',
    author='car-hunt skill')

ss = getSampleStyleSheet()
header_style  = ParagraphStyle('header', parent=ss['Title'], fontSize=14, leading=17, spaceAfter=2, alignment=TA_LEFT, textColor=HexColor('#0a3d62'))
sub_style     = ParagraphStyle('sub', parent=ss['Normal'], fontSize=9, leading=11, textColor=HexColor('#333333'))
section_style = ParagraphStyle('section', parent=ss['Heading2'], fontSize=11, leading=13, spaceBefore=6, spaceAfter=2, textColor=HexColor('#0a3d62'))
item_style    = ParagraphStyle('item', parent=ss['Normal'], fontSize=8.5, leading=11, leftIndent=14, firstLineIndent=-12)
note_style    = ParagraphStyle('note', parent=ss['Normal'], fontSize=8, leading=10, leftIndent=14, textColor=HexColor('#555555'))
warn_style    = ParagraphStyle('warn', parent=ss['Normal'], fontSize=9, leading=11, leftIndent=8, textColor=HexColor('#a83232'))

def section(title): return Paragraph(f'<b>{title}</b>', section_style)
def item(text):     return Paragraph(f'☐ {text}', item_style)
def note(text):     return Paragraph(text, note_style)
def hr():           return HRFlowable(width='100%', thickness=0.5, color=HexColor('#cccccc'), spaceBefore=2, spaceAfter=2)

story = []
story.append(Paragraph('Test-Drive Checklist — 2011 Toyota Camry', header_style))
story.append(Paragraph(
    '<b>VIN:</b> TBD — get from Kevin before driving over &nbsp;·&nbsp; <b>Ask:</b> $3,300 &nbsp;·&nbsp; <b>Miles:</b> 192,000 &nbsp;·&nbsp; <b>CPM:</b> $0.031/mi &nbsp;·&nbsp; <b>Life used:</b> 64%<br/>'
    '<b>Seller:</b> Kevin (Hartkip Kevin per FB) &nbsp;·&nbsp; <b>Location:</b> Birmingham, AL &nbsp;·&nbsp; '
    '<b>Listing:</b> facebook.com/marketplace/item/2065946833961172<br/>'
    '<b>Posted:</b> 5 days ago &nbsp;·&nbsp; <b>Description (full):</b> <i>"Runs and drives smooth"</i> — that\'s the entire seller-provided info<br/>'
    '<b>Generated:</b> 2026-04-28 by car-hunt skill', sub_style))
story.append(hr())

# Critical context
story.append(section('⚠️ Critical context — why this car needs extra scrutiny'))
story.append(Paragraph(
    'This listing has <b>extreme information asymmetry</b> compared to the Accord: the seller wrote ONE sentence — '
    '"Runs and drives smooth" — and disclosed nothing about title status, owners, accidents, '
    'service history, or known issues. <b>2011 Camry is also a known caution year</b> due to the '
    '2AR-FE 2.5L engine\'s oil-consumption defect (2007–2011). Toyota issued TSB T-SB-0094-11 for piston-ring '
    'replacement; many owners never had it done. If this car burns oil, you will pay for it — repair is $2,000–$4,000.', warn_style))

# Before you leave
story.append(section('Before you leave the house'))
for t in [
    'Cash or cashier\'s check ready &mdash; <b>target $2,800 / walk-away $3,100</b>',
    'Bill of sale form printed (Alabama: 2 copies, both signatures)',
    'Flashlight + magnet (paint/body filler check) + tire-tread gauge',
    'OBD-II scanner if you own one (clears recent codes = red flag)',
    '<b>Get the VIN from Kevin BEFORE driving over.</b> Text: <i>"Can you send me the VIN before I drive over? Want to run a recall check."</i>',
    'Refusal to share VIN = <b>walk away now</b>. Most legit sellers share it.',
    'When you have the VIN, run NHTSA per-VIN unrepaired-recall check (10 sec). Open recalls = leverage or walk.',
    'Tell Kevin: <i>"Don\'t run it before I get there — I want to do a cold start."</i>',
]:
    story.append(item(t))

# Paper checks
story.append(section('Paper checks (before keys turn) — extra scrutiny here'))
for t in [
    '<b>Title in Kevin\'s name</b> — listing made no mention of title; verify in person',
    '<b>Title is clean</b>, NOT marked Salvage / Rebuilt / Junk / Flood / Lemon Law Buyback',
    'Title VIN matches dashboard VIN matches door-jamb sticker (write down all 3, compare digit-by-digit)',
    'Kevin\'s photo ID matches name on title — <b>if not, walk</b> (curbstoning or stolen-car red flag)',
    'Odometer on title matches dashboard reading (within 1000 mi). 192K written on listing, verify on metal',
    '<b>No active liens</b> noted on title. AL liens appear on the title face',
    'Title is original Alabama (or whatever state), not photocopied/scanned/laminated',
    'No erasures, white-out, ink mismatches, scratched-out fields',
    '<b>Run the VIN at NHTSA</b> (already done before arrival) — confirm 0 unrepaired recalls',
]:
    story.append(item(t))

story.append(note('Use the separate FRAUD PAPERWORK CHECKLIST for full verification — '
                  'this is the high-risk category for this listing given the lack of disclosure.'))

# Cold start - the Camry-specific oil consumption check
story.append(section('Cold start — THE CRITICAL TEST for this engine'))
for t in [
    'Hood up, key OFF: <b>oil dipstick at FULL line</b>, oil clean honey/light brown',
    '<b>If oil is at MIN or below — walk away.</b> Toyota 2AR-FE oil consumption is the dispositive issue',
    '<b>If oil is BLACK — walk.</b> Means it hasn\'t been changed in 10K+ miles, or it\'s burning fuel',
    'Coolant reservoir between MIN/MAX, no rust or oil sheen floating',
    'Brake fluid at MAX, light amber (not dark)',
    'Power steering fluid at MAX, not foamy',
    'Now start it. <b>Watch the tailpipe</b> in the rearview mirror at first key-on:',
    '&nbsp;&nbsp;&nbsp;&nbsp;• <b>BLUE/WHITE smoke = oil burning = piston rings shot.</b> Walk.',
    '&nbsp;&nbsp;&nbsp;&nbsp;• Black smoke = rich/fuel issue (less expensive but still a flag)',
    '<b>LISTEN first 5 seconds:</b>',
    '&nbsp;&nbsp;&nbsp;&nbsp;• No clattering / valve-train tap (= 2AR-FE oil starvation, ring problem beginning)',
    '&nbsp;&nbsp;&nbsp;&nbsp;• No knocking from bottom end (= rod knock, terminal)',
    'All warning lights illuminate THEN extinguish within 5 seconds',
    'No CEL, ABS, SRS, VSC, or TRAC lights stay on',
    'All gauges sweep and settle in normal range',
]:
    story.append(item(t))

# Static inspection
story.append(section('Static inspection (engine off, ~5 min)'))
for t in [
    'Walk around: panel gaps even, paint matches across panels (rebuild signal)',
    'Magnet sticks to every steel body panel (no Bondo)',
    'Tire tread depth ≥ 4/32" all four (penny test: Lincoln\'s head shows = bad)',
    'All four tires same brand & size, even wear',
    'No rust on rocker panels, frame rails (flashlight UNDER the car)',
    'Check for fluid puddles where it was parked (oil, coolant, transmission)',
    'Open all 4 doors, hood, trunk — alignment, latches, weatherstripping intact',
    'All glass: no chips, cracks, repair stars',
    'All exterior lights: low/high beam, brake (both sides), turn, reverse',
    '<b>AC: blows COLD at center vent within 60s at idle</b> (no listing claim — verify)',
    '<b>Heat: blows HOT at center vent within 90s</b>',
    'All 4 windows up/down without grinding',
    'Power locks all 4 doors',
    'Driver\'s seat slides/reclines, fabric/leather not torn',
    'All seatbelts retract fully and lock when yanked',
    'No mildew/cigarette/pet smell (flood / heavy use signal)',
    'Trunk floor + spare tire well <b>DRY</b> (water damage check)',
]:
    story.append(item(t))

story.append(PageBreak())
story.append(Paragraph('Test-Drive Checklist (cont.) — 2011 Toyota Camry', header_style))
story.append(hr())

# Model-specific
story.append(section('Model-specific red flags (2011 Camry — 2AR-FE engine)'))
for t in [
    '<b>OIL CONSUMPTION (the #1 issue):</b> ask Kevin flat out — <i>"How often do you add oil between changes?"</i>',
    '&nbsp;&nbsp;&nbsp;&nbsp;• Anything > 0 qt / 1,000 mi = active 2AR-FE problem. <b>Walk or deduct $3,000.</b>',
    '&nbsp;&nbsp;&nbsp;&nbsp;• Honest answer "I add a quart every couple of months" = the issue is here',
    '<b>Has the piston-ring TSB (T-SB-0094-11) been performed?</b> Ask. If yes, ask for paperwork.',
    '<b>Pull dipstick AGAIN at end of test drive</b> — must still be at FULL. Drop = burning oil.',
    '<b>2011 had 2 NHTSA recalls</b>: floor mat / accelerator (07V-372) and brake light switch (15V-321). NHTSA per-VIN check should show these as remedied.',
    'Rear strut top mount — clunk over bumps = $400 fix',
    'Rear stabilizer bar end-link rattle on test drive',
    'Trans fluid: should be CLEAR or pink-red, not brown or burnt smell',
    'Door-handle interior trim cracks (cosmetic, common)',
    'A/C amplifier failure (look for blower-only-on-MAX symptom on test drive)',
    'Sun visor sag/break (cosmetic, doesn\'t affect deal)',
]:
    story.append(item(t))

# Test drive
story.append(section('Test drive — minimum 15 min, mixed roads'))
for t in [
    'Driveway: smooth take-off from cold, no clunks',
    'Parking lot: tight figure-8 left and right, listen for CV joint clicks',
    'Reverse: 30+ feet straight back, no whine/grinding',
    'City stop-and-go: <b>smooth 1→2 and 2→3 shifts (6AT)</b>, no flare or slip',
    'Hard brake from 30 mph (safe spot): straight stop, no pulsation, no pull',
    '45–55 mph cruise: no steering vibration (alignment/balance)',
    'Highway 65+: no wandering',
    '<b>Highway WOT to 70</b>: 6AT must downshift cleanly and hold, no slip',
    'Windows down, stereo OFF: listen at every speed for whines, ticks, knocks',
    'Hot stop: park, leave running 2 min, look under for new leaks',
    'After drive: pop hood — coolant <b>NOT</b> boiling out of overflow (head gasket check)',
    'After drive: <b>oil dipstick still at FULL</b> (the dispositive test)',
]:
    story.append(item(t))

# Negotiation
story.append(section('Negotiation levers (fill in during inspection)'))
neg_data = [
    ['Issue found', 'Deduction', 'Confirmed?'],
    ['Oil consumption (any sign of it)', '−$2,000 to −$3,500', '☐'],
    ['Piston-ring TSB NOT done & no smoke', '−$1,000 (future risk)', '☐'],
    ['Tire tread <4/32"', '−$400', '☐'],
    ['AC weak / compressor noisy', '−$600 to −$1,200', '☐'],
    ['Brake pulsation', '−$200', '☐'],
    ['Battery >4 yrs old', '−$150', '☐'],
    ['Cracked windshield', '−$300', '☐'],
    ['Each warning light ON', '−$200', '☐'],
    ['Other:', '$________', '☐'],
    ['Total deductions', '$________', ''],
    ['My counter (→ $3,300 − deductions)', '$________', ''],
]
neg_tbl = Table(neg_data, colWidths=[3.6*inch, 1.7*inch, 1.0*inch])
neg_tbl.setStyle(TableStyle([
    ('FONTNAME', (0,0), (-1,0), 'Helvetica-Bold'),
    ('FONTSIZE', (0,0), (-1,-1), 8.5),
    ('BACKGROUND', (0,0), (-1,0), HexColor('#e8f0fa')),
    ('GRID', (0,0), (-1,-1), 0.4, HexColor('#999999')),
    ('VALIGN', (0,0), (-1,-1), 'MIDDLE'),
    ('LEFTPADDING', (0,0), (-1,-1), 5), ('RIGHTPADDING', (0,0), (-1,-1), 5),
    ('TOPPADDING', (0,0), (-1,-1), 3), ('BOTTOMPADDING', (0,0), (-1,-1), 3),
    ('FONTNAME', (0,-2), (-1,-1), 'Helvetica-Bold'),
    ('BACKGROUND', (0,-2), (-1,-1), HexColor('#fff4d6')),
]))
story.append(neg_tbl)

# Walk away
story.append(section('⚠️ Red flags — walk if any of these'))
for t in [
    '<b>Kevin refused to share the VIN</b> before you arrived',
    'Title not present at meeting (any reason)',
    'VIN on title ≠ dashboard or door',
    'Kevin\'s name not on title (the title is in someone else\'s name = curbstoning or theft)',
    '<b>Engine smokes blue at any point</b> (oil burning = $3,000+ fix)',
    '<b>Oil level at MIN or below on dipstick</b>',
    '<b>Oil dipstick drops between cold check and post-drive check</b> (active consumption)',
    'Transmission flares or slips on test drive',
    'Any frame rail rust deeper than surface',
    'CEL on, "I don\'t know what it means"',
    'Coolant in oil cap (mayonnaise) or oil in coolant (sheen)',
    'Recent paint on a single panel that doesn\'t match',
    'Kevin pressures: "decide now" / "two other people coming"',
    '<b>Description was 4 words</b> — make sure your gut feel matches what you see',
]:
    story.append(item(t))

# After purchase
story.append(section('After you agree to buy'))
for t in [
    'Sign <b>both copies</b> of bill of sale',
    'Kevin signs SELLER section of title only — <b>you don\'t sign yet</b> (Alabama courthouse witness rule)',
    'Take photo of Kevin\'s driver\'s license next to title',
    'Pay only after both signatures + physical title in YOUR hand',
    'Get all keys (most have 2; ask for spares)',
    'Drive to courthouse same day or within 20 days (AL late fee)',
]:
    story.append(item(t))

story.append(Spacer(1, 8))
story.append(Paragraph(
    '<i>Generated by the car-hunt skill on 2026-04-28. The single most important moment is the cold-start dipstick check '
    'and the post-drive dipstick check on this car. The 2AR-FE oil consumption issue is dispositive — if oil drops or there\'s '
    'any blue smoke, walk regardless of how nicely the car drives. Compared to the Accord (verified clean VIN, full disclosure), '
    'this car is the higher-risk option even at the better CPM.</i>', note_style))

doc.build(story)
print(f'Wrote {OUT}')
