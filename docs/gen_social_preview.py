#!/usr/bin/env python3
"""Erzeugt das GitHub-Social-Preview-Bild für Fastra (1280x640 PNG).

Design: dunkler Verlauf, großes Wildcard-Sternchen als Markenmotiv,
Titel + Untertitel, Mono-Zeile mit Suchen-→-Ersetzen-Beispiel.
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

W, H = 1280, 640
ACCENT = (255, 159, 67)      # warmes Orange (Wildcard-Stern)
FG = (240, 241, 245)         # fast weiß
MUTED = (156, 163, 175)      # grau für Untertitel
MONO_FG = (140, 200, 255)    # helles Blau für Code

img = Image.new("RGB", (W, H))
px = img.load()

# Vertikaler Verlauf dunkelgrau -> fast schwarz
top, bottom = (36, 38, 46), (20, 21, 26)
for y in range(H):
    t = y / H
    r = int(top[0] + (bottom[0] - top[0]) * t)
    g = int(top[1] + (bottom[1] - top[1]) * t)
    b = int(top[2] + (bottom[2] - top[2]) * t)
    for x in range(W):
        px[x, y] = (r, g, b)

d = ImageDraw.Draw(img)

def font(path, size, index=0):
    return ImageFont.truetype(path, size, index=index)

SUP = "/System/Library/Fonts/Supplemental/"
f_title = font(SUP + "Arial Bold.ttf", 150)
f_sub = font(SUP + "Arial.ttf", 44)
f_mono = font("/System/Library/Fonts/Menlo.ttc", 40, index=1)  # Menlo Bold
f_small = font(SUP + "Arial.ttf", 30)

# Riesiges Wildcard-Sternchen rechts als Wasserzeichen-Motiv
f_star_big = font(SUP + "Arial Bold.ttf", 640)
d.text((880, -20), "*", font=f_star_big, fill=(255, 159, 67, 40))
# etwas abdunkeln, damit es wie ein Wasserzeichen wirkt: halbtransparentes Overlay
overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
od = ImageDraw.Draw(overlay)
od.text((880, -20), "*", font=f_star_big, fill=(255, 159, 67, 60))
img = Image.alpha_composite(img.convert("RGBA"), overlay)
d = ImageDraw.Draw(img)

# Titel + oranges Sternchen dahinter
d.text((90, 150), "Fastra", font=f_title, fill=FG)
w_title = d.textlength("Fastra", font=f_title)
d.text((90 + w_title + 18, 150), "*", font=f_title, fill=ACCENT)

# Untertitel — Positionierung: Editor zuerst, Suchen&Ersetzen als Superkraft
f_sub2 = font(SUP + "Arial.ttf", 37)
d.text((95, 330), "The native macOS text editor", font=f_sub, fill=FG)
d.text((95, 394), "unmatched find & replace:  *-wildcards  ·  regex  ·  diff preview", font=f_sub2, fill=MUTED)

# Mono-Beispielzeile in dezenter "Terminal-Box"
box_y = 490
d.rounded_rectangle([90, box_y, 700, box_y + 84], radius=14, fill=(28, 30, 37), outline=(60, 63, 74), width=2)
d.text((120, box_y + 20), "*, The", font=f_mono, fill=MONO_FG)
w1 = d.textlength("*, The", font=f_mono)
d.text((120 + w1 + 34, box_y + 20), "→", font=f_mono, fill=ACCENT)
w2 = d.textlength("→", font=f_mono)
d.text((120 + w1 + 34 + w2 + 34, box_y + 20), "The *", font=f_mono, fill=FG)
# Erklärung rechts neben der Box (außerhalb), dezent grau
d.text((730, box_y + 30), 'turns "Beatles, The" into "The Beatles"', font=f_small, fill=(110, 116, 128))

# Badge unten rechts
badge = "macOS  ·  Swift  ·  notarized"
wb = d.textlength(badge, font=f_small)
d.text((W - wb - 70, H - 70), badge, font=f_small, fill=MUTED)

out = Path(__file__).with_name("fastra-social-preview.png")
img.convert("RGB").save(out, "PNG")
print("OK:", out)
