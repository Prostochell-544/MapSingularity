#!/usr/bin/env python3
"""
КПП «Лунь»: как модель выглядит от первого лица при заданной подгонке — без запуска игры.

  python tools/model/preview_viewmodel.py [--x 19.5 --y 8.25 --z -6.5 --p 0 --yw -6.8 --r 1.7 --s 0.9] [--out vm.png]

Повторяет математику weapon_singularity.lua: начало модели ставится от камеры вьюмодели
(x вперёд, y вправо, z вверх), затем повороты рыскание → тангаж (плюс — ствол вверх) → крен
вокруг осей оружия, масштаб от начала модели. Проекция — как в Source: ViewModelFOV задан
по горизонтали для 4:3 и растягивается под ширину экрана.

Меш — kpp_lun_ref.smd, цвет — basecolor в центре треугольника, свет — Ламберт.
Как в игре: SMD поворачивается так же, как его поворачивает studiomdl ($origin в QC;
без него — +90 град. вокруг Z), а панель экрана (бирюзовая) рисуется по точкам крепления
"screen" / "screen_br" из QC — видно, легла ли она в стекло.
"""

import argparse
import math
import os
import re

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.normpath(os.path.join(HERE, "..", ".."))
WORK = os.path.join(PROJECT, "art", "kpp_lun")          # процедурная; модель из Tripo — art/kpp_lun_tripo
TEX_SUBDIR = os.path.join("materialsrc", "models", "map_singularity", "kpp_lun")

# По умолчанию — TUNE_DEFAULTS.vm из weapon_singularity.lua.
DEFAULTS = (("x", 22.26), ("y", 8.25), ("z", -4.91), ("p", 5.1), ("yw", 1.7), ("r", 1.7), ("s", 0.9))
PANEL_COLOR = (20, 120, 105)


def read_smd(path):
    pos, nrm, uv, mats = [], [], [], []
    with open(path, encoding="ascii", errors="replace") as f:
        lines = iter(f)
        for line in lines:
            if line.strip() == "triangles":
                break
        while True:
            mat = next(lines, "").strip()
            if not mat or mat == "end":
                break
            mats.append(mat)
            for _ in range(3):
                p = next(lines).split()
                pos.append([float(p[1]), float(p[2]), float(p[3])])
                nrm.append([float(p[4]), float(p[5]), float(p[6])])
                uv.append([float(p[7]), float(p[8])])
    return (np.array(pos).reshape(-1, 3, 3), np.array(nrm).reshape(-1, 3, 3), np.array(uv).reshape(-1, 3, 2), mats)


def material_colors(work, mats, uv):
    """Цвет треугольника — текстура его материала (<mat>.tga или <mat>_basecolor.tga) в центре UV."""
    cuv = uv.mean(axis=1)
    out = np.full((len(mats), 3), 128.0)
    cache = {}
    for i, m in enumerate(mats):
        if m not in cache:
            cache[m] = None
            for name in (m + ".tga", m + "_basecolor.tga"):
                path = os.path.join(work, TEX_SUBDIR, name)
                if os.path.exists(path):
                    cache[m] = np.asarray(Image.open(path).convert("RGB"), dtype=np.float32)
                    break
        tex = cache[m]
        if tex is not None:
            th, tw = tex.shape[:2]
            out[i] = tex[int(np.clip((1 - cuv[i, 1] % 1) * th, 0, th - 1)), int(np.clip((cuv[i, 0] % 1) * tw, 0, tw - 1))]
    return out


def read_qc(path):
    """Поворот studiomdl (град. вокруг Z) и точки крепления {имя: (позиция, углы)} в осях SMD."""
    rot, atts = 90.0, {}
    if not os.path.exists(path):
        return rot, atts
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r'\s*\$origin\s+\S+\s+\S+\s+\S+\s+(\S+)', line)
            if m:
                rot = float(m.group(1)) + 90
            m = re.match(r'\s*\$attachment\s+"(\w+)"\s+"lun_root"\s+(\S+)\s+(\S+)\s+(\S+)\s+rotate\s+(\S+)\s+(\S+)\s+(\S+)', line)
            if m:
                v = [float(x) for x in m.groups()[1:]]
                atts[m.group(1)] = (np.array(v[:3]), v[3:])
    return rot, atts


def body_smd(work):
    """SMD, который QC берёт в $body (после запекания — kpp_lun_body.smd)."""
    path = os.path.join(work, "kpp_lun.qc")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            m = re.search(r'\$body\s+"\w+"\s+"([^"]+)"', f.read())
            if m:
                return os.path.join(work, m.group(1))
    return os.path.join(work, "kpp_lun_ref.smd")


def angle_matrix(p, y, r):
    """Оси Source-углов: столбцы вперёд (X), влево (Y), вверх (Z)."""
    sp, cp = math.sin(math.radians(p)), math.cos(math.radians(p))
    sy, cy = math.sin(math.radians(y)), math.cos(math.radians(y))
    sr, cr = math.sin(math.radians(r)), math.cos(math.radians(r))
    fwd = np.array([cp * cy, cp * sy, -sp])
    left = np.array([sp * sr * cy - cr * sy, sp * sr * sy + cr * cy, sr * cp])
    up = np.array([sp * cr * cy + sr * sy, sp * cr * sy - sr * cy, cr * cp])
    return fwd, left, up


def rotz(deg):
    c, s = math.cos(math.radians(deg)), math.sin(math.radians(deg))
    return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1.0]])


def rotate(v, axis, deg):
    """Поворот по правилу правой руки (как Angle:RotateAroundAxis в Source)."""
    axis = axis / np.linalg.norm(axis)
    a = math.radians(deg)
    return v * math.cos(a) + np.cross(axis, v) * math.sin(a) + axis * np.dot(axis, v) * (1 - math.cos(a))


def gun_basis(t):
    # Мир Source: камера смотрит по +X, +Y — влево, +Z — вверх.
    fwd, right, up = np.array([1.0, 0, 0]), np.array([0, -1.0, 0]), np.array([0, 0, 1.0])
    for axis_name, deg in (("up", t.yw), ("right", t.p), ("fwd", t.r)):
        axis = {"up": up, "right": right, "fwd": fwd}[axis_name].copy()
        fwd, right, up = rotate(fwd, axis, deg), rotate(right, axis, deg), rotate(up, axis, deg)
    origin = np.array([t.x, -t.y, t.z])
    # Модель: X — вперёд, Y — влево, Z — вверх.
    return origin, np.stack([fwd, -right, up]) * t.s


def panel_quad(atts):
    """Четырёхугольник панели экрана по точкам "screen" (левый верх) и "screen_br" (правый низ)."""
    if "screen" not in atts or "screen_br" not in atts:
        return None
    tl, ang = atts["screen"]
    br, _ = atts["screen_br"]
    x_axis, y_axis, _ = angle_matrix(*ang)
    d = br - tl
    w, h = d.dot(x_axis), -d.dot(y_axis)
    tr, bl = tl + x_axis * w, tl - y_axis * h
    print("панель экрана: %.2f x %.2f юнита (в модели, до масштаба)" % (w, h))
    return np.array([[tl, tr, tr - y_axis * h], [tl, tr - y_axis * h, bl]])


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    for name, default in DEFAULTS:
        ap.add_argument("--" + name, type=float, default=default)
    ap.add_argument("--fov", type=float, default=54, help="SWEP.ViewModelFOV")
    ap.add_argument("--aspect", type=float, default=16 / 9)
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--work", default=WORK, help="папка сборки: art/kpp_lun или art/kpp_lun_tripo")
    ap.add_argument("--rot", type=float, default=None, help="поворот studiomdl вокруг Z (по умолчанию — из QC)")
    ap.add_argument("--out", default=None, help="по умолчанию <work>/preview_viewmodel.png")
    t = ap.parse_args()
    t.out = t.out or os.path.join(t.work, "preview_viewmodel.png")

    W = t.width
    H = int(round(W / t.aspect))
    tan_v = math.tan(math.radians(t.fov / 2)) * 0.75
    tan_h = tan_v * t.aspect

    rot, atts = read_qc(os.path.join(t.work, "kpp_lun.qc"))
    if t.rot is not None:
        rot = t.rot
    game = rotz(rot).T  # строки-векторы: v @ R^T

    tri, nrm, uv, mats = read_smd(body_smd(t.work))
    tri, nrm = tri @ game, nrm @ game
    origin, basis = gun_basis(t)

    base = material_colors(t.work, mats, uv)

    light = np.array([0.6, 0.35, 0.75])       # из-за плеча: спереди-слева-сверху
    light /= np.linalg.norm(light)
    wn = nrm @ (basis / t.s)
    n = wn.mean(axis=1)
    n /= np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-6)
    shade = 0.35 + 0.65 * np.clip(n @ light, 0, 1)
    col = np.clip(base * shade[:, None], 0, 255).astype(np.uint8)

    quad = panel_quad(atts)
    if quad is not None:
        tri = np.concatenate([tri, quad @ game])
        col = np.concatenate([col, np.array([PANEL_COLOR, PANEL_COLOR], dtype=np.uint8)])

    world = origin + tri @ basis              # (N, 3, 3)
    fwd, right, up = world[..., 0], -world[..., 1], world[..., 2]

    def to_px(f, r, u):
        return (W / 2 + r / (f * tan_h) * W / 2, H / 2 - u / (f * tan_v) * H / 2)

    img = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(img)
    for yy in range(H):                       # «уровень»: небо и пол
        k = yy / H
        c = (int(70 + 60 * (1 - k)), int(85 + 60 * (1 - k)), int(105 + 70 * (1 - k))) if k < 0.55 else (int(60 + 30 * k), int(56 + 26 * k), int(50 + 20 * k))
        d.line([(0, yy), (W, yy)], fill=c)

    visible = (fwd > 1.0).all(axis=1)
    order = np.argsort(-fwd.mean(axis=1))
    for i in order:
        if visible[i]:
            d.polygon([to_px(fwd[i, k], right[i, k], up[i, k]) for k in range(3)], fill=tuple(int(x) for x in col[i]))

    cx, cy = W / 2, H / 2
    d.line([(cx - 10, cy), (cx + 10, cy)], fill=(255, 255, 255))
    d.line([(cx, cy - 10), (cx, cy + 10)], fill=(255, 255, 255))

    for name in ("muzzle", "screen", "screen_br"):
        if name not in atts:
            continue
        w = origin + (atts[name][0] @ game) @ basis
        f, r, u = w[0], -w[1], w[2]
        px, py = to_px(f, r, u)
        on = 0 <= px <= W and 0 <= py <= H and f > 1
        print("%-10s вперёд %6.1f  вправо %6.1f  вверх %6.1f  -> экран %4.0f%% x %4.0f%% %s" % (
            name, f, r, u, 100 * px / W, 100 * py / H, "" if on else "(за кадром)"))
        if on:
            d.ellipse([px - 4, py - 4, px + 4, py + 4], outline=(255, 80, 200))

    img.save(t.out)
    print("поворот studiomdl %.0f град.; кадр -> %s" % (rot, t.out))


if __name__ == "__main__":
    main()
