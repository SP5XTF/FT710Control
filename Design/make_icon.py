"""Ikona FT-710 Control (oryginalna): gałka VFO na tle waterfallu, bursztynowa podziałka.
Siatka macOS: płótno 1024, płytka 824 przy (100,100), zaokrąglenie ~185."""
import math, random
random.seed(7)
W = 1024; X0 = 100; S = 824; R = 185; CX = 512; CY = 516
def heat(v):          # paleta waterfallu: granat → niebieski → cyjan → żółty → czerwony
    stops = [(0, (10, 22, 60)), (0.35, (30, 90, 200)), (0.6, (40, 200, 220)), (0.8, (255, 210, 70)), (1, (255, 80, 40))]
    for (a, ca), (b, cb) in zip(stops, stops[1:]):
        if v <= b:
            t = (v - a) / (b - a); return tuple(int(ca[i] + (cb[i] - ca[i]) * t) for i in range(3))
    return stops[-1][1]
parts = []
# tło waterfallu: drobne ziarno w odcieniach granatu i niebieskiego (bez filtrów - renderer ich nie obsługuje)
cell = 8
for gy in range(X0, X0 + S, cell):
    for gx in range(X0, X0 + S, cell):
        v = random.random() ** 2.4 * 0.40
        parts.append(f'<rect x="{gx}" y="{gy}" width="{cell}" height="{cell}" fill="rgb{heat(v)}"/>')
noise = "\n".join(parts)
# sygnały: każdy wiersz to poziomy gradient przezroczystości (miękkie brzegi), kolor płynnie zmienia się w pionie
streaks = [(0.20, 70, 0.78), (0.36, 34, 0.55), (0.70, 84, 0.98), (0.84, 36, 0.62)]
defs, sig = [], []
rows = 48
for k, (pos, width, power) in enumerate(streaks):
    cx = X0 + S * pos
    for r in range(rows):
        v = power * (0.62 + 0.38 * math.sin(r * 0.33 + k * 2.1) ** 2) * (0.92 + 0.08 * random.random())
        c = heat(v)
        gid = f"g{k}_{r}"
        defs.append(f'<linearGradient id="{gid}" x1="0" y1="0" x2="1" y2="0">'
                    f'<stop offset="0" stop-color="rgb{c}" stop-opacity="0"/>'
                    f'<stop offset="0.5" stop-color="rgb{c}" stop-opacity="0.95"/>'
                    f'<stop offset="1" stop-color="rgb{c}" stop-opacity="0"/></linearGradient>')
        y = X0 + S * r / rows
        sig.append(f'<rect x="{cx - width/2:.1f}" y="{y:.1f}" width="{width}" height="{S/rows + 0.8:.1f}" fill="url(#{gid})"/>')
streak_defs = "\n".join(defs)
waterfall = noise + "\n" + "\n".join(sig)
# podziałka wokół gałki (bursztynowa), co 10° z dłuższą co 30°
ticks = []
for i in range(36):
    a = math.radians(i * 10 - 90); long = i % 3 == 0
    r1, r2 = 286, 286 + (34 if long else 18)
    for extra, alpha in ((14, 0.10), (7, 0.18), (0, 0.95 if long else 0.6)):          # ręczna poświata
        ticks.append(f'<line x1="{CX + r1*math.cos(a):.1f}" y1="{CY + r1*math.sin(a):.1f}" x2="{CX + r2*math.cos(a):.1f}" y2="{CY + r2*math.sin(a):.1f}" '
                     f'stroke="#FFB347" stroke-width="{(10 if long else 6) + extra}" stroke-linecap="round" opacity="{alpha}"/>')
ticks = "\n".join(ticks)
# karbowanie brzegu gałki
knurl = "\n".join(
    f'<line x1="{CX + 222*math.cos(math.radians(a)):.1f}" y1="{CY + 222*math.sin(math.radians(a)):.1f}" '
    f'x2="{CX + 246*math.cos(math.radians(a)):.1f}" y2="{CY + 246*math.sin(math.radians(a)):.1f}" stroke="#20252c" stroke-width="5" opacity="0.55"/>'
    for a in range(0, 360, 6))
svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" viewBox="0 0 {W} {W}">
<defs>
{streak_defs}
  <clipPath id="tile"><rect x="{X0}" y="{X0}" width="{S}" height="{S}" rx="{R}" ry="{R}"/></clipPath>
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#16202E"/><stop offset="1" stop-color="#07090D"/>
  </linearGradient>
  <radialGradient id="vignette" cx="0.5" cy="0.5" r="0.62">
    <stop offset="0.45" stop-color="#000" stop-opacity="0"/><stop offset="1" stop-color="#000" stop-opacity="0.75"/>
  </radialGradient>
  <radialGradient id="metal" cx="0.38" cy="0.32" r="0.85">
    <stop offset="0" stop-color="#F4F6F8"/><stop offset="0.45" stop-color="#B9C0C8"/><stop offset="0.8" stop-color="#6E7680"/><stop offset="1" stop-color="#3C424A"/>
  </radialGradient>
  <radialGradient id="face" cx="0.42" cy="0.36" r="0.8">
    <stop offset="0" stop-color="#3A4049"/><stop offset="0.7" stop-color="#1B1F25"/><stop offset="1" stop-color="#0E1115"/>
  </radialGradient>
  <radialGradient id="dimple" cx="0.4" cy="0.35" r="0.7">
    <stop offset="0" stop-color="#0B0D10"/><stop offset="1" stop-color="#2A3038"/>
  </radialGradient>
  <filter id="glow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="6"/></filter>
  <filter id="soft" x="-100%" y="-5%" width="300%" height="110%"><feGaussianBlur stdDeviation="9 3"/></filter>
  <filter id="softer" x="-100%" y="-5%" width="300%" height="110%"><feGaussianBlur stdDeviation="3 2"/></filter>
  <filter id="grain"><feGaussianBlur stdDeviation="1.6"/></filter>
  <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%"><feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#000" flood-opacity="0.65"/></filter>
  <filter id="tileshadow" x="-10%" y="-10%" width="120%" height="125%"><feDropShadow dx="0" dy="14" stdDeviation="16" flood-color="#000" flood-opacity="0.35"/></filter>
</defs>
<g filter="url(#tileshadow)"><rect x="{X0}" y="{X0}" width="{S}" height="{S}" rx="{R}" ry="{R}" fill="url(#bg)"/></g>
<g clip-path="url(#tile)">
  {waterfall}
  <rect x="{X0}" y="{X0}" width="{S}" height="{S}" fill="url(#vignette)"/>
</g>
{ticks}
<circle cx="{CX}" cy="{CY + 16}" r="262" fill="#000" opacity="0.22"/>
<circle cx="{CX}" cy="{CY + 10}" r="252" fill="#000" opacity="0.30"/>
<circle cx="{CX}" cy="{CY}" r="246" fill="url(#metal)"/>
{knurl}
<circle cx="{CX}" cy="{CY}" r="208" fill="url(#face)"/>
<circle cx="{CX}" cy="{CY}" r="208" fill="none" stroke="#9AA3AD" stroke-width="3" opacity="0.5"/>
<!-- wgłębienie na palec + znacznik -->
<circle cx="{CX + 104}" cy="{CY + 88}" r="40" fill="url(#dimple)" opacity="0.55"/>
<circle cx="{CX}" cy="{CY - 176}" r="30" fill="#409EFF" opacity="0.15"/>
<circle cx="{CX}" cy="{CY - 176}" r="21" fill="#409EFF" opacity="0.35"/>
<circle cx="{CX}" cy="{CY - 176}" r="14" fill="#409EFF"/>
<circle cx="{CX - 3}" cy="{CY - 179}" r="6" fill="#D6EBFF"/>
<!-- połysk płytki -->
<rect x="{X0}" y="{X0}" width="{S}" height="{S}" rx="{R}" ry="{R}" fill="none" stroke="#FFFFFF" stroke-opacity="0.08" stroke-width="3"/>
</svg>'''
open("AppIcon.svg", "w").write(svg)
import cairosvg
cairosvg.svg2png(bytestring=svg.encode(), write_to="AppIcon_1024.png", output_width=1024, output_height=1024)
cairosvg.svg2png(bytestring=svg.encode(), write_to="preview_64.png", output_width=64, output_height=64)
print("ok")
