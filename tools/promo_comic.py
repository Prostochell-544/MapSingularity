#!/usr/bin/env python3
"""
Картинка для мастерской: «бумажка из лаборатории» — затёртый тетрадный лист, на котором ручкой
набросано, как пользоваться КПП: человечек стреляет в пол → ныряет в портал → стоит хрен пойми где.
Между набросками — стрелки. Внизу без подписи строка цифр: ID карты gm_titan (3796444652) и
«увидимся» (uvidimsya) в кодах ASCII; конец залит кофе от кружки. Подпись «— Петро».

  python tools/promo_comic.py [--out release/screenshots]   -> 03_instruction.jpg

Бумага и рукописные шрифты — те же, что у записок на модели (tools/model/kpp_lun_textures.py).
"""

import argparse
import math
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "model"))
from kpp_lun_textures import HAND_FONTS, PEN_FONTS, hand_font, noise, paper  # noqa: E402

W, H = 1600, 1000
SS = 2
PEN = (28, 40, 115)
RED = (180, 38, 32)

TITAN_ID = "3796444652"
SEE_YOU = " ".join(str(ord(c)) for c in "uvidimsya")   # 117 118 105 100 105 109 115 121 97
SIGN = "— Петро"


class Pen:
    """Линии «от руки»: путь дробится и слегка дрожит плавным шумом."""

    def __init__(self, d, rng, color=PEN, width=5):
        self.d, self.rng, self.color, self.width = d, rng, color, width * SS

    def line(self, pts, wobble=2.5):
        pts = [np.array(p, float) * SS for p in pts]
        out = []
        for a, b in zip(pts, pts[1:]):
            n = max(2, int(np.linalg.norm(b - a) / (12 * SS)))
            for t in np.linspace(0, 1, n, endpoint=False):
                out.append(a + (b - a) * t)
        out.append(pts[-1])
        phase = self.rng.uniform(0, 6.3, 2)
        jit = [tuple(p + wobble * SS * np.array([math.sin(i * 0.5 + phase[0]), math.cos(i * 0.43 + phase[1])]))
               for i, p in enumerate(out)]
        self.d.line(jit, fill=self.color, width=self.width, joint="curve")

    def circle(self, c, r, turns=1.08):
        pts = [(c[0] + r * math.cos(a), c[1] + r * math.sin(a)) for a in np.linspace(0, 2 * math.pi * turns, 40)]
        self.line(pts, wobble=1.5)

    def spiral(self, c, r, turns=3.2, squash=0.45):
        pts = [(c[0] + r * (k / 120) * math.cos(k / 120 * 2 * math.pi * turns),
                c[1] + r * squash * (k / 120) * math.sin(k / 120 * 2 * math.pi * turns)) for k in range(121)]
        self.line(pts, wobble=1.0)

    def arrow(self, a, b, bend=40):
        """Изогнутая стрелка от руки из a в b."""
        a, b = np.array(a, float), np.array(b, float)
        mid = (a + b) / 2 + np.array([0, -bend])
        pts = [tuple((1 - t) ** 2 * a + 2 * (1 - t) * t * mid + t ** 2 * b) for t in np.linspace(0, 1, 16)]
        self.line(pts, 1.5)
        tip = np.array(pts[-1])
        back = tip - np.array(pts[-3])
        back /= np.linalg.norm(back)
        side = np.array([-back[1], back[0]])
        self.line([tuple(tip - back * 22 + side * 12), tuple(tip), tuple(tip - back * 22 - side * 12)], 1.0)


def stick(pen, x, y, s=1.0, arms=((-0.6, 0.9), (0.6, 0.9)), legs=((-0.35, 1.0), (0.35, 1.0)), tilt=0.0):
    """Человечек: голова, туловище, руки и ноги (концы — доли размера от плеча/таза)."""
    def rot(px, py):
        c, sn = math.cos(tilt), math.sin(tilt)
        return (x + (px * c - py * sn) * s, y + (px * sn + py * c) * s)
    pen.circle(rot(0, -95), 22 * s)
    pen.line([rot(0, -73), rot(0, 0)])
    for ax, ay in arms:
        pen.line([rot(0, -55), rot(ax * 60, -55 + ay * 45)])
    for lx, ly in legs:
        pen.line([rot(0, 0), rot(lx * 60, ly * 70)])
    return rot


def gun(pen, x, y):
    """«Лунь» каракулями: коробка, бак, ствол и когти."""
    pen.line([(x, y), (x + 40, y), (x + 40, y - 22), (x, y - 22), (x, y)], 1.0)
    pen.line([(x + 40, y - 4), (x + 80, y - 4), (x + 80, y - 18), (x + 40, y - 18)], 1.0)
    pen.line([(x + 80, y - 11), (x + 100, y - 11)], 0.8)
    pen.line([(x + 100, y - 11), (x + 112, y - 26), (x + 120, y - 16)], 0.8)
    pen.line([(x + 100, y - 11), (x + 114, y + 4), (x + 122, y - 6)], 0.8)
    pen.line([(x + 10, y), (x + 4, y + 20)], 0.8)


def soft_blobs(size, rng, items, blur):
    """Маска мягких пятен (для грязи, графита, отпечатков): items — (x, y, rx, ry, сила)."""
    m = Image.new("L", size, 0)
    d = ImageDraw.Draw(m)
    for x, y, rx, ry, a in items:
        d.ellipse([x - rx, y - ry, x + rx, y + ry], fill=int(255 * a))
    return np.asarray(m.filter(ImageFilter.GaussianBlur(blur)), float) / 255


def grime(img, rng):
    """Старение листа: желтизна пятнами, тёмные края, сгиб, замятины, графит, отпечаток, капли."""
    a = np.asarray(img, float)
    h, w = a.shape[:2]
    size = max(w, h)
    yy, xx = np.mgrid[0:h, 0:w]

    # Неровная желтизна и потемнение к краям.
    blot = noise(rng, 90, size=size)[:h, :w]
    a = a * (1 - 0.10 * np.clip(blot, 0, 2)[..., None]) * np.array([1.0, 0.97, 0.90])
    edge = np.minimum(np.minimum(xx, w - 1 - xx), np.minimum(yy, h - 1 - yy)) / (0.12 * size)
    a = a * (0.72 + 0.28 * np.clip(edge, 0, 1) ** 0.6)[..., None]

    # Сгиб посередине и пара замятин: светлый гребень и тень рядом.
    def crease(x0, y0, x1, y1, strength):
        dx, dy = x1 - x0, y1 - y0
        dist = ((xx - x0) * dy - (yy - y0) * dx) / math.hypot(dx, dy)
        wob = 4 * noise(rng, 40, size=size)[:h, :w]
        dist = dist + wob
        light = np.exp(-(dist / 2.0) ** 2) * strength
        shade = np.exp(-((dist - 6) / 5.0) ** 2) * strength * 0.8
        return light, shade
    for c in (crease(w * 0.52, 0, w * 0.50, h, 1.0), crease(0, h * 0.22, w * 0.35, h * 0.05, 0.6),
              crease(w * 0.78, h, w, h * 0.62, 0.55)):
        a = a * (1 + 0.10 * c[0])[..., None] * (1 - 0.16 * c[1])[..., None]

    # Размазанный графит и грязь от пальцев.
    graphite = soft_blobs((w, h), rng, [(w * 0.30, h * 0.80, 160, 40, 0.5), (w * 0.86, h * 0.30, 90, 140, 0.35),
                                        (w * 0.12, h * 0.15, 120, 60, 0.4)], 30)
    a = a * (1 - 0.22 * graphite)[..., None] + np.array([70, 70, 75]) * 0.22 * graphite[..., None]

    # Отпечаток пальца — кривые кольца грязи.
    fp = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(fp)
    fx, fy = w * 0.08, h * 0.88
    for k in range(9):
        rx, ry = 30 + k * 9, 42 + k * 11
        d.arc([fx - rx, fy - ry, fx + rx, fy + ry], -200 + k * 7, 40 - k * 5, fill=180, width=4)
    fpm = np.asarray(fp.filter(ImageFilter.GaussianBlur(2.5)), float) / 255
    a = a * (1 - 0.25 * fpm)[..., None]

    # Капли кофе.
    drops = soft_blobs((w, h), rng, [(rng.uniform(0.05, 0.95) * w, rng.uniform(0.05, 0.95) * h,
                                      r, r * rng.uniform(0.7, 1.0), 0.8) for r in rng.uniform(6, 22, 9)], 2)
    a = a * (1 - 0.25 * drops)[..., None] + np.array([150, 105, 55]) * 0.25 * drops[..., None]

    # Крупное зерно бумаги.
    a = a * (1 + 0.035 * noise(rng, 1.2, size=size)[:h, :w])[..., None]
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGB")


def coffee_ring(img, cx, cy, r, rng):
    """Кольцо от кружки поверх текста: плотная впитавшаяся середина, тёмный ободок, неровный край."""
    w, h = img.size
    m = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(m)
    pts = []
    for k in range(90):
        ang = k / 90 * 2 * math.pi
        rr = r * (1 + 0.03 * math.sin(ang * 5 + 1) + 0.02 * rng.normal())
        pts.append((cx + rr * math.cos(ang), cy + rr * 0.95 * math.sin(ang)))
    d.polygon(pts, fill=255)
    fill = np.asarray(m.filter(ImageFilter.GaussianBlur(3)), float) / 255
    ring = Image.new("L", (w, h), 0)
    ImageDraw.Draw(ring).line(pts + [pts[0]], fill=255, width=max(3, int(r * 0.035)))
    ring = np.asarray(ring.filter(ImageFilter.GaussianBlur(1.6)), float) / 255
    a = np.asarray(img, float)
    # Середина ровная (чуть светлее к центру — кофе стягивается к краю), по краю тёмный ободок.
    yy, xx = np.mgrid[0:h, 0:w]
    rad = np.clip(np.hypot(xx - cx, (yy - cy) / 0.95) / r, 0, 1)
    tex = 0.94 + 0.06 * noise(rng, 25, size=max(w, h))[:h, :w]
    depth = (0.62 + 0.18 * rad ** 3) * tex
    coffee = np.array([170, 128, 80])
    a = a * (1 - depth * fill)[..., None] + coffee * (depth * fill)[..., None]
    a = a * (1 - 0.55 * ring)[..., None] + np.array([105, 66, 32]) * 0.55 * ring[..., None]
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGB")


def draw(out_path, seed=7):
    rng = np.random.default_rng(seed)
    img = paper(rng, W * SS, H * SS, (234, 228, 210))
    d = ImageDraw.Draw(img, "RGBA")
    for yy in range(150, H, 46):                                   # линовка тетради
        d.line([(0, yy * SS), (W * SS, yy * SS)], fill=(150, 175, 205, 140), width=2 * SS)
    d.line([(110 * SS, 0), (110 * SS, H * SS)], fill=(210, 120, 120, 180), width=2 * SS)

    pen = Pen(d, rng)
    red = Pen(d, rng, RED, 5)

    # Набросок 1: стреляет в пол — луч бьёт в спираль будущего портала.
    rot = stick(pen, 230, 500, arms=((0.75, 0.15), (0.55, 0.35)))
    hx, hy = rot(45, -48)
    gun(pen, hx - 10, hy + 8)
    a, b = np.array([hx + 112, hy - 4]), np.array([470, 566])
    perp = np.array([-(b - a)[1], (b - a)[0]]) / np.linalg.norm(b - a)
    red.line([tuple(a + (b - a) * k / 6 + perp * (0 if k in (0, 6) else (14 if k % 2 else -14))) for k in range(7)], 2.0)
    pen.line([(170, 570), (540, 574)], 1.5)
    red.spiral((470, 568), 55)

    pen.arrow((560, 400), (680, 410))

    # Набросок 2: ныряет головой в портал.
    pen.line([(700, 574), (1030, 570)], 1.5)
    red.spiral((880, 545), 95, turns=3.6, squash=0.55)
    stick(pen, 820, 320, 1.0, arms=((1.0, -1.7), (-1.0, -1.7)), legs=((-0.45, 1.0), (0.45, 1.0)), tilt=2.6)
    for k in range(3):
        pen.line([(690 + k * 24, 195 - k * 14), (715 + k * 24, 240 - k * 14)], 1.0)

    pen.arrow((1040, 400), (1150, 410))

    # Набросок 3: хрен пойми где — кривые горы, странное солнце, «?!».
    pen.line([(1160, 575), (1220, 460), (1270, 530), (1340, 410), (1420, 545), (1470, 490), (1540, 575)], 2.0)
    pen.circle((1470, 250), 34)
    for k in range(8):
        ang = k * math.pi / 4
        pen.line([(1470 + 44 * math.cos(ang), 250 + 44 * math.sin(ang)),
                  (1470 + 62 * math.cos(ang), 250 + 62 * math.sin(ang))], 0.8)
    stick(pen, 1270, 505, 0.85, arms=((-0.8, -0.6), (0.8, -0.6)))
    d.text((1230 * SS, 290 * SS), "?!", font=hand_font(HAND_FONTS, 90 * SS), fill=RED)

    # Строка цифр без подписи: ID gm_titan и «увидимся» в ASCII — конец уйдёт под кофе.
    f = hand_font(PEN_FONTS, 44 * SS)
    d.text((160 * SS, 700 * SS), TITAN_ID, font=f, fill=PEN)
    d.text((160 * SS, 770 * SS), SEE_YOU, font=f, fill=PEN)
    d.text((1180 * SS, 895 * SS), SIGN, font=hand_font(PEN_FONTS, 50 * SS), fill=PEN)

    # Чернила чуть расплылись по бумаге.
    img = img.filter(ImageFilter.GaussianBlur(0.9 * SS)).resize((W, H), Image.LANCZOS)
    img = coffee_ring(img, 1040, 790, 130, rng)
    img = grime(img, rng)
    img = img.rotate(-1.2, resample=Image.BICUBIC, expand=False, fillcolor=(34, 30, 28))
    img.save(out_path, quality=90)
    print("->", out_path)


def main():
    ap = argparse.ArgumentParser(description="Бумажка из лаборатории с набросками")
    ap.add_argument("--out", default=os.path.join(HERE, "..", "release", "screenshots"))
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    draw(os.path.join(os.path.abspath(args.out), "03_instruction.jpg"))


if __name__ == "__main__":
    main()
