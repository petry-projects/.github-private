from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.enums import TA_LEFT
from reportlab.lib.colors import HexColor, black
from reportlab.lib.units import inch
from reportlab.platypus import SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak
from reportlab.platypus.flowables import HRFlowable

OUT = '/Users/dj/Downloads/car-hunt-checklist-2026-04-28-honda-accord-9855.pdf'

doc = SimpleDocTemplate(
    OUT, pagesize=letter,
    leftMargin=0.5*inch, rightMargin=0.5*inch,
    topMargin=0.4*inch, bottomMargin=0.4*inch,
    title='Car Hunt Test-Drive Checklist — 2008 Honda Accord EX-L (VIN ...9855)',
    author='car-hunt skill'
)

ss = getSampleStyleSheet()
header_style  = ParagraphStyle('header', parent=ss['Title'], fontSize=14, leading=17, spaceAfter=2, alignment=TA_LEFT, textColor=HexColor('#0a3d62'))
sub_style     = ParagraphStyle('sub', parent=ss['Normal'], fontSize=9, leading=11, textColor=HexColor('#333333'))
section_style = ParagraphStyle('section', parent=ss['Heading2'], fontSize=11, leading=13, spaceBefore=6, spaceAfter=2, textColor=HexColor('#0a3d62'))
item_style    = ParagraphStyle('item', parent=ss['Normal'], fontSize=8.5, leading=11, leftIndent=14, firstLineIndent=-12, spaceBefore=0, spaceAfter=0)
note_style    = ParagraphStyle('note', parent=ss['Normal'], fontSize=8, leading=10, leftIndent=14, textColor=HexColor('#555555'), spaceBefore=0, spaceAfter=2)

def section(title): return Paragraph(f'<b>{title}</b>', section_style)
def item(text):     return Paragraph(f'☐ {text}', item_style)
def note(text):     return Paragraph(text, note_style)
def hr():           return HRFlowable(width='100%', thickness=0.5, color=HexColor('#cccccc'), spaceBefore=2, spaceAfter=2)

story = []

# --- HEADER ---
story.append(Paragraph('Test-Drive Checklist — 2008 Honda Accord EX-L Sedan', header_style))
story.append(Paragraph(
    '<b>VIN:</b> 1HGCP26818A029855 &nbsp;·&nbsp; <b>Ask:</b> $4,000 &nbsp;·&nbsp; <b>Miles:</b> 160,000 &nbsp;·&nbsp; <b>CPM:</b> $0.044/mi &nbsp;·&nbsp; <b>Life used:</b> 64%<br/>'
    '<b>Seller:</b> Donald &nbsp;·&nbsp; <b>Location:</b> Birmingham, AL &nbsp;·&nbsp; '
    '<b>Listing:</b> facebook.com/marketplace/item/1460230412225566<br/>'
    '<b>Verified:</b> 0 unrepaired NHTSA recalls associated with this VIN (checked 2026-04-28)<br/>'
    '<b>Generated:</b> 2026-04-28 by car-hunt skill', sub_style))
story.append(hr())

# --- BEFORE YOU LEAVE ---
story.append(section('Before you leave the house'))
for t in [
    'Cash or cashier’s check ready &mdash; <b>target $3,500 / walk-away $3,800</b>',
    'Bill of sale form printed (Alabama: 2 copies, both signatures)',
    'Flashlight + magnet (paint/body filler check) + tire-tread gauge',
    'OBD-II scanner if you own one',
    'Phone fully charged for photos of damage, VIN, odometer',
    'Already texted Donald: <i>"Don’t run it before I get there — I want a cold start."</i>',
]:
    story.append(item(t))

# --- PAPER CHECKS ---
story.append(section('Paper checks (before keys turn)'))
for t in [
    'Title in Donald’s name &mdash; <b>clean Alabama title</b>, NOT marked Salvage / Rebuilt / Junk',
    'Title VIN matches dashboard VIN matches door-jamb sticker = <b>1HGCP26818A029855</b>',
    'Donald’s photo ID matches name on title',
    'Odometer on title matches dashboard reading (~160K)',
    'No active liens noted on title (listing says "paid off" — verify)',
]:
    story.append(item(t))
story.append(note('✅ Already verified: 0 unrepaired NHTSA recalls associated with this VIN.'))

# --- COLD START ---
story.append(section('Cold start (most important — only happens once)'))
for t in [
    'Hood up, key OFF: oil dipstick at <b>FULL</b> line, oil clean honey/light brown (NOT black)',
    'Coolant reservoir between MIN/MAX, no rust or oil sheen floating in it',
    'Brake fluid at MAX, light amber (not dark)',
    'Power steering fluid at MAX, not foamy or dark',
    'Transmission dipstick: <b>FULL, RED</b> &mdash; not brown, not burnt smell',
    'Now start it. <b>Watch the tailpipe</b> in the rearview mirror at first key-on:',
    '&nbsp;&nbsp;&nbsp;&nbsp;• No blue/white smoke (= oil burning, K24 piston rings worn)',
    '&nbsp;&nbsp;&nbsp;&nbsp;• No black smoke (= rich/fuel issue)',
    '&nbsp;&nbsp;&nbsp;&nbsp;• Smoke clears in 10s in cold weather, immediately in warm',
    '<b>LISTEN first 5 seconds &mdash; VTC actuator is the #1 K24 issue:</b>',
    '&nbsp;&nbsp;&nbsp;&nbsp;• No 1–2 second metallic rattle from top end (= $400–700 fix)',
    'All warning lights illuminate THEN extinguish within 5 seconds',
    'No CEL, ABS, SRS, or TCS lights stay on',
    'All gauges sweep and settle in normal range',
]:
    story.append(item(t))

# --- STATIC INSPECTION ---
story.append(section('Static inspection (engine off, ~5 min)'))
for t in [
    '<b>Bumper + headlight damage</b> (already disclosed) &mdash; you should already have a body-shop quote in hand',
    'Walk around: panel gaps even, paint matches across panels (rebuild signal)',
    'Magnet sticks to every steel body panel (no Bondo)',
    'Tire tread depth ≥ 4/32" all four (penny test: Lincoln’s head shows = bad)',
    'All four tires same brand & size, even wear (uneven = alignment/suspension)',
    'No rust on rocker panels or frame rails (flashlight UNDER the car)',
    'Check for fluid puddles where it was parked (oil, coolant, transmission)',
    'Open all 4 doors, hood, trunk — alignment, latches, weatherstripping intact',
    'All glass: no chips, cracks, or repair stars (windshield = $200–400)',
    'All exterior lights: low/high beam, brake (both sides), turn, reverse',
    '<b>AC: blows COLD at center vent within 60s at idle</b>',
    '<b>Heat: blows HOT at center vent within 90s</b>',
    'All 4 windows up/down without grinding (regulators are common failure)',
    'Power locks all 4 doors',
    'Driver’s seat slides/reclines, leather not torn (it’s an EX-L)',
    'Sunroof opens/closes (EX-L has it; common to fail)',
    'All seatbelts retract fully and lock when yanked',
    'No mildew/cigarette/pet smell (flood / heavy use signal)',
    'Trunk floor + spare tire well <b>DRY</b> (water damage check)',
]:
    story.append(item(t))

story.append(PageBreak())

# --- MODEL-SPECIFIC ---
story.append(Paragraph('Test-Drive Checklist (cont.) &mdash; 2008 Honda Accord EX-L, VIN ...9855', header_style))
story.append(hr())

story.append(section('Model-specific red flags (2008 Accord EX-L K24)'))
for t in [
    '<b>VTC actuator rattle</b> at cold start (covered above) — must be absent',
    '<b>Oil consumption (K24 issue):</b> ask Donald flat out &mdash; <i>"How often do you add oil between changes?"</i> &nbsp; Anything > 0 qt/1000 mi = walk',
    '<b>Pull dipstick AGAIN at end of test drive</b> &mdash; should still be at FULL',
    '<b>A/C compressor</b>: known weak point on 8th gen Accord. Listen for clutch click and pulley whine when AC engages',
    'Verify it’s the 2.4L 4-cyl K24 (per VIN decode) &mdash; NOT the V6 with the troubled 5AT',
    'Sunroof drains: press leather around the sunroof, look for water staining (clogged drains cause leaks)',
    'EX-L leather: check driver’s seat side bolster for excessive wear (gives away true mileage)',
]:
    story.append(item(t))

# --- TEST DRIVE ---
story.append(section('Test drive &mdash; minimum 15 min, mixed roads'))
for t in [
    'Driveway: smooth take-off from cold, no clunks from suspension',
    'Parking lot: tight figure-8 left and right, listen for CV joint clicks',
    'Reverse: 30+ feet straight back, no whine/grinding',
    'City stop-and-go: <b>smooth 1→2 and 2→3 shifts</b>, no flare or slip',
    'Hard brake from 30 mph (safe spot): straight stop, no pulsation, no pull',
    '45–55 mph cruise: no vibration in steering wheel (alignment/balance)',
    'Highway 65+ mph: no wandering, no death-wobble',
    '<b>Highway WOT to 70</b>: 5AT must downshift cleanly and hold without slip',
    'Windows down, stereo OFF: listen at every speed for whines, ticks, knocks',
    'Hot stop: park, leave running 2 min, look under for new leaks',
    'After drive: pop hood &mdash; coolant <b>NOT</b> boiling out of overflow (head gasket check)',
    'After drive: oil dipstick still at <b>FULL</b> (oil consumption check)',
]:
    story.append(item(t))

# --- NEGOTIATION TABLE ---
story.append(section('Negotiation levers (fill in during inspection)'))
neg_data = [
    ['Issue found', 'Deduction', 'Confirmed?'],
    ['Bumper + headlight repair (real shop quote)', '$________', '☐'],
    ['Tire tread <4/32"', '−$400', '☐'],
    ['AC weak / compressor noisy', '−$600 to −$1,200', '☐'],
    ['Brake pulsation', '−$200', '☐'],
    ['Battery >4 yrs old (date sticker)', '−$150', '☐'],
    ['Cracked windshield', '−$300', '☐'],
    ['Each warning light ON', '−$200', '☐'],
    ['Other:', '$________', '☐'],
    ['Total deductions', '$________', ''],
    ['My counter (→ $4,000 − deductions)', '$________', ''],
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

# --- RED FLAGS / WALK ---
story.append(section('⚠️ Red flags &mdash; if any of these, walk away'))
for t in [
    'Title not present at meeting (any reason)',
    'VIN on title ≠ dashboard or door',
    'Donald’s name not on title',
    'Engine smokes blue at any point (oil burning)',
    'Transmission flares or slips on test drive',
    'Any frame rail rust deeper than surface',
    'CEL on, "I don’t know what it means"',
    'Coolant in oil cap (mayonnaise) or oil in coolant (sheen)',
    'Recent paint on a single panel that doesn’t match',
    'Donald pressures: "decide now" / "two other people coming"',
]:
    story.append(item(t))

# --- AFTER YOU AGREE ---
story.append(section('After you agree to buy'))
for t in [
    'Sign <b>both copies</b> of bill of sale, both parties keep one',
    'Donald signs SELLER section of title only &mdash; <b>you don’t sign yet</b> (Alabama requires courthouse witness for buyer signature)',
    'Take photo of Donald’s driver’s license next to the title for records',
    'Pay only <b>after</b> both signatures and physical title in YOUR hand',
    'Get all keys (most cars have 2; ask for spares)',
    'Drive to courthouse same day or within 20 days (Alabama late fee accrues)',
]:
    story.append(item(t))

story.append(Spacer(1, 8))
story.append(Paragraph(
    '<i>Generated by the car-hunt skill on 2026-04-28. The single most important moment is the cold start with you watching the tailpipe and listening for VTC rattle &mdash; that 5 seconds tells you more than the next 30 minutes combined.</i>',
    note_style))

doc.build(story)
print(f'Wrote {OUT}')
