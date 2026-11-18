#!/usr/bin/env python3
"""
КПП «Лунь» — процедурные текстуры для меша из kpp_lun_mesh.py.

Бесшовные поверхности (шум через БПФ — периодичен сам по себе) под кубическую проекцию UV
(одна плитка на 8 юнитов) и табличка с маркировкой под подогнанную UV. Пишет TGA + .txt
для vtex в materialsrc/<TEX_DIR>/ и materials.json — параметры VMT для compile_lun.py.

Вызывается из kpp_lun_mesh.py; отдельно:  python tools/model/kpp_lun_textures.py --out art/kpp_lun
"""

import argparse
import json
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFont

TEX_DIR = "models/map_singularity/kpp_lun"
SIZE = 512          # плитка 8 юнитов -> 64 пикселя на юнит
FLAT_NORMAL = "kpp_flat_normal"
LABEL_TEXT = "КПП-04 // ВИРІБ «ЛУНЬ»"
LABEL_SUB = "НДІ ПРОЕКТУВАННЯ   ·   ЗАВ. № 0417"
FONT_CANDIDATES = [r"C:\Windows\Fonts\bahnschrift.ttf", r"C:\Windows\Fonts\arialbd.ttf"]

# Параметры VMT. Phong в VertexLitGeneric — с плоской картой нормалей (маска блеска в её альфе).
# Без $halflambert: как у гравипушки и тулгана — полутень глубже, модель не «пластиковая».
PHONG = {"$bumpmap": TEX_DIR + "/" + FLAT_NORMAL, "$phong": "1"}
VMT = {
    "kpp_shell":    dict(PHONG, **{"$phongexponent": "10", "$phongboost": "0.6", "$phongfresnelranges": "[0.3 0.6 1]"}),
    "kpp_metal":    dict(PHONG, **{"$phongexponent": "25", "$phongboost": "1.8", "$phongfresnelranges": "[0.4 0.8 1]"}),
    "kpp_worn":     dict(PHONG, **{"$phongexponent": "35", "$phongboost": "2.5", "$phongfresnelranges": "[0.4 0.8 1]"}),
    "kpp_copper":   dict(PHONG, **{"$phongexponent": "30", "$phongboost": "3", "$phongtint": "[1 0.72 0.5]",
                                   "$phongfresnelranges": "[0.5 0.8 1]"}),
    "kpp_bakelite": dict(PHONG, **{"$phongexponent": "14", "$phongboost": "1", "$phongfresnelranges": "[0.3 0.6 1]"}),
    "kpp_hazard":   dict(PHONG, **{"$phongexponent": "10", "$phongboost": "0.5", "$phongfresnelranges": "[0.3 0.6 1]"}),
    "kpp_label":    dict(PHONG, **{"$phongexponent": "10", "$phongboost": "0.5", "$phongfresnelranges": "[0.3 0.6 1]"}),
    "kpp_screen":   dict(PHONG, **{"$phongexponent": "80", "$phongboost": "3", "$phongfresnelranges": "[0.6 0.9 1]",
                                   "$selfillum": "1"}),
    "kpp_rubber":   dict(PHONG, **{"$phongexponent": "6", "$phongboost": "0.3", "$phongfresnelranges": "[0.2 0.4 1]"}),
    "kpp_led":      {"$selfillum": "1", "$selfillumtint": "[1.6 1.6 1.6]"},
    "kpp_tube":     {"$selfillum": "1", "$selfillumtint": "[1.5 1.4 1.3]"},
    "kpp_brass":    dict(PHONG, **{"$phongexponent": "30", "$phongboost": "3", "$phongtint": "[1 0.85 0.55]", "$phongfresnelranges": "[0.5 0.8 1]"}),
    "kpp_porcelain": dict(PHONG, **{"$phongexponent": "40", "$phongboost": "1.5", "$phongfresnelranges": "[0.3 0.6 1]"}),
    "kpp_note":     dict(PHONG, **{"$phongexponent": "8", "$phongboost": "0.3", "$phongfresnelranges": "[0.2 0.4 1]"}),
    "kpp_sticky":   dict(PHONG, **{"$phongexponent": "8", "$phongboost": "0.3", "$phongfresnelranges": "[0.2 0.4 1]"}),
    "kpp_warn":     dict(PHONG, **{"$phongexponent": "12", "$phongboost": "0.6", "$phongfresnelranges": "[0.3 0.6 1]"}),
    "kpp_tape":     dict(PHONG, **{"$phongexponent": "20", "$phongboost": "1.2", "$phongfresnelranges": "[0.3 0.6 1]"}),
    "kpp_gauge":    dict(PHONG, **{"$phongexponent": "60", "$phongboost": "1.2", "$phongfresnelranges": "[0.4 0.7 1]"}),
    "kpp_glow":     {"$selfillum": "1", "$selfillumtint": "[1.3 1.3 1.3]"},
    "kpp_orb":      {"$selfillum": "1", "$selfillumtint": "[1.6 1.5 1.8]"},
}


def noise(rng, sx, sy=None, size=SIZE):
    """Бесшовный гауссов шум: размытие белого шума в частотной области; sx/sy — радиусы в пикселях."""
    sy = sx if sy is None else sy
    f = np.fft.fft2(rng.standard_normal((size, size)))
    ky = np.fft.fftfreq(size)[:, None]
    kx = np.fft.fftfreq(size)[None, :]
    n = np.real(np.fft.ifft2(f * np.exp(-2 * np.pi ** 2 * ((sx * kx) ** 2 + (sy * ky) ** 2))))
    return (n - n.mean()) / (n.std() + 1e-9)


def fbm(rng, base, octaves=4, size=SIZE):
    out, amp, total = np.zeros((size, size)), 1.0, 0.0
    for o in range(octaves):
        out += noise(rng, base / 2 ** o, size=size) * amp
        total += amp
        amp *= 0.5
    return out / total


def rgb(color):
    return np.array(color, float)[None, None, :]


def smooth(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def scratches(rng, count, length, width, size=SIZE):
    """Тонкие светлые царапины; рисуются со сдвигами на период — плитка остаётся бесшовной."""
    img = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(img)
    for _ in range(count):
        x, y = rng.uniform(0, size, 2)
        a = rng.normal(0, 0.35) + (np.pi / 2 if rng.random() < 0.25 else 0)
        L = rng.uniform(0.3, 1.0) * length
        x2, y2 = x + np.cos(a) * L, y + np.sin(a) * L
        v = int(rng.uniform(90, 255))
        for ox in (-size, 0, size):
            for oy in (-size, 0, size):
                d.line([(x + ox, y + oy), (x2 + ox, y2 + oy)], fill=v, width=width)
    return np.asarray(img, float) / 255


def tex_shell(rng):
    """Молотковая эмаль: серо-зелёная, с «чешуёй» ударов молотка, грязью и сколами до металла."""
    hammer = np.abs(noise(rng, 5.0)) + 0.4 * np.abs(noise(rng, 2.2))
    grime = fbm(rng, 48)
    col = rgb((92, 106, 94)) * (0.95 + 0.05 * hammer[..., None] + 0.02 * noise(rng, 0.8)[..., None])
    col = col * (1 - 0.18 * smooth(0.2, 1.6, grime)[..., None]) + rgb((40, 34, 20)) * 0.06 * smooth(0.6, 1.8, grime)[..., None]
    chips = smooth(2.3, 2.6, noise(rng, 2.5)) * smooth(-0.2, 0.6, fbm(rng, 30))
    col = col * (1 - chips[..., None]) + rgb((120, 120, 116)) * chips[..., None]
    return col


def tex_brass(rng):
    col = rgb((176, 140, 72)) * (1 + 0.08 * noise(rng, 50, 0.8)[..., None] + 0.08 * fbm(rng, 30)[..., None])
    tarnish = smooth(0.6, 1.8, fbm(rng, 36))
    return col * (1 - 0.35 * tarnish[..., None]) + rgb((70, 60, 40)) * 0.35 * tarnish[..., None]


def tex_porcelain(rng):
    col = rgb((226, 220, 204)) * (1 + 0.02 * noise(rng, 1)[..., None])
    return col * (1 - 0.18 * smooth(0.8, 2.0, fbm(rng, 30))[..., None])


def tex_tube(rng):
    u = np.arange(SIZE)[None, :]
    filament = (0.5 + 0.5 * np.sin(u / SIZE * 2 * np.pi * 24)) ** 4
    col = rgb((255, 140, 50)) * (0.75 + 0.3 * filament[..., None] + 0.05 * noise(rng, 8)[..., None])
    return col, 255


HAND_FONTS = [r"C:\Windows\Fonts\Inkfree.ttf", r"C:\Windows\Fonts\segoepr.ttf", r"C:\Windows\Fonts\comic.ttf"]
PEN_FONTS = [r"C:\Windows\Fonts\segoepr.ttf", r"C:\Windows\Fonts\Inkfree.ttf", r"C:\Windows\Fonts\comic.ttf"]


def hand_font(paths, size, text=None, max_w=None):
    """Рукописный шрифт; с text и max_w — уменьшается, пока строка не влезет."""
    for path in paths:
        if os.path.exists(path):
            font = ImageFont.truetype(path, size)
            while text and max_w and font.getlength(text) > max_w and size > 12:
                size -= 2
                font = ImageFont.truetype(path, size)
            return font
    return load_font(size)


def paper(rng, w, h, base, tape=True):
    """Бумага: цвет, волокно, замятость, края темнее, полоски скотча сверху."""
    n = noise(rng, 2, size=max(w, h))[:h, :w]
    crease = smooth(1.6, 2.2, np.abs(noise(rng, 60, 1.5, size=max(w, h))[:h, :w]))
    yy, xx = np.mgrid[0:h, 0:w]
    edge = np.minimum(np.minimum(xx, w - 1 - xx), np.minimum(yy, h - 1 - yy)) / (0.08 * min(w, h))
    col = rgb(base) * (0.96 + 0.03 * n[..., None] - 0.08 * crease[..., None]) * (0.85 + 0.15 * np.clip(edge, 0, 1)[..., None])
    img = Image.fromarray(np.clip(col, 0, 255).astype(np.uint8), "RGB")
    if tape:
        d = ImageDraw.Draw(img, "RGBA")
        for x0 in (int(w * 0.12), int(w * 0.68)):
            d.polygon([(x0, 0), (x0 + int(w * 0.22), 0), (x0 + int(w * 0.24), int(h * 0.1)), (x0 + 2, int(h * 0.11))],
                      fill=(235, 225, 190, 120))
    return img


def tex_note(rng, w=512, h=384):
    """Записка от руки на силовом блоке."""
    img = paper(rng, w, h, (232, 228, 214))
    d = ImageDraw.Draw(img)
    for y in range(70, h, 36):                                  # линовка тетради
        d.line([(0, y), (w, y)], fill=(150, 175, 205), width=2)
    d.line([(60, 0), (60, h)], fill=(210, 120, 120), width=2)
    d.text((80, 50), "НЕ ЧІПАТИ!", font=hand_font(HAND_FONTS, 88, "НЕ ЧІПАТИ!", w - 110), fill=(190, 30, 30))
    d.text((90, 170), "400 кВ !!!", font=hand_font(HAND_FONTS, 64), fill=(30, 40, 120))
    d.text((210, 270), "— Петро", font=hand_font(PEN_FONTS, 42), fill=(30, 40, 120))
    d.ellipse([70, 160, 380, 250], outline=(190, 30, 30), width=4)
    return np.asarray(img, float)


def tex_sticky(rng, w=384, h=384):
    """Жёлтый стикер на экране прибора."""
    img = paper(rng, w, h, (246, 222, 90), tape=False)
    d = ImageDraw.Draw(img)
    f = hand_font(PEN_FONTS, 46, "НЕ ВМИКАТИ", w - 50)
    for i, line in enumerate(("фаза 2:", "НЕ ВМИКАТИ", "до тесту!")):
        d.text((26, 40 + i * 95), line, font=f, fill=(30, 40, 110))
    d.line([(40, 335), (330, 320)], fill=(30, 40, 110), width=5)
    return np.asarray(img, float)


def tex_warn(rng, w=512, h=256):
    """Трафарет на баке: треугольник с молнией и «ВИСОКА НАПРУГА», краска облезла."""
    img = Image.new("RGB", (w, h), (92, 106, 94))
    d = ImageDraw.Draw(img)
    tri = [(24, h - 30), (24 + 190, h - 30), (24 + 95, 30)]
    d.polygon(tri, fill=(232, 182, 30))
    d.polygon([(110, 80), (138, 80), (122, 140), (146, 140), (100, 214), (112, 154), (90, 154)], fill=(25, 25, 22))
    f = load_font(70)
    d.text((240, 52), "ВИСОКА", font=f, fill=(232, 182, 30))
    d.text((240, 132), "НАПРУГА", font=f, fill=(232, 182, 30))
    col = np.asarray(img, float)
    scuff = smooth(1.0, 2.0, noise(rng, 4, size=w)[:h, :w] + 0.6 * noise(rng, 30, size=w)[:h, :w])
    return col * (1 - scuff[..., None]) + rgb((92, 106, 94)) * scuff[..., None]


def tex_tape(rng):
    return rgb((40, 70, 160)) * (1 + 0.05 * noise(rng, 1)[..., None] + 0.08 * fbm(rng, 20)[..., None])


def tex_gauge(rng, size=512):
    """Циферблат: шкала 0–10 на 270°, красная зона, подпись «НАПРУЖЕНІСТЬ ПОЛЯ, кВ/м»."""
    img = Image.new("RGB", (size, size), (228, 222, 200))
    d = ImageDraw.Draw(img)
    c, r = size / 2, size * 0.46
    d.ellipse([c - r, c - r, c + r, c + r], outline=(30, 30, 28), width=10)
    for i in range(51):
        a = np.radians(225 - i * 270 / 50)
        long = i % 5 == 0
        r0 = r * (0.72 if long else 0.8)
        color = (190, 40, 30) if i >= 40 else (30, 30, 28)
        d.line([(c + np.cos(a) * r0, c - np.sin(a) * r0), (c + np.cos(a) * r * 0.9, c - np.sin(a) * r * 0.9)], fill=color, width=6 if long else 3)
        if long:
            f = load_font(34)
            t = str(i // 5)
            tw = f.getlength(t)
            d.text((c + np.cos(a) * r * 0.58 - tw / 2, c - np.sin(a) * r * 0.58 - 20), t, font=f, fill=color)
    small = load_font(26)
    for text, y in (("НАПРУЖЕНІСТЬ", c + r * 0.3), ("ПОЛЯ, кВ/м", c + r * 0.45)):
        d.text((c - small.getlength(text) / 2, y), text, font=small, fill=(60, 58, 52))
    col = np.asarray(img, float)
    return col * (1 - 0.15 * smooth(0.8, 2.2, noise(rng, 40, size=size))[..., None])


def tex_metal(rng):
    col = rgb((60, 63, 66)) * (1 + 0.07 * noise(rng, 60, 0.7)[..., None] + 0.05 * fbm(rng, 40)[..., None])
    return col + rgb((60, 60, 60)) * 0.35 * scratches(rng, 40, 60, 1)[..., None]


def tex_worn(rng):
    col = rgb((140, 141, 138)) * (1 + 0.08 * noise(rng, 70, 0.8)[..., None])
    col = col * (1 - 0.22 * smooth(0.4, 1.8, fbm(rng, 36))[..., None])
    return col + rgb((70, 70, 70)) * 0.6 * scratches(rng, 90, 50, 1)[..., None]


def tex_copper(rng):
    col = rgb((198, 112, 58)) * (1 + 0.10 * fbm(rng, 24)[..., None] + 0.05 * noise(rng, 40, 0.8)[..., None])
    ox = smooth(0.9, 1.9, fbm(rng, 40))
    return col * (1 - 0.5 * ox[..., None]) + rgb((70, 110, 90)) * 0.35 * ox[..., None]


def tex_bakelite(rng):
    warp = noise(rng, 50) * 6
    yy = np.arange(SIZE)[:, None] + warp
    grain = np.sin(yy / SIZE * 2 * np.pi * 22) * 0.5 + 0.5
    col = rgb((90, 54, 33)) * (1 + 0.13 * noise(rng, 80, 1.2)[..., None] - 0.18 * grain[..., None] ** 6)
    return col * (1 - 0.15 * smooth(0.5, 1.8, fbm(rng, 40))[..., None])


def tex_hazard(rng):
    i, j = np.mgrid[0:SIZE, 0:SIZE]
    stripe = ((i + j) // (SIZE // 16)) % 2 == 0                     # 8 пар полос на плитку (полоса 0,5 юнита)
    col = np.where(stripe[..., None], rgb((232, 180, 28)), rgb((34, 32, 30)))
    col = col * (1 + 0.04 * noise(rng, 1)[..., None])
    wear = smooth(1.4, 2.0, fbm(rng, 10)) + 0.8 * scratches(rng, 50, 40, 2)
    wear = np.clip(wear, 0, 1)
    return col * (1 - wear[..., None]) + rgb((128, 128, 124)) * wear[..., None]


def tex_screen(rng):
    col = rgb((12, 40, 30)) * (1 + 0.08 * noise(rng, 30)[..., None])
    return col, 70


def tex_glow(rng):
    u = np.arange(SIZE)[None, :]
    bands = (0.5 + 0.5 * np.sin(u / SIZE * 2 * np.pi * 16)) ** 3      # кольца поля вдоль оси
    col = rgb((90, 175, 255)) * (0.78 + 0.3 * bands[..., None] + 0.06 * noise(rng, 18)[..., None])
    return col, 255


def tex_rubber(rng):
    col = rgb((32, 32, 34)) * (1 + 0.06 * noise(rng, 1.2)[..., None] + 0.08 * fbm(rng, 30)[..., None])
    return col


def tex_led(rng):
    return rgb((255, 96, 40)) * (0.95 + 0.05 * noise(rng, 4)[..., None]), 255


def tex_orb(rng):
    col = rgb((225, 205, 255)) * (0.92 + 0.08 * fbm(rng, 30)[..., None])
    return col, 255


def load_font(size):
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            font = ImageFont.truetype(path, size)
            try:
                font.set_variation_by_name("Bold Condensed")
            except Exception:
                pass
            return font
    return ImageFont.load_default()


def tex_label(rng, w=1024, h=256):
    """Табличка: блок жёлто-чёрных полос слева, справа две строки трафаретом."""
    img = Image.new("RGB", (w, h), (52, 56, 50))
    d = ImageDraw.Draw(img)
    block = int(h * 0.75)
    for k in range(-h, block + h, 32):
        d.polygon([(k, h), (k + 16, h), (k + 16 + h, 0), (k + h, 0)], fill=(232, 180, 28))
    d.rectangle([block, 0, w, h], fill=(52, 56, 50))
    d.rectangle([4, 4, w - 5, h - 5], outline=(150, 150, 138), width=4)
    d.line([(block, 4), (block, h - 5)], fill=(150, 150, 138), width=4)

    def fit(text, max_w, size):
        font = load_font(size)
        while font.getlength(text) > max_w and size > 10:
            size -= 2
            font = load_font(size)
        return font

    x0, max_w = block + 28, w - block - 56
    f1 = fit(LABEL_TEXT, max_w, 112)
    f2 = fit(LABEL_SUB, max_w, 52)
    d.text((x0, 24), LABEL_TEXT, font=f1, fill=(230, 224, 204))
    d.text((x0, h - 84), LABEL_SUB, font=f2, fill=(200, 196, 178))

    col = np.asarray(img, float)
    scuff = smooth(2.2, 2.8, noise(rng, 3, size=w)[:h, :w])  # мелкие потёртости краски
    col = col * (1 - scuff[..., None]) + rgb((110, 112, 106)) * scuff[..., None]
    return col


def pow2(n):
    p = 1
    while p < n:
        p *= 2
    return p


def save_tga(path, col, alpha=None):
    """TGA для vtex: стороны приводятся к степени двойки (vtex иначе не собирает DXT)."""
    col = np.clip(col, 0, 255).astype(np.uint8)
    if alpha is None:
        img = Image.fromarray(col, "RGB")
    else:
        a = np.full(col.shape[:2], alpha, np.uint8) if np.isscalar(alpha) else np.clip(alpha, 0, 255).astype(np.uint8)
        img = Image.fromarray(np.dstack([col, a]), "RGBA")
    size = (pow2(img.width), pow2(img.height))
    if size != img.size:
        img = img.resize(size, Image.LANCZOS)
    img.save(path)


def write_all(out_dir, seed=417):
    """Пишет materialsrc/<TEX_DIR>/*.tga + *.txt и materials.json; возвращает список материалов."""
    src = os.path.join(out_dir, "materialsrc", *TEX_DIR.split("/"))
    os.makedirs(src, exist_ok=True)
    rng = np.random.default_rng(seed)
    makers = {
        "kpp_shell": tex_shell, "kpp_metal": tex_metal, "kpp_worn": tex_worn, "kpp_copper": tex_copper,
        "kpp_bakelite": tex_bakelite, "kpp_hazard": tex_hazard, "kpp_label": tex_label,
        "kpp_rubber": tex_rubber, "kpp_screen": tex_screen, "kpp_glow": tex_glow, "kpp_orb": tex_orb,
        "kpp_led": tex_led, "kpp_tube": tex_tube, "kpp_brass": tex_brass, "kpp_porcelain": tex_porcelain,
        "kpp_gauge": tex_gauge, "kpp_note": tex_note, "kpp_sticky": tex_sticky, "kpp_warn": tex_warn,
        "kpp_tape": tex_tape,
    }
    for name, make in makers.items():
        res = make(rng)
        col, alpha = res if isinstance(res, tuple) else (res, None)
        save_tga(os.path.join(src, name + ".tga"), col, alpha)
        with open(os.path.join(src, name + ".txt"), "w", encoding="ascii") as f:
            f.write("nocompress 0\n")

    flat = np.zeros((64, 64, 3)) + rgb((128, 128, 255))
    save_tga(os.path.join(src, FLAT_NORMAL + ".tga"), flat, 255)
    with open(os.path.join(src, FLAT_NORMAL + ".txt"), "w", encoding="ascii") as f:
        f.write("normal 1\nnocompress 0\n")

    materials = {}
    for name in makers:
        params = {"$basetexture": TEX_DIR + "/" + name}
        params.update(VMT[name])
        materials[name] = {"shader": "VertexLitGeneric", "params": params}
    with open(os.path.join(out_dir, "materials.json"), "w", encoding="utf-8") as f:
        json.dump({"tex_dir": TEX_DIR, "materials": materials, "textures": sorted(list(makers) + [FLAT_NORMAL])}, f,
                  ensure_ascii=False, indent=1)
    return list(makers)


if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description="КПП «Лунь»: процедурные текстуры")
    ap.add_argument("--out", default=os.path.normpath(os.path.join(here, "..", "..", "art", "kpp_lun")))
    args = ap.parse_args()
    print("материалы:", ", ".join(write_all(args.out)))
