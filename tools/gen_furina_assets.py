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

    def line(self, pts, w=None):
        w = self.w if w is None else w * self.k
        pts = [self.P(p) for p in pts]
        self.d.line(pts, fill=255, width=int(round(w)))
        r = w / 2
        for x, y in pts:
            self.d.ellipse((x - r, y - r, x + r, y + r), fill=255)

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

    def done(self):
        a = self.img.resize((self.size, self.size), Image.LANCZOS)
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


ICONS = {
    "home": icon_home, "combat": icon_combat, "esp": icon_esp, "power": icon_power, "hitbox": icon_hitbox, "luck": icon_luck,
    "visuals": icon_sun, "move": icon_move, "misc": icon_misc, "gear": icon_gear, "search": icon_search, "x": icon_x,
    "minus": icon_minus, "arrow": icon_arrow, "check": icon_check, "chevron": icon_chevron, "star": icon_star, "moon": icon_moon,
    "sun": icon_sun, "info": icon_info,
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


# ---------------------------------------------------------------- build
def main():
    assets = {}
    assets["emblem"] = ("png", png_bytes(emblem(128)))
    assets["soft"] = ("png", png_bytes(soft_glow(128)))
    assets["shadow"] = ("png", png_bytes(shadow(128)))
    assets["wave"] = ("png", png_bytes(wave(128)))
    for name, fn in ICONS.items():
        ic = Icon(64)
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
