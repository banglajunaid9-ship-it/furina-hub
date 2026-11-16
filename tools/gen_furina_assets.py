"""
Builds the FurinaUI asset pack and embeds it into furina_ui.luau (between BEGIN/END ASSETS).

Images: emblem, tab/UI icons, a soft radial glow, a 9-slice shadow and a tiling water wave (PNG).
Sounds: short synthesized water clicks (8-bit 16 kHz WAV, tiny).
The script writes them to the executor workspace and loads them with getcustomasset.

Run:  python tools/gen_furina_assets.py
"""
import base64
import hashlib
import io
import math
import re
import struct
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
LUA = ROOT / "furina_ui.luau"
SS = 4  # supersampling factor


def png_bytes(img):
    buf = io.BytesIO()
    img.save(buf, format="PNG", optimize=True)
    return buf.getvalue()


# ---------------------------------------------------------------- geometry helpers
def cubic(p0, p1, p2, p3, n=24):
    pts = []
    for i in range(n + 1):
        t = i / n
        mt = 1 - t
        x = mt**3 * p0[0] + 3 * mt * mt * t * p1[0] + 3 * mt * t * t * p2[0] + t**3 * p3[0]
        y = mt**3 * p0[1] + 3 * mt * mt * t * p1[1] + 3 * mt * t * t * p2[1] + t**3 * p3[1]
        pts.append((x, y))
    return pts


def arc(cx, cy, r, a0, a1, n=24):
    return [(cx + r * math.cos(math.radians(a0 + (a1 - a0) * i / n)), cy + r * math.sin(math.radians(a0 + (a1 - a0) * i / n))) for i in range(n + 1)]


class Icon:
    """Draws on a 24-unit grid (like the SVG icons in the preview) at 4x, then downsamples."""

    def __init__(self, size=64, stroke=2.0):
        self.size = size
        self.k = size * SS / 24
        self.img = Image.new("L", (size * SS, size * SS), 0)
        self.d = ImageDraw.Draw(self.img)
        self.w = stroke * self.k

    def P(self, p):
        return (p[0] * self.k, p[1] * self.k)

    def line(self, pts, w=None, fill=255):
        w = self.w if w is None else w * self.k
        pts = [self.P(p) for p in pts]
        self.d.line(pts, fill=fill, width=int(round(w)))
        r = w / 2
        for x, y in pts:
            self.d.ellipse((x - r, y - r, x + r, y + r), fill=fill)

    def circle(self, c, r, w=None):
        w = self.w if w is None else w * self.k
        x, y = self.P(c)
        R = r * self.k
        self.d.ellipse((x - R - w / 2, y - R - w / 2, x + R + w / 2, y + R + w / 2), fill=255)
        self.d.ellipse((x - R + w / 2, y - R + w / 2, x + R - w / 2, y + R - w / 2), fill=0)

    def disc(self, c, r, fill=255):
        x, y = self.P(c)
        R = r * self.k
        self.d.ellipse((x - R, y - R, x + R, y + R), fill=fill)

    def poly(self, pts, fill=255):
        self.d.polygon([self.P(p) for p in pts], fill=fill)

    def rrect(self, box, radius, w=None, fill=False):
        x0, y0, x1, y1 = [v * self.k for v in box]
        r = radius * self.k
        if fill:
            self.d.rounded_rectangle((x0, y0, x1, y1), radius=r, fill=255)
            return
        w = self.w if w is None else w * self.k
        self.d.rounded_rectangle((x0 - w / 2, y0 - w / 2, x1 + w / 2, y1 + w / 2), radius=r + w / 2, fill=255)
        self.d.rounded_rectangle((x0 + w / 2, y0 + w / 2, x1 - w / 2, y1 - w / 2), radius=max(1, r - w / 2), fill=0)

    def arcln(self, cx, cy, r, a0, a1, w=None, n=24):
        self.line(arc(cx, cy, r, a0, a1, n), w=w)

    def done(self, cozy=True):
        src = self.img
        if cozy:
            # soften: blur + re-threshold rounds every sharp corner (stars, bolts, arrow tips) into a pillowy edge
            u = self.k  # px per grid unit at supersampled size
            b = np.asarray(src.filter(ImageFilter.GaussianBlur(0.7 * u)), dtype=np.float32) / 255
            core = np.clip((b - 0.5) * 3.2 + 0.5, 0, 1)
            # faint warm halo hugging the stroke, so tinted icons read as gently glowing rather than etched
            halo = np.asarray(Image.fromarray((core * 255).astype("uint8")).filter(ImageFilter.GaussianBlur(1.3 * u)), dtype=np.float32) / 255
            src = Image.fromarray((np.maximum(core, halo * 0.34) * 255).astype("uint8"))
        a = src.resize((self.size, self.size), Image.LANCZOS)
        # 16 alpha levels: invisible at menu size, and the PNGs shrink ~half (smaller than the hard-edged originals)
        q = np.asarray(a, dtype=np.float32)
        a = Image.fromarray((np.round(q / 255 * 15) * 17).astype("uint8"))
        out = Image.new("RGBA", a.size, (255, 255, 255, 0))
        out.putalpha(a)
        return out


def icon_home(i):
    i.line([(3, 11), (12, 3), (21, 11)])
    i.line([(5, 10), (5, 20), (19, 20), (19, 10)])


def icon_combat(i):
    i.line([(14.5, 17.5), (3, 6), (3, 3), (6, 3), (17.5, 14.5)])
    i.line([(13, 19), (19, 13)])
    i.line([(16, 16), (20, 20)])
    i.line([(19, 21), (21, 19)])
    i.line([(14.5, 6.5), (18, 3), (21, 3), (21, 6), (17.5, 9.5)])
    i.line([(5, 14), (9, 18)])
    i.line([(7, 17), (4, 20)])
    i.line([(3, 19), (5, 21)])


def icon_esp(i):
    top = [(x, 12 - 7 * math.sin(math.pi * (x - 2) / 20)) for x in np.linspace(2, 22, 40)]
    bot = [(x, 12 + 7 * math.sin(math.pi * (x - 2) / 20)) for x in np.linspace(2, 22, 40)]
    i.line(top)
    i.line(bot)
    i.circle((12, 12), 3)


def icon_power(i):
    i.line([(13, 2), (3, 14), (12, 14), (11, 22), (21, 10), (12, 10), (13, 2)])


def icon_hitbox(i):
    i.circle((12, 12), 9)
    i.circle((12, 12), 4)
    for a, b in [((12, 1), (12, 4)), ((12, 20), (12, 23)), ((1, 12), (4, 12)), ((20, 12), (23, 12))]:
        i.line([a, b])


def icon_luck(i):
    w = i.w
    x0, y0, x1, y1 = [v * i.k for v in (3, 3, 21, 21)]
    r = 4 * i.k
    i.d.rounded_rectangle((x0 - w / 2, y0 - w / 2, x1 + w / 2, y1 + w / 2), radius=r + w / 2, fill=255)
    i.d.rounded_rectangle((x0 + w / 2, y0 + w / 2, x1 - w / 2, y1 - w / 2), radius=max(1, r - w / 2), fill=0)
    for c in [(8.5, 8.5), (15.5, 15.5), (12, 12), (15.5, 8.5), (8.5, 15.5)]:
        i.disc(c, 1.35)


def icon_sun(i):
    i.circle((12, 12), 4)
    for a, b in [((12, 2), (12, 4)), ((12, 20), (12, 22)), ((4.9, 4.9), (6.3, 6.3)), ((17.7, 17.7), (19.1, 19.1)), ((2, 12), (4, 12)),
                 ((20, 12), (22, 12)), ((4.9, 19.1), (6.3, 17.7)), ((17.7, 6.3), (19.1, 4.9))]:
        i.line([a, b])


def icon_move(i):
    i.line([(2, 12), (19.5, 12)] + arc(19.5, 9.5, 2.5, 90, -135))
    i.line([(2, 8), (11, 8)] + arc(11, 6, 2, 90, -135))
    i.line([(2, 16), (14, 16)] + arc(14, 18, 2, -90, 135))


def icon_misc(i):
    for a, b in [((4, 21), (4, 14)), ((4, 10), (4, 3)), ((12, 21), (12, 12)), ((12, 8), (12, 3)), ((20, 21), (20, 16)), ((20, 12), (20, 3)),
                 ((1, 14), (7, 14)), ((9, 8), (15, 8)), ((17, 16), (23, 16))]:
        i.line([a, b])


def icon_gear(i):
    i.circle((12, 12), 3)
    i.circle((12, 12), 7)
    for n in range(8):
        a = math.radians(n * 45)
        i.line([(12 + 7.5 * math.cos(a), 12 + 7.5 * math.sin(a)), (12 + 10 * math.cos(a), 12 + 10 * math.sin(a))], w=3)


def icon_search(i):
    i.circle((11, 11), 7, w=2.4)
    i.line([(20, 20), (16.2, 16.2)], w=2.4)


def icon_x(i):
    i.line([(6, 6), (18, 18)], w=2.6)
    i.line([(18, 6), (6, 18)], w=2.6)


def icon_minus(i):
    i.line([(5, 12), (19, 12)], w=2.6)


def icon_arrow(i):
    i.line([(5, 12), (19, 12)], w=2.4)
    i.line([(13, 6), (19, 12), (13, 18)], w=2.4)


def icon_check(i):
    i.line([(5, 12.5), (9.5, 17), (19, 7.5)], w=3)


def icon_chevron(i):
    i.line([(6, 9), (12, 15), (18, 9)], w=2.4)


def icon_star(i):
    pts = []
    for n in range(10):
        r = 10 if n % 2 == 0 else 4.2
        a = math.radians(-90 + n * 36)
        pts.append((12 + r * math.cos(a), 12.6 + r * math.sin(a)))
    i.poly(pts)


def icon_moon(i):
    i.disc((12, 12), 8.5)
    i.disc((16.2, 8.2), 7.2, fill=0)


def icon_info(i):
    i.circle((12, 12), 9)
    i.line([(12, 11), (12, 16.5)], w=2.2)
    i.disc((12, 7.8), 1.3)


# ---- extra icons (lucide-style) ----
def icon_eye(i):
    icon_esp(i)


def icon_zap(i):
    i.poly([(13, 2), (4, 13.5), (10.5, 13.5), (9.5, 22), (19, 9.5), (12.5, 9.5)])


def icon_swords(i):
    i.line([(14.5, 17.5), (3, 6), (3, 3), (6, 3), (17.5, 14.5)], w=2.2)
    i.line([(13, 19), (16, 16)], w=2.2)
    i.line([(19, 21), (21, 19)], w=2.2)
    i.line([(14.5, 6.5), (18, 3), (21, 3), (21, 6), (17.5, 9.5)], w=2.2)
    i.line([(5, 14), (9, 18)], w=2.2)
    i.line([(7, 17), (4, 20)], w=2.2)
    i.line([(3, 19), (5, 21)], w=2.2)


def icon_user(i):
    i.circle((12, 8), 4, w=2.1)
    i.line(arc(12, 20.5, 7, 200, 340), w=2.1)


def icon_users(i):
    i.circle((9, 8.5), 3.3, w=1.9)
    i.line(arc(9, 20, 6, 205, 335), w=1.9)
    i.arcln(16, 8.5, 3.3, -60, 60, w=1.9)
    i.line(arc(17.5, 19.5, 5.5, 250, 340), w=1.9)


def icon_package(i):
    i.line([(12, 2.5), (20.5, 7), (20.5, 17), (12, 21.5), (3.5, 17), (3.5, 7), (12, 2.5)], w=2.0)
    i.line([(3.5, 7), (12, 11.5), (20.5, 7)], w=2.0)
    i.line([(12, 11.5), (12, 21.5)], w=2.0)
    i.line([(7.75, 4.75), (16.25, 9.25)], w=1.6)


def icon_map_pin(i):
    i.line(cubic((12, 22), (12, 22), (20, 13.5), (20, 9), 16) + arc(12, 9, 8, 0, -180, 24)[1:] + cubic((4, 9), (4, 13.5), (12, 22), (12, 22), 16)[1:], w=2.0)
    i.circle((12, 9), 2.6, w=1.8)


def icon_bell(i):
    i.line(cubic((6, 17), (6, 11), (6.5, 7.5), (12, 7.5), 18) + cubic((12, 7.5), (17.5, 7.5), (18, 11), (18, 17), 18)[1:], w=2.0)
    i.line([(4.5, 17), (19.5, 17)], w=2.0)
    i.line([(12, 5), (12, 7.5)], w=2.0)
    i.arcln(12, 18.5, 2.2, 20, 160, w=1.9)


def icon_shield(i):
    i.line([(12, 2.5), (20, 5.5), (20, 11), (12, 21.5), (4, 11), (4, 5.5), (12, 2.5)], w=2.0)


def icon_crosshair(i):
    i.circle((12, 12), 8, w=2.0)
    for a, b in [((12, 1.5), (12, 5)), ((12, 19), (12, 22.5)), ((1.5, 12), (5, 12)), ((19, 12), (22.5, 12))]:
        i.line([a, b], w=2.0)
    i.disc((12, 12), 1.4)


def icon_target(i):
    i.circle((12, 12), 9, w=2.0)
    i.circle((12, 12), 5, w=2.0)
    i.disc((12, 12), 1.8)


def icon_flame(i):
    i.line(cubic((12, 2.5), (14, 6), (19, 9.5), (19, 14.5), 18) + arc(12, 14.5, 7, 0, 180, 26)[1:]
           + cubic((5, 14.5), (5, 11), (6.5, 9), (8.5, 7.5), 12)[1:] + cubic((8.5, 7.5), (8.5, 10), (10, 11), (11, 10.5), 10)[1:]
           + cubic((11, 10.5), (12.5, 8.5), (11, 5), (12, 2.5), 12)[1:], w=2.0)
    i.line(cubic((12, 12.8), (14, 14.6), (14.5, 15.6), (14.5, 16.8), 10) + arc(12, 16.8, 2.5, 0, 180, 14)[1:]
           + cubic((9.5, 16.8), (9.5, 15.6), (10, 14.6), (12, 12.8), 10)[1:], w=1.7)


def icon_droplet(i):
    i.line(cubic((12, 2.5), (18, 10), (20, 14), (20, 16.5), 18) + arc(12, 16.5, 8, 0, 180, 26)[1:] + cubic((4, 16.5), (4, 14), (6, 10), (12, 2.5), 18)[1:], w=2.0)


def icon_snowflake(i):
    for a in (0, 60, 120):
        ra = math.radians(a)
        dx, dy = 9 * math.cos(ra), 9 * math.sin(ra)
        i.line([(12 - dx, 12 - dy), (12 + dx, 12 + dy)], w=1.8)
    for a in (0, 60, 120, 180, 240, 300):
        ra = math.radians(a)
        bx, by = 12 + 6 * math.cos(ra), 12 + 6 * math.sin(ra)
        for da in (-35, 35):
            r2 = math.radians(a + 180 + da)
            i.line([(bx, by), (bx + 3 * math.cos(r2), by + 3 * math.sin(r2))], w=1.6)


def icon_crown(i):
    i.line([(3, 8), (7, 16), (12, 6), (17, 16), (21, 8), (19, 19), (5, 19), (3, 8)], w=2.0)
    for cx, cy in ((3, 8), (12, 6), (21, 8)):
        i.disc((cx, cy), 1.4)


def icon_sparkles(i):
    def star(cx, cy, r):
        i.poly([(cx, cy - r), (cx + r * 0.32, cy - r * 0.32), (cx + r, cy), (cx + r * 0.32, cy + r * 0.32),
                (cx, cy + r), (cx - r * 0.32, cy + r * 0.32), (cx - r, cy), (cx - r * 0.32, cy - r * 0.32)])
    star(10, 10, 6)
    star(18, 17, 3.2)
    star(18.5, 6, 2.2)


def icon_heart(i):
    pts = []
    for n in range(73):
        t = 2 * math.pi * n / 72
        x = 16 * math.sin(t) ** 3
        y = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
        pts.append((12 + x * 0.56, 11.2 - y * 0.56))
    i.poly(pts)


def icon_lock(i):
    i.rrect((5, 11, 19, 20.5), 2.4)
    i.arcln(12, 11, 4.2, 180, 360, w=2.0)
    i.disc((12, 15), 1.3)
    i.line([(12, 15), (12, 17.5)], w=1.8)


def icon_trash(i):
    i.line([(4, 6.5), (20, 6.5)], w=2.0)
    i.line([(9, 6.5), (9.5, 4), (14.5, 4), (15, 6.5)], w=1.8)
    i.line([(6, 6.5), (7, 20.5), (17, 20.5), (18, 6.5)], w=2.0)
    for x in (10, 12, 14):
        i.line([(x, 10), (x, 17)], w=1.5)


def icon_refresh(i):
    i.line(arc(12, 12, 8, -50, 200), w=2.0)
    i.line([(4.2, 7.5), (4, 12), (8.5, 11.5)], w=2.0)
    i.line(arc(12, 12, 8, 130, 380), w=2.0)
    i.line([(19.8, 16.5), (20, 12), (15.5, 12.5)], w=2.0)


def icon_download(i):
    i.line([(12, 3), (12, 15)], w=2.0)
    i.line([(7, 10.5), (12, 15.5), (17, 10.5)], w=2.0)
    i.line([(4.5, 20), (19.5, 20)], w=2.0)


def icon_play(i):
    i.poly([(8, 5), (8, 19), (19, 12)])


def icon_pause(i):
    i.rrect((8, 5, 11, 19), 1.2, fill=True)
    i.rrect((13, 5, 16, 19), 1.2, fill=True)


def icon_folder(i):
    i.line([(3.5, 6.5), (9.5, 6.5), (11.5, 9), (20.5, 9), (20.5, 19), (3.5, 19), (3.5, 6.5)], w=2.0)


def icon_wifi(i):
    i.arcln(12, 18, 10.5, -140, -40, w=2.0)
    i.arcln(12, 18, 7, -135, -45, w=2.0)
    i.arcln(12, 18, 3.5, -125, -55, w=2.0)
    i.disc((12, 18), 1.4)


def icon_gauge(i):
    i.arcln(12, 14, 8.5, 180, 360, w=2.0)
    i.line([(12, 14), (16, 9.5)], w=2.0)
    i.disc((12, 14), 1.5)


def icon_globe(i):
    i.circle((12, 12), 9, w=1.9)
    i.line([(3, 12), (21, 12)], w=1.6)
    i.line([(12, 3), (12, 21)], w=1.6)
    i.line([(12 + 5 * math.sin(math.radians(a)), 12 - 9 * math.cos(math.radians(a))) for a in range(-90, 91, 10)], w=1.5)
    i.line([(12 - 5 * math.sin(math.radians(a)), 12 - 9 * math.cos(math.radians(a))) for a in range(-90, 91, 10)], w=1.5)


def icon_clock(i):
    i.circle((12, 12), 9, w=2.0)
    i.line([(12, 7), (12, 12), (16, 14)], w=2.0)


def icon_grid(i):
    i.rrect((3.5, 3.5, 10.5, 10.5), 1.8)
    i.rrect((13.5, 3.5, 20.5, 10.5), 1.8)
    i.rrect((3.5, 13.5, 10.5, 20.5), 1.8)
    i.rrect((13.5, 13.5, 20.5, 20.5), 1.8)


def icon_filter(i):
    i.line([(3, 5), (21, 5), (14, 13), (14, 20), (10, 18), (10, 13), (3, 5)], w=2.0)


def icon_bolt(i):
    icon_zap(i)


# ---- batch 2: water / cozy, pets, game items, tools ----
def ellipse_pts(cx, cy, rx, ry, n=36):
    return [(cx + rx * math.cos(2 * math.pi * t / n), cy + ry * math.sin(2 * math.pi * t / n)) for t in range(n + 1)]


def capsule_pts(a, b, r, n=14):
    th = math.degrees(math.atan2(b[1] - a[1], b[0] - a[0]))
    return arc(b[0], b[1], r, th - 90, th + 90, n) + arc(a[0], a[1], r, th + 90, th + 270, n) + [arc(b[0], b[1], r, th - 90, th - 90, 1)[0]]


def small_star(i, cx, cy, r):
    i.poly([(cx, cy - r), (cx + r * 0.3, cy - r * 0.3), (cx + r, cy), (cx + r * 0.3, cy + r * 0.3),
            (cx, cy + r), (cx - r * 0.3, cy + r * 0.3), (cx - r, cy), (cx - r * 0.3, cy - r * 0.3)])


def icon_waves(i):
    for y in (6.5, 12, 17.5):
        i.line([(x, y + 1.5 * math.sin((x - 3) / 18 * 3 * math.pi)) for x in np.linspace(3, 21, 36)], w=2.0)


def icon_wind(i):
    i.line([(3, 9), (14, 9)] + arc(14, 6, 3, 90, -160), w=2.0)
    i.line([(3, 13), (18, 13)] + arc(18, 16, 3, -90, 160), w=2.0)
    i.line([(3, 17), (9, 17)], w=2.0)


def icon_cloud(i):
    i.line(arc(6, 15, 4, -74, -270, 18) + arc(18, 15, 4, 90, -90, 18)[0:1], w=2.0)
    i.line([(6, 19), (18, 19)] + arc(18, 15, 4, 90, -90, 18) + arc(12.5, 11.5, 5.5, -5, -180, 26), w=2.0)


def icon_umbrella(i):
    i.line(arc(12, 12, 9, 180, 360) + [(3, 12)], w=2.0)
    i.line([(12, 12), (12, 18.5)] + arc(10, 18.5, 2, 0, 180), w=2.0)
    i.line([(12, 3), (12, 2)], w=2.0)


def icon_anchor(i):
    i.circle((12, 5), 2.2, w=1.9)
    i.line([(12, 7.2), (12, 21)], w=2.0)
    i.line([(8, 10.5), (16, 10.5)], w=2.0)
    i.line(arc(12, 13, 8, 0, 180), w=2.0)
    i.line([(2.5, 15), (4, 13), (6, 14.5)], w=1.8)
    i.line([(21.5, 15), (20, 13), (18, 14.5)], w=1.8)


def icon_fish(i):
    i.line(cubic((2.5, 12), (6.5, 5.5), (13.5, 5.5), (17, 12), 20) + cubic((17, 12), (13.5, 18.5), (6.5, 18.5), (2.5, 12), 20)[1:], w=2.0)
    i.line([(17, 12), (21.5, 7.5), (21.5, 16.5), (17, 12)], w=2.0)
    i.disc((7, 11), 1.2)


def icon_paw(i):
    for c in ((5.5, 11), (9.3, 6.2), (14.7, 6.2), (18.5, 11)):
        i.disc(c, 2.15)
    i.poly(ellipse_pts(12, 16.3, 5, 4.2))


def icon_leaf(i):
    i.line(cubic((4.5, 19.5), (4.5, 9), (11, 4), (20, 4), 22) + cubic((20, 4), (20, 13), (15, 19.5), (4.5, 19.5), 22)[1:], w=2.0)
    i.line([(3, 21), (14, 10)], w=1.8)


def icon_skull(i):
    i.line(arc(12, 10.5, 7.5, 140, 400) + [(16, 16.6), (16, 20.5), (8, 20.5), (8, 16.6), (6.25, 15.3)], w=2.0)
    i.disc((9, 11), 1.8)
    i.disc((15, 11), 1.8)
    i.line([(12, 17.5), (12, 20.5)], w=1.5)


def icon_ghost(i):
    i.line(arc(12, 10, 7, 180, 360) + [(19, 20.5), (16.7, 18.5), (14.3, 20.5), (12, 18.5), (9.7, 20.5), (7.3, 18.5), (5, 20.5), (5, 10)], w=2.0)
    i.disc((9.5, 10.5), 1.25)
    i.disc((14.5, 10.5), 1.25)


def icon_rocket(i):
    i.line(cubic((12, 2.5), (17, 6), (16.5, 12.5), (15, 16), 20) + [(9, 16)] + cubic((9, 16), (7.5, 12.5), (7, 6), (12, 2.5), 20), w=2.0)
    i.circle((12, 9), 1.8, w=1.7)
    i.line([(8.6, 12.5), (5.5, 15.5), (5.5, 18.5), (9, 16.2)], w=1.8)
    i.line([(15.4, 12.5), (18.5, 15.5), (18.5, 18.5), (15, 16.2)], w=1.8)
    i.line([(10.5, 18.5), (12, 21.5), (13.5, 18.5)], w=1.8)


def icon_send(i):
    i.line([(21.5, 2.5), (14.5, 21), (11, 13), (2.5, 9.5), (21.5, 2.5)], w=2.0)
    i.line([(21.5, 2.5), (11, 13)], w=2.0)


def icon_car(i):
    i.line([(3, 16.5), (3, 12.5), (5.5, 11.5), (7.5, 7), (16.5, 7), (18.5, 11.5), (21, 12.5), (21, 16.5), (3, 16.5)], w=2.0)
    i.line([(5.5, 11.5), (18.5, 11.5)], w=1.6)
    i.disc((7.5, 17.5), 2.6)
    i.disc((16.5, 17.5), 2.6)
    i.disc((7.5, 17.5), 1.0, fill=0)
    i.disc((16.5, 17.5), 1.0, fill=0)


def icon_gem(i):
    i.line([(6, 3.5), (18, 3.5), (22, 9), (12, 21), (2, 9), (6, 3.5)], w=2.0)
    i.line([(2, 9), (22, 9)], w=1.7)
    i.line([(9.5, 3.5), (8, 9), (12, 21), (16, 9), (14.5, 3.5)], w=1.6)


def icon_coins(i):
    i.circle((9, 9), 6, w=2.0)
    run = arc(15, 15, 6, -40, 130, 40)
    i.line(run, w=2.0)
    i.circle((9, 9), 2.6, w=1.6)


def icon_gift(i):
    i.rrect((3.5, 8, 20.5, 12), 1.2)
    i.rrect((5, 12, 19, 21), 1.2)
    i.line([(12, 8), (12, 21)], w=1.9)
    i.line(cubic((12, 8), (8.5, 8), (6.5, 6), (8.5, 4.2), 14) + cubic((8.5, 4.2), (10.2, 2.8), (12, 5), (12, 8), 14)[1:], w=1.8)
    i.line(cubic((12, 8), (15.5, 8), (17.5, 6), (15.5, 4.2), 14) + cubic((15.5, 4.2), (13.8, 2.8), (12, 5), (12, 8), 14)[1:], w=1.8)


def icon_key(i):
    i.circle((7.5, 15.5), 4.3, w=2.0)
    i.line([(10.6, 12.4), (20.5, 2.5)], w=2.0)
    i.line([(17.3, 5.7), (20, 8.4)], w=2.0)
    i.line([(14.6, 8.4), (16.6, 10.4)], w=2.0)


def icon_magnet(i):
    i.line([(5, 3.5), (5, 12)] + arc(12, 12, 7, 180, 0) + [(19, 3.5)], w=2.0)
    i.line([(9, 3.5), (9, 12)] + arc(12, 12, 3, 180, 0) + [(15, 3.5)], w=2.0)
    i.line([(5, 7.5), (9, 7.5)], w=2.0)
    i.line([(15, 7.5), (19, 7.5)], w=2.0)


def icon_wand(i):
    i.line([(3.5, 20.5), (14.5, 9.5)], w=2.3)
    small_star(i, 18, 6, 3.6)
    small_star(i, 9, 4.5, 1.8)
    small_star(i, 20, 13.5, 1.8)


def icon_bomb(i):
    i.circle((10.5, 14), 6.5, w=2.0)
    i.line([(15, 9.5), (17, 7.5)], w=2.2)
    i.line(cubic((17, 7.5), (18, 5), (20, 6), (20.5, 3.5), 12), w=1.8)
    i.arcln(9, 13.5, 3.2, 200, 260, w=1.5)


def icon_cart(i):
    i.line([(2, 3), (5, 3), (7.5, 15), (18, 15), (20.5, 7), (6, 7)], w=2.0)
    i.disc((9, 19.5), 1.7)
    i.disc((17, 19.5), 1.7)


def icon_trophy(i):
    i.line([(7, 3.5), (17, 3.5), (17, 9)] + arc(12, 9, 5, 0, 180) + [(7, 3.5)], w=2.0)
    i.line(arc(17, 7, 2.6, -90, 90), w=1.8)
    i.line(arc(7, 7, 2.6, 90, 270), w=1.8)
    i.line([(12, 14), (12, 18)], w=2.0)
    i.line([(7.5, 20.5), (16.5, 20.5)], w=2.0)
    i.line([(9, 18), (15, 18)], w=1.8)


def icon_music(i):
    i.line([(9, 18), (9, 5), (20, 3), (20, 16)], w=2.0)
    i.line([(9, 9), (20, 7)], w=1.6)
    i.disc((6.5, 18), 2.6)
    i.disc((17.5, 16), 2.6)


def icon_volume(i):
    i.line([(3, 9), (7, 9), (12, 4.5), (12, 19.5), (7, 15), (3, 15), (3, 9)], w=2.0)
    i.arcln(13, 12, 3.8, -45, 45, w=2.0, n=12)
    i.arcln(13, 12, 7.5, -50, 50, w=2.0, n=16)


def icon_camera(i):
    i.rrect((2.5, 7, 21.5, 20), 2.6)
    i.line([(8, 7), (9.5, 4), (14.5, 4), (16, 7)], w=2.0)
    i.circle((12, 13.5), 3.6, w=2.0)


def icon_pointer(i):
    i.line([(5, 3), (5, 19), (9.3, 15.2), (12.3, 21.5), (15.2, 20.2), (12.3, 14), (18, 14), (5, 3)], w=2.0)


def icon_keyboard(i):
    i.rrect((2.5, 6, 21.5, 18), 2.2)
    for y in (9.5, 12.5):
        for x in (6, 9, 12, 15, 18):
            i.disc((x, y), 0.95)
    i.line([(8, 15.3), (16, 15.3)], w=1.8)


def icon_code(i):
    i.line([(8, 6.5), (2.5, 12), (8, 17.5)], w=2.2)
    i.line([(16, 6.5), (21.5, 12), (16, 17.5)], w=2.2)
    i.line([(14, 4), (10, 20)], w=1.8)


def icon_terminal(i):
    i.rrect((2.5, 4, 21.5, 20), 2.4)
    i.line([(6.5, 9), (10, 12), (6.5, 15)], w=2.0)
    i.line([(12, 15.5), (17, 15.5)], w=2.0)


def icon_layers(i):
    i.line([(12, 3), (21.5, 8), (12, 13), (2.5, 8), (12, 3)], w=2.0)
    i.line([(2.5, 12.2), (12, 17.2), (21.5, 12.2)], w=2.0)
    i.line([(2.5, 16.4), (12, 21.4), (21.5, 16.4)], w=2.0)


def icon_link(i):
    i.line(capsule_pts((5.5, 18.5), (10, 14), 3.3), w=2.0)
    i.line(capsule_pts((14, 10), (18.5, 5.5), 3.3), w=2.0)
    i.line([(9, 15), (15, 9)], w=2.0)


def icon_copy(i):
    i.rrect((8.5, 8.5, 20.5, 20.5), 2.2)
    i.line([(15.5, 8.5), (15.5, 5.5)] + arc(13.5, 5.5, 2, 0, -90, 8) + [(5.5, 3.5)] + arc(5.5, 5.5, 2, -90, -180, 8) + [(3.5, 13.5)]
           + arc(5.5, 13.5, 2, 180, 90, 8) + [(8.5, 15.5)], w=2.0)


def icon_edit(i):
    i.line([(16.5, 3.5), (20.5, 7.5), (8, 20), (3.5, 20.5), (4, 16), (16.5, 3.5)], w=2.0)
    i.line([(14, 6), (18, 10)], w=1.8)


def icon_plus(i):
    i.line([(12, 5), (12, 19)], w=2.6)
    i.line([(5, 12), (19, 12)], w=2.6)


def icon_list(i):
    for y in (6, 12, 18):
        i.line([(9, y), (20.5, y)], w=2.0)
        i.disc((4.5, y), 1.4)


def icon_menu(i):
    for y in (6, 12, 18):
        i.line([(4, y), (20, y)], w=2.2)


def icon_bookmark(i):
    i.line([(6, 3.5), (18, 3.5), (18, 21), (12, 16.5), (6, 21), (6, 3.5)], w=2.0)


def icon_flag(i):
    i.line([(5, 22), (5, 3.5)], w=2.0)
    i.line([(5, 4)] + cubic((5, 4), (9, 2), (14, 6), (19, 4), 16)[1:] + [(19, 14)] + cubic((19, 14), (14, 16), (9, 12), (5, 14), 16)[1:], w=2.0)


def icon_compass(i):
    i.circle((12, 12), 9, w=2.0)
    i.line([(16, 8), (13.6, 13.6), (8, 16), (10.4, 10.4), (16, 8)], w=1.8)
    i.poly([(16, 8), (13.6, 13.6), (10.4, 10.4)])


def icon_mountain(i):
    i.line([(2.5, 20), (9, 7.5), (13, 14), (15.5, 10.5), (21.5, 20), (2.5, 20)], w=2.0)


def icon_eye_off(i):
    icon_esp(i)
    i.line([(3.5, 3.5), (20.5, 20.5)], w=4.4, fill=0)
    i.line([(3.5, 3.5), (20.5, 20.5)], w=2.0)


def icon_unlock(i):
    i.rrect((5, 11, 19, 20.5), 2.4)
    i.line([(7.8, 11), (7.8, 7.2)] + arc(12, 7.2, 4.2, 180, 330), w=2.0)
    i.disc((12, 15), 1.3)
    i.line([(12, 15), (12, 17.5)], w=1.8)


def icon_bug(i):
    i.rrect((7.5, 8.5, 16.5, 20.5), 4.4)
    i.line(arc(12, 8.5, 3, 180, 360), w=1.9)
    i.line([(12, 11.5), (12, 20)], w=1.6)
    for y0, y1, x in ((11.5, 9.5, 4), (15, 15, 3.5), (18.5, 20.5, 4)):
        i.line([(7.5, y0), (x, y1)], w=1.8)
        i.line([(16.5, y0), (24 - x, y1)], w=1.8)
    i.line([(10, 5.8), (8.5, 3.5)], w=1.6)
    i.line([(14, 5.8), (15.5, 3.5)], w=1.6)


def icon_chart(i):
    i.line([(3.5, 3.5), (3.5, 20.5), (20.5, 20.5)], w=2.0)
    i.line([(8, 16.5), (8, 12)], w=2.8)
    i.line([(12.5, 16.5), (12.5, 7)], w=2.8)
    i.line([(17, 16.5), (17, 10)], w=2.8)


def icon_activity(i):
    i.line([(2.5, 12), (6.5, 12), (9.5, 20), (14.5, 4), (17.5, 12), (21.5, 12)], w=2.0)


def icon_warning(i):
    i.line([(12, 3), (22, 20.5), (2, 20.5), (12, 3)], w=2.0)
    i.line([(12, 9.5), (12, 14)], w=2.2)
    i.disc((12, 17.2), 1.25)


def icon_upload(i):
    i.line([(12, 16), (12, 4)], w=2.0)
    i.line([(7, 8.5), (12, 3.5), (17, 8.5)], w=2.0)
    i.line([(4.5, 20), (19.5, 20)], w=2.0)


def icon_logout(i):
    i.line([(10, 3.5), (4.5, 3.5), (4.5, 20.5), (10, 20.5)], w=2.0)
    i.line([(10, 12), (21, 12)], w=2.0)
    i.line([(17, 8), (21, 12), (17, 16)], w=2.0)


def icon_hourglass(i):
    i.line([(5.5, 3), (18.5, 3)], w=2.0)
    i.line([(5.5, 21), (18.5, 21)], w=2.0)
    i.line([(7, 3), (7, 6), (12, 12), (17, 6), (17, 3)], w=2.0)
    i.line([(7, 21), (7, 18), (12, 12), (17, 18), (17, 21)], w=2.0)


def icon_battery(i):
    i.rrect((2.5, 7, 18.5, 17), 2.2)
    i.rrect((5, 9.5, 12, 14.5), 0.8, fill=True)
    i.line([(21, 10.5), (21, 13.5)], w=2.4)


def icon_sword(i):
    i.line([(20.5, 3.5), (20.5, 7), (9.5, 18), (6, 14.5), (17, 3.5), (20.5, 3.5)], w=1.9)
    i.line([(4.5, 12.5), (11.5, 19.5)], w=2.0)
    i.line([(7, 17), (3.5, 20.5)], w=2.2)


def icon_egg(i):
    i.line(cubic((12, 2.5), (16.5, 2.5), (19.5, 9.5), (19.5, 14), 20) + arc(12, 14, 7.5, 0, 180, 26)[1:]
           + cubic((4.5, 14), (4.5, 9.5), (7.5, 2.5), (12, 2.5), 20)[1:], w=2.0)


def icon_shirt(i):
    i.line([(8.5, 3.5), (3, 6.5), (4.5, 11), (7, 10), (7, 20.5), (17, 20.5), (17, 10), (19.5, 11), (21, 6.5), (15.5, 3.5)]
           + cubic((15.5, 3.5), (14.5, 6), (9.5, 6), (8.5, 3.5), 12)[1:], w=2.0)


def icon_hand(i):
    for x, top in ((8, 6), (11, 3.5), (14, 4), (17, 7)):
        i.line([(x, 13), (x, top)], w=2.3)
    i.line([(17, 7), (17, 15)] + cubic((17, 15), (17, 19), (14.5, 21.5), (11.5, 21.5), 12)[1:]
           + cubic((11.5, 21.5), (8.5, 21.5), (6.5, 19.5), (4.5, 15.5), 12)[1:] + [(3.5, 13.5), (5, 12.5), (8, 15)], w=2.0)



ICONS = {
    "home": icon_home, "combat": icon_combat, "esp": icon_esp, "power": icon_power, "hitbox": icon_hitbox, "luck": icon_luck,
    "visuals": icon_sun, "move": icon_move, "misc": icon_misc, "gear": icon_gear, "search": icon_search, "x": icon_x,
    "minus": icon_minus, "arrow": icon_arrow, "check": icon_check, "chevron": icon_chevron, "star": icon_star, "moon": icon_moon,
    "sun": icon_sun, "info": icon_info,
    "eye": icon_eye, "zap": icon_zap, "bolt": icon_bolt, "swords": icon_swords, "user": icon_user, "users": icon_users,
    "package": icon_package, "map_pin": icon_map_pin, "bell": icon_bell, "shield": icon_shield, "crosshair": icon_crosshair,
    "target": icon_target, "flame": icon_flame, "droplet": icon_droplet, "snowflake": icon_snowflake, "crown": icon_crown,
    "sparkles": icon_sparkles, "heart": icon_heart, "lock": icon_lock, "trash": icon_trash, "refresh": icon_refresh,
    "download": icon_download, "play": icon_play, "pause": icon_pause, "folder": icon_folder, "wifi": icon_wifi,
    "gauge": icon_gauge, "globe": icon_globe, "clock": icon_clock, "grid": icon_grid, "filter": icon_filter,
    # batch 2
    "waves": icon_waves, "wind": icon_wind, "cloud": icon_cloud, "umbrella": icon_umbrella, "anchor": icon_anchor,
    "fish": icon_fish, "paw": icon_paw, "leaf": icon_leaf, "skull": icon_skull, "ghost": icon_ghost, "rocket": icon_rocket,
    "send": icon_send, "car": icon_car, "gem": icon_gem, "coins": icon_coins, "gift": icon_gift, "key": icon_key,
    "magnet": icon_magnet, "wand": icon_wand, "bomb": icon_bomb, "cart": icon_cart, "trophy": icon_trophy,
    "music": icon_music, "volume": icon_volume, "camera": icon_camera, "pointer": icon_pointer, "keyboard": icon_keyboard,
    "code": icon_code, "terminal": icon_terminal, "layers": icon_layers, "link": icon_link, "copy": icon_copy,
    "edit": icon_edit, "plus": icon_plus, "list": icon_list, "menu": icon_menu, "bookmark": icon_bookmark,
    "flag": icon_flag, "compass": icon_compass, "mountain": icon_mountain, "eye_off": icon_eye_off, "unlock": icon_unlock,
    "bug": icon_bug, "chart": icon_chart, "activity": icon_activity, "warning": icon_warning, "upload": icon_upload,
    "logout": icon_logout, "hourglass": icon_hourglass, "battery": icon_battery, "sword": icon_sword, "egg": icon_egg,
    "shirt": icon_shirt, "hand": icon_hand,
}


# ---------------------------------------------------------------- emblem (same drawing as the preview's SVG)
def drop_outline():
    pts = cubic((20, 2.5), (26.6, 12), (34, 18.6), (34, 27.2), 40)
    pts += arc(20, 27.2, 14, 0, 180, 48)[1:]
    pts += cubic((6, 27.2), (6, 18.6), (13.4, 12), (20, 2.5), 40)[1:]
    return pts


def emblem(width=128):
    vb_w, vb_h = 40, 44
    k = width * SS / vb_w
    W, H = int(vb_w * k), int(vb_h * k)

    def P(pts):
        return [(x * k, y * k) for x, y in pts]

    outline = P(drop_outline())
    mask = Image.new("L", (W, H), 0)
    ImageDraw.Draw(mask).polygon(outline, fill=255)

    # body gradient
    yy, xx = np.mgrid[0:H, 0:W]
    t = np.clip((0.6 * (yy / H) + 0.4 * (xx / W) * 0.6 + 0.0), 0, 1)
    stops = [(0.0, (223, 245, 255)), (0.38, (92, 179, 255)), (1.0, (20, 55, 143))]
    col = np.zeros((H, W, 3))
    for (t0, c0), (t1, c1) in zip(stops, stops[1:]):
        m = (t >= t0) & (t <= t1)
        f = ((t - t0) / (t1 - t0))[m][:, None]
        col[m] = np.array(c0) * (1 - f) + np.array(c1) * f
    body = Image.fromarray(col.astype("uint8"), "RGB").convert("RGBA")
    layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    layer.paste(body, (0, 0), mask)

    inner = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    di = ImageDraw.Draw(inner)
    # dark wave at the bottom
    wave = P(cubic((2, 36.5), (7.5, 38.7), (12.5, 38.1), (17.5, 35.3), 20) + cubic((17.5, 35.3), (22.5, 32.5), (28.1, 31.9), (36, 34.7), 20)[1:] + [(36, 46), (2, 46)])
    di.polygon(wave, fill=(15, 45, 120, 140))
    # white curl
    curl = cubic((8.6, 32.2), (11, 25.8), (17.2, 22.8), (22.2, 25.6), 24) + cubic((22.2, 25.6), (25.8, 27.6), (25.6, 32.4), (22, 33.2), 16)[1:] \
        + cubic((22, 33.2), (19.6, 33.7), (18, 31.8), (19.2, 30), 12)[1:]
    cw = 2.2 * k
    di.line(P(curl), fill=(255, 255, 255, 255), width=int(cw))
    for x, y in (P(curl)[0], P(curl)[-1]):
        di.ellipse((x - cw / 2, y - cw / 2, x + cw / 2, y + cw / 2), fill=(255, 255, 255, 255))
    small = cubic((5, 38.4), (10, 40), (15, 39.4), (19.6, 36.8), 20)
    di.line(P(small), fill=(191, 233, 255, 200), width=int(1.3 * k))
    inner_masked = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    inner_masked.paste(inner, (0, 0), Image.composite(inner.split()[3], Image.new("L", (W, H), 0), mask))
    layer = Image.alpha_composite(layer, inner_masked)

    # gold rim (gradient)
    rim = Image.new("L", (W, H), 0)
    rw = 1.7 * k
    ImageDraw.Draw(rim).line(outline + [outline[0]], fill=255, width=int(rw), joint="curve")
    gold = np.zeros((H, W, 3))
    g = np.clip((xx / W + yy / H) / 2, 0, 1)
    gstops = [(0.0, (255, 244, 207)), (0.45, (226, 190, 120)), (1.0, (154, 113, 38))]
    for (t0, c0), (t1, c1) in zip(gstops, gstops[1:]):
        m = (g >= t0) & (g <= t1)
        f = ((g - t0) / (t1 - t0))[m][:, None]
        gold[m] = np.array(c0) * (1 - f) + np.array(c1) * f
    gold_img = Image.fromarray(gold.astype("uint8"), "RGB").convert("RGBA")
    rim_layer = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    rim_layer.paste(gold_img, (0, 0), rim)
    layer = Image.alpha_composite(layer, rim_layer)

    # highlight, glint, sparkle
    top = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    hl = Image.new("RGBA", (int(4 * k), int(8 * k)), (0, 0, 0, 0))
    ImageDraw.Draw(hl).ellipse((0, 0, hl.size[0] - 1, hl.size[1] - 1), fill=(255, 255, 255, 205))
    hl = hl.rotate(-28, expand=True, resample=Image.BICUBIC)
    top.paste(hl, (int(14.2 * k - hl.size[0] / 2), int(18.6 * k - hl.size[1] / 2)), hl)
    dt = ImageDraw.Draw(top)
    r = 0.9 * k
    dt.ellipse((17.6 * k - r, 12.6 * k - r, 17.6 * k + r, 12.6 * k + r), fill=(255, 255, 255, 180))
    star = [(33, 3.2), (34, 5.8), (36.6, 6.8), (34, 7.8), (33, 10.4), (32, 7.8), (29.4, 6.8), (32, 5.8)]
    dt.polygon(P(star), fill=(240, 212, 150, 255))
    layer = Image.alpha_composite(layer, top)
    return layer.resize((width, int(width * vb_h / vb_w)), Image.LANCZOS)


def soft_glow(size=128):
    yy, xx = np.mgrid[0:size, 0:size]
    r = np.sqrt((xx - size / 2 + 0.5) ** 2 + (yy - size / 2 + 0.5) ** 2) / (size / 2)
    a = np.clip(1 - r, 0, 1) ** 1.7
    img = np.zeros((size, size, 4), dtype=np.uint8)
    img[..., :3] = 255
    img[..., 3] = (a * 255).astype(np.uint8)
    return Image.fromarray(img, "RGBA")


def shadow(size=128, inset=40, blur=14):
    m = Image.new("L", (size, size), 0)
    ImageDraw.Draw(m).rounded_rectangle((inset - 6, inset - 6, size - inset + 6, size - inset + 6), radius=18, fill=255)
    m = m.filter(ImageFilter.GaussianBlur(blur))
    out = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    out.putalpha(m)
    return out


def wave(size=128):
    W, H = size * SS, size * SS
    m = Image.new("L", (W, H), 0)
    pts = [(x, H * 0.22 + H * 0.07 * math.sin(2 * math.pi * x / W)) for x in range(0, W + 1, 4)]
    ImageDraw.Draw(m).polygon(pts + [(W, H), (0, H)], fill=255)
    m = m.resize((size, size), Image.LANCZOS)
    out = Image.new("RGBA", (size, size), (255, 255, 255, 0))
    out.putalpha(m)
    return out


# ---------------------------------------------------------------- sounds
RATE = 16000


def tone(f1, f2, dur, kind="sine", vol=0.5, delay=0.0):
    n = int((dur + delay) * RATE)
    out = np.zeros(n)
    s0 = int(delay * RATE)
    m = n - s0
    t = np.arange(m) / RATE
    freq = f1 * (f2 / f1) ** (t / dur)
    phase = 2 * np.pi * np.cumsum(freq) / RATE
    if kind == "triangle":
        wavef = 2 / np.pi * np.arcsin(np.sin(phase))
    else:
        wavef = np.sin(phase)
    env = np.minimum(1, t / 0.008) * np.exp(-t / (dur / 4.5))
    out[s0:] = wavef * env * vol
    return out


def mix(*parts):
    n = max(len(p) for p in parts)
    out = np.zeros(n)
    for p in parts:
        out[: len(p)] += p
    return out


def wav_bytes(samples):
    samples = np.clip(samples, -1, 1)
    data = ((samples * 127) + 128).astype(np.uint8).tobytes()
    header = b"RIFF" + struct.pack("<I", 36 + len(data)) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, RATE, RATE, 1, 8) + b"data" + struct.pack("<I", len(data))
    return header + data


SOUNDS = {
    "on": lambda: tone(480, 1040, 0.11),
    "off": lambda: tone(760, 320, 0.11),
    "tick": lambda: tone(1500, 1200, 0.035, "triangle", 0.35),
    "tab": lambda: tone(900, 1250, 0.05, "sine", 0.4),
    "ok": lambda: mix(tone(660, 700, 0.1, "sine", 0.45), tone(990, 1040, 0.16, "sine", 0.38, 0.07)),
    "warn": lambda: tone(240, 170, 0.18, "triangle", 0.6),
    "pop": lambda: tone(380, 1400, 0.08, "sine", 0.45),
    "open": lambda: mix(tone(300, 900, 0.18, "sine", 0.45), tone(900, 1300, 0.12, "sine", 0.25, 0.1)),
    "close": lambda: tone(900, 280, 0.16, "sine", 0.4),
}


def logo(width=128):
    import glob
    candidates = [ROOT / "78ad6145-fe15-4079-9ea6-03f9df5674d2.png", ROOT / "private" / "assets" / "furina_logo.png"]
    src = next((c for c in candidates if c.exists()), None)
    if src is None:
        hits = sorted(glob.glob(str(ROOT / "**" / "*furina*logo*.png"), recursive=True))
        src = Path(hits[0]) if hits else None
    if src is None:
        return None
    im = Image.open(src).convert("RGBA")
    s2 = min(im.size)
    im = im.crop(((im.size[0] - s2) // 2, (im.size[1] - s2) // 2, (im.size[0] + s2) // 2, (im.size[1] + s2) // 2))
    im = im.resize((width, width), Image.LANCZOS)
    mask = Image.new("L", (width * 4, width * 4), 0)
    ImageDraw.Draw(mask).ellipse((2, 2, width * 4 - 2, width * 4 - 2), fill=255)
    mask = mask.resize((width, width), Image.LANCZOS)
    rgb = im.convert("RGB").quantize(colors=96, method=Image.FASTOCTREE, dither=Image.Dither.NONE).convert("RGB")
    r, g, b = rgb.split()
    return Image.merge("RGBA", (r, g, b, mask))


# ---------------------------------------------------------------- build
def main():
    assets = {}
    assets["emblem"] = ("png", png_bytes(emblem(128)))
    _logo = logo(128)
    if _logo is not None:
        assets["logo"] = ("png", png_bytes(_logo))
    assets["soft"] = ("png", png_bytes(soft_glow(128)))
    assets["shadow"] = ("png", png_bytes(shadow(128)))
    assets["wave"] = ("png", png_bytes(wave(128)))
    for name, fn in ICONS.items():
        ic = Icon(40)
        fn(ic)
        assets["ic_" + name] = ("png", png_bytes(ic.done()))
    for name, fn in SOUNDS.items():
        assets["sfx_" + name] = ("wav", wav_bytes(fn()))

    preview = ROOT / "tools" / "asset_preview"
    preview.mkdir(exist_ok=True)
    lines = ["local ASSET_DATA = {"]
    total = 0
    for name, (ext, data) in assets.items():
        (preview / f"{name}.{ext}").write_bytes(data)
        b64 = base64.b64encode(data).decode()
        total += len(b64)
        ver = hashlib.sha1(data).hexdigest()[:8]
        lines.append(f'\t{name} = {{ ext = "{ext}", v = "{ver}", b64 = "{b64}" }},')
    lines.append("}")
    block = "\n".join(lines)

    src = LUA.read_text(encoding="utf-8")
    new, n = re.subn(r"(-- BEGIN ASSETS[^\n]*\n).*?(\n-- END ASSETS)", lambda m: m.group(1) + block + m.group(2), src, flags=re.S)
    assert n == 1, "asset markers not found"
    LUA.write_text(new, encoding="utf-8")
    print(f"{len(assets)} assets, {total / 1024:.1f} KB base64 embedded into {LUA.name}")


if __name__ == "__main__":
    main()
