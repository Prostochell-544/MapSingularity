#!/usr/bin/env python3
"""
КПП «Лунь» — процедурный hard-surface меш по концепту «ГП-04 Прорив».

Чистая геометрия без булевых операций: каждая деталь собирается из колец вершин
(loft) — фаски экструзий, тела вращения, протяжки по кривой, торы. Корпус генератора —
оболочка с толщиной и вырезанными окнами с бортиками. Все детали замкнуты и
одинаково ориентированы (проверяется в отчёте).

Система координат Source: X — вперёд по стволу, Y — влево, Z — вверх; 1 юнит ≈ 1 дюйм.
Начало координат — над рукоятью, там, где оружие держит правая рука.

Запуск:  python tools/model/kpp_lun_mesh.py [--out art/kpp_lun]
         python tools/model/compile_lun.py   — компиляция и установка в аддон
Выход:   kpp_lun.obj + .mtl      — для Blender (импорт: Forward X, Up Z), с текстурами
         kpp_lun_ref.smd         — меш с костями по ТЗ (жёсткая привязка)
         kpp_lun.qc              — игровая модель map_singularity/kpp_lun.mdl
         materialsrc/, materials.json — текстуры и параметры VMT (kpp_lun_textures.py)
         preview.html + preview_data.js — 3D-превью в браузере
         report.txt              — статистика и проверка чистоты сетки
"""

import argparse
import json
import math
import os
from collections import defaultdict

import numpy as np

from kpp_lun_textures import TEX_DIR, write_all as write_textures

# --------------------------------------------------------------------------
# Материалы: имя (= имя VMT) -> цвет превью и параметры PBR для three.js
# --------------------------------------------------------------------------

MATERIALS = {
    "kpp_shell":    {"color": [0.38, 0.43, 0.38], "metal": 0.1, "rough": 0.55},   # молотковая эмаль
    "kpp_metal":    {"color": [0.20, 0.21, 0.22], "metal": 0.8, "rough": 0.45},
    "kpp_worn":     {"color": [0.52, 0.52, 0.50], "metal": 0.9, "rough": 0.35},
    "kpp_copper":   {"color": [0.78, 0.42, 0.20], "metal": 1.0, "rough": 0.30},
    "kpp_bakelite": {"color": [0.36, 0.22, 0.14], "metal": 0.0, "rough": 0.60},
    "kpp_hazard":   {"color": [0.92, 0.72, 0.10], "metal": 0.2, "rough": 0.50},
    "kpp_label":    {"color": [0.22, 0.23, 0.21], "metal": 0.1, "rough": 0.60},
    "kpp_rubber":   {"color": [0.12, 0.12, 0.13], "metal": 0.0, "rough": 0.80},
    "kpp_brass":    {"color": [0.72, 0.58, 0.30], "metal": 1.0, "rough": 0.35},
    "kpp_porcelain": {"color": [0.90, 0.88, 0.82], "metal": 0.0, "rough": 0.20},
    "kpp_tube":     {"color": [1.00, 0.55, 0.20], "metal": 0.0, "rough": 0.20, "emissive": [1.00, 0.50, 0.15]},
    "kpp_gauge":    {"color": [0.90, 0.88, 0.80], "metal": 0.0, "rough": 0.50},
    "kpp_note":     {"color": [0.90, 0.89, 0.84], "metal": 0.0, "rough": 0.90},
    "kpp_sticky":   {"color": [0.96, 0.87, 0.35], "metal": 0.0, "rough": 0.90},
    "kpp_warn":     {"color": [0.36, 0.42, 0.37], "metal": 0.1, "rough": 0.60},
    "kpp_tape":     {"color": [0.16, 0.27, 0.63], "metal": 0.0, "rough": 0.40},
    "kpp_led":      {"color": [1.00, 0.35, 0.15], "metal": 0.0, "rough": 0.30, "emissive": [1.00, 0.35, 0.15]},
    "kpp_screen":   {"color": [0.04, 0.14, 0.10], "metal": 0.0, "rough": 0.10, "emissive": [0.05, 0.35, 0.22]},
    "kpp_glow":     {"color": [0.35, 0.70, 1.00], "metal": 0.0, "rough": 0.30, "emissive": [0.35, 0.65, 1.00]},
    "kpp_orb":      {"color": [0.85, 0.80, 1.00], "metal": 0.0, "rough": 0.10, "emissive": [0.75, 0.60, 1.00]},
}

# Кости по ТЗ (docs/MODEL-SPEC-LUN.md): имя -> (родитель, позиция)
BONES = [
    ("lun_root", None, (0.0, 0.0, 0.0)),
    ("lun_claw_1", "lun_root", None),
    ("lun_claw_2", "lun_root", None),
    ("lun_claw_3", "lun_root", None),
    ("lun_generator", "lun_root", (9.5, 0.0, 0.5)),
    ("lun_screen", "lun_root", (-0.5, 0.0, 5.1)),
    ("lun_trigger", "lun_root", (-2.4, 0.0, -1.3)),
    ("lun_mag", "lun_root", (0.2, 0.0, -1.3)),
    ("lun_needle", "lun_root", (2.4, 1.57, 1.55)),
]

# --------------------------------------------------------------------------
# Базовая геометрия
# --------------------------------------------------------------------------

def unit(v):
    v = np.asarray(v, float)
    n = np.linalg.norm(v)
    return v / n if n > 1e-12 else v


def perpendicular_basis(axis):
    x = unit(axis)
    helper = np.array([0.0, 0.0, 1.0]) if abs(x[2]) < 0.9 else np.array([0.0, 1.0, 0.0])
    y = unit(np.cross(helper, x))
    z = np.cross(x, y)
    return x, y, z


class Part:
    """
    Деталь: вершины, полигоны (списки индексов), материал, кость, угол сглаживания.
    uv_fit — (ось u, ось v): UV не плиткой, а растянутой на деталь проекцией (для табличек).
    """

    def __init__(self, name, mat, bone="lun_root", smooth=35.0, closed=True, uv_fit=None):
        self.name, self.mat, self.bone, self.smooth, self.closed = name, mat, bone, smooth, closed
        self.uv_fit = uv_fit
        self.V = []
        self.F = []

    def vert(self, p):
        self.V.append(np.asarray(p, float))
        return len(self.V) - 1

    def verts(self, pts):
        return [self.vert(p) for p in pts]

    def face(self, idx):
        self.F.append(list(idx))


def loft(part, rings, closed_seq=False, cap_start=True, cap_end=True):
    """Соединяет кольца одинаковой длины квадами; торцы — n-угольники."""
    ids = [part.verts(r) for r in rings]
    k, n = len(rings[0]), len(rings)
    for i in range(n if closed_seq else n - 1):
        a, b = ids[i], ids[(i + 1) % n]
        for j in range(k):
            j2 = (j + 1) % k
            part.face([a[j], a[j2], b[j2], b[j]])
    if not closed_seq:
        if cap_start:
            part.face(list(reversed(ids[0])))
        if cap_end:
            part.face(list(ids[-1]))
    return ids


# ---- 2D-профили -----------------------------------------------------------

def signed_area(poly):
    return 0.5 * sum(poly[i][0] * poly[(i + 1) % len(poly)][1] - poly[(i + 1) % len(poly)][0] * poly[i][1]
                     for i in range(len(poly)))


def ccw(poly):
    poly = [tuple(map(float, p)) for p in poly]
    return poly if signed_area(poly) > 0 else list(reversed(poly))


def offset_polygon(poly, d):
    """Сдвиг контура (CCW) наружу (d > 0) или внутрь (d < 0) с ограничением углов."""
    n = len(poly)
    out = []
    for i in range(n):
        p0, p1, p2 = np.array(poly[i - 1]), np.array(poly[i]), np.array(poly[(i + 1) % n])
        e1, e2 = unit(p1 - p0), unit(p2 - p1)
        n1, n2 = np.array([e1[1], -e1[0]]), np.array([e2[1], -e2[0]])
        denom = max(1.0 + float(np.dot(n1, n2)), 0.25)
        out.append(tuple(p1 + d * (n1 + n2) / denom))
    return out


def chamfer_rect(w, h, c, cx=0.0, cy=0.0):
    x, y = w / 2, h / 2
    c = min(c, x * 0.45, y * 0.45)
    pts = [(-x + c, -y), (x - c, -y), (x, -y + c), (x, y - c), (x - c, y), (-x + c, y), (-x, y - c), (-x, -y + c)]
    return [(px + cx, py + cy) for px, py in pts]


def chamfer_poly(poly, c):
    """Скашивает углы произвольного контура на длину c."""
    poly = ccw(poly)
    out = []
    n = len(poly)
    for i in range(n):
        p0, p1, p2 = np.array(poly[i - 1]), np.array(poly[i]), np.array(poly[(i + 1) % n])
        l1, l2 = np.linalg.norm(p1 - p0), np.linalg.norm(p2 - p1)
        cc = min(c, l1 * 0.4, l2 * 0.4)
        out.append(tuple(p1 + unit(p0 - p1) * cc))
        out.append(tuple(p1 + unit(p2 - p1) * cc))
    return out


def circle2d(r, n, phase=0.0):
    return [(r * math.cos(phase + 2 * math.pi * i / n), r * math.sin(phase + 2 * math.pi * i / n)) for i in range(n)]


# ---- 3D-примитивы -----------------------------------------------------------

def extrude(part, poly, depth, chamfer, origin, U, V, W):
    """Экструзия контура (в плоскости U,V) на глубину вдоль W с фаской по торцам."""
    poly = ccw(poly)
    origin, U, V, W = map(lambda a: np.asarray(a, float), (origin, U, V, W))
    c = min(chamfer, depth * 0.45)

    def place(pts, w):
        return [origin + u * U + v * V + w * W for (u, v) in pts]

    if c > 1e-6:
        inner = offset_polygon(poly, -c)
        rings = [place(inner, -depth / 2), place(poly, -depth / 2 + c), place(poly, depth / 2 - c), place(inner, depth / 2)]
    else:
        rings = [place(poly, -depth / 2), place(poly, depth / 2)]
    loft(part, rings)


def side_extrude(part, poly_xz, depth, chamfer, y=0.0):
    """Деталь по боковому профилю (X,Z), толщина по Y."""
    extrude(part, poly_xz, depth, chamfer, (0, y, 0), (1, 0, 0), (0, 0, 1), (0, 1, 0))


def revolve(part, profile, n, origin=(0, 0, 0), axis=(1, 0, 0), closed_profile=False, caps=True, phase=0.0):
    """Тело вращения: profile — точки (t, r) вдоль оси."""
    X, Y, Z = perpendicular_basis(axis)
    origin = np.asarray(origin, float)
    rings = []
    for t, r in profile:
        rings.append([origin + X * t + (Y * math.cos(phase + 2 * math.pi * j / n) + Z * math.sin(phase + 2 * math.pi * j / n)) * r
                      for j in range(n)])
    loft(part, rings, closed_seq=closed_profile, cap_start=caps and not closed_profile, cap_end=caps and not closed_profile)


def cylinder(part, x0, x1, r, n=24, chamfer=0.0, origin=(0, 0, 0), axis=(1, 0, 0)):
    c = min(chamfer, r * 0.4, (x1 - x0) * 0.4)
    prof = [(x0, r - c), (x0 + c, r), (x1 - c, r), (x1, r - c)] if c > 1e-6 else [(x0, r), (x1, r)]
    revolve(part, prof, n, origin, axis)


def sweep(part, profile, path, up, closed_path=False, caps=True):
    """Протяжка контура (u — по проекции up, v — по бинормали) вдоль пути."""
    profile = ccw(profile)
    path = [np.asarray(p, float) for p in path]
    up = unit(up)
    n = len(path)
    rings = []
    for i in range(n):
        if closed_path:
            t = path[(i + 1) % n] - path[i - 1]
        else:
            t = path[min(i + 1, n - 1)] - path[max(i - 1, 0)]
        t = unit(t)
        nrm = up - np.dot(up, t) * t
        if np.linalg.norm(nrm) < 1e-6:
            nrm = perpendicular_basis(t)[1]
        nrm = unit(nrm)
        b = np.cross(t, nrm)
        rings.append([path[i] + nrm * u + b * v for (u, v) in profile])
    loft(part, rings, closed_seq=closed_path, cap_start=caps and not closed_path, cap_end=caps and not closed_path)


def torus(part, center, axis, R, r, n=40, m=10):
    X, Y, Z = perpendicular_basis(axis)
    c = np.asarray(center, float)
    path = [c + (Y * math.cos(2 * math.pi * i / n) + Z * math.sin(2 * math.pi * i / n)) * R for i in range(n)]
    sweep(part, circle2d(r, m), path, X, closed_path=True)


def sphere(part, center, r, n=28, m=14):
    c = np.asarray(center, float)
    top = part.vert(c + np.array([0, 0, r]))
    bottom = part.vert(c - np.array([0, 0, r]))
    rows = []
    for i in range(1, m):
        phi = math.pi * i / m
        rows.append(part.verts([c + r * np.array([math.sin(phi) * math.cos(2 * math.pi * j / n),
                                                  math.sin(phi) * math.sin(2 * math.pi * j / n),
                                                  math.cos(phi)]) for j in range(n)]))
    for j in range(n):
        j2 = (j + 1) % n
        part.face([top, rows[0][j], rows[0][j2]])
        part.face([bottom, rows[-1][j2], rows[-1][j]])
    for i in range(len(rows) - 1):
        a, b = rows[i], rows[i + 1]
        for j in range(n):
            j2 = (j + 1) % n
            part.face([a[j], b[j], b[j2], a[j2]])


def shell_with_windows(part, xs, radius_fn, thetas, thickness, windows, origin=(0, 0, 0)):
    """
    Оболочка вращения вокруг X с толщиной и прямоугольными (в координатах x, θ) окнами.
    xs и thetas должны содержать границы окон как узлы. windows — [(x0, x1, th0, th1)].
    Окна и открытые торцы получают бортики, так что оболочка замкнута.
    """
    o = np.asarray(origin, float)
    nx, nt = len(xs), len(thetas)

    def pt(x, th, r):
        return o + np.array([x, r * math.cos(th), r * math.sin(th)])

    O = [[part.vert(pt(x, th, radius_fn(x))) for th in thetas] for x in xs]
    I = [[part.vert(pt(x, th, radius_fn(x) - thickness)) for th in thetas] for x in xs]

    def removed(i, j):
        if i < 0 or i >= nx - 1:
            return None  # за торцом
        xm = 0.5 * (xs[i] + xs[i + 1])
        t0, t1 = thetas[j % nt], thetas[(j + 1) % nt]
        if t1 < t0:
            t1 += 2 * math.pi
        tm = 0.5 * (t0 + t1)
        for (x0, x1, a0, a1) in windows:
            if x0 <= xm <= x1:
                for shift in (0.0, 2 * math.pi, -2 * math.pi):
                    if a0 <= tm + shift <= a1:
                        return True
        return False

    for i in range(nx - 1):
        for j in range(nt):
            if removed(i, j):
                continue
            j2 = (j + 1) % nt
            part.face([O[i][j], O[i][j2], O[i + 1][j2], O[i + 1][j]])
            part.face([I[i][j], I[i + 1][j], I[i + 1][j2], I[i][j2]])
            # рёбра внешнего квада и соседи за ними
            edges = [
                ((i, j), (i, j2), (i - 1, j)),
                ((i, j2), (i + 1, j2), (i, j + 1)),
                ((i + 1, j2), (i + 1, j), (i + 1, j)),
                ((i + 1, j), (i, j), (i, j - 1)),
            ]
            for (a, b, nb) in edges:
                state = removed(nb[0], nb[1] % nt)
                if state is None or state is True:
                    oa, ob = O[a[0]][a[1]], O[b[0]][b[1]]
                    ia, ib = I[a[0]][a[1]], I[b[0]][b[1]]
                    part.face([ob, oa, ia, ib])


# --------------------------------------------------------------------------
# Модель «Луня»
# --------------------------------------------------------------------------

# Бак: почти цилиндр со скруглёнными торцами (высокая степень), уменьшен по просьбе пользователя.
SHELL_XC, SHELL_HALF, SHELL_R, SHELL_P = 9.5, 5.3, 2.6, 6.0
SHELL_Z = 0.5
SHELL_X0, SHELL_X1 = 4.2, 14.8
WIN_X0, WIN_X1, WIN_HALF = 6.0, 13.0, 0.75


def shell_radius(x):
    k = min(abs(x - SHELL_XC) / SHELL_HALF, 0.999)
    return SHELL_R * (1.0 - k ** SHELL_P) ** (1.0 / SHELL_P)


def build():
    parts = []

    def P(name, mat, bone="lun_root", smooth=35.0, uv_fit=None):
        p = Part(name, mat, bone, smooth, uv_fit=uv_fit)
        parts.append(p)
        return p

    # ---- Ствольная коробка, планка, маркировочные пластины -----------------
    receiver = [(-6.5, -1.3), (4.0, -1.3), (4.6, -0.7), (4.6, 1.8), (4.1, 2.3), (-6.0, 2.3), (-6.5, 1.8)]
    side_extrude(P("receiver", "kpp_metal"), receiver, 2.4, 0.18)

    # Ручка для переноски из гнутой трубы (как у лабораторных приборов) вместо планки;
    # стойка экрана стоит на ней.
    handle = P("carry_handle", "kpp_worn", smooth=60)
    sweep(handle, circle2d(0.26, 10), bezier((-5.6, 0, 2.2), (-5.6, 0, 3.0), (-5.2, 0, 3.35), (-1.1, 0, 3.35), 10), (0, 1, 0))
    sweep(handle, circle2d(0.26, 10), bezier((0.3, 0, 3.35), (2.8, 0, 3.35), (3.4, 0, 3.0), (3.4, 0, 2.2), 10), (0, 1, 0))
    feet = P("handle_feet", "kpp_metal")
    for x in (-5.6, 3.4):
        side_extrude(feet, chamfer_rect(1.0, 0.35, 0.08, cx=x, cy=2.45), 0.9, 0.08)

    for side in (1, -1):
        extrude(P("hazard_plate_%s" % ("l" if side > 0 else "r"), "kpp_hazard"),
                chamfer_rect(4.2, 0.5, 0.05, cx=-1.2, cy=1.55), 0.08, 0.02,
                (0, side * 1.22, 0), (1, 0, 0), (0, 0, 1), (0, 1, 0))

    # Табличка «КПП-04 // ВИРІБ «ЛУНЬ»» на обеих сторонах коробки. Текст читается снаружи:
    # слева (+Y) строка идёт к прикладу (-X), справа (-Y) — к стволу (+X).
    for side in (1, -1):
        extrude(P("label_%s" % ("l" if side > 0 else "r"), "kpp_label", smooth=10,
                  uv_fit=((-side, 0, 0), (0, 0, 1))),
                chamfer_rect(4.4, 1.1, 0.06, cx=-3.5, cy=0.15), 0.06, 0.015,
                (0, side * 1.23, 0), (1, 0, 0), (0, 0, 1), (0, 1, 0))

    # ---- Магазин-батарея со светящимися полосками ---------------------------
    # Батарея: эмалированный корпус, дно, латунные клеммы спереди, окошко заряда по бокам.
    side_extrude(P("battery", "kpp_shell", "lun_mag"), chamfer_rect(2.9, 4.6, 0.3, cx=0.1, cy=-3.5), 1.9, 0.2)
    side_extrude(P("battery_cap", "kpp_metal", "lun_mag"), chamfer_rect(3.1, 0.4, 0.1, cx=0.1, cy=-5.85), 2.05, 0.1)
    terminals = P("battery_terminals", "kpp_brass", "lun_mag", smooth=50)
    for y in (0.45, -0.45):
        cylinder(terminals, -0.02, 0.3, 0.17, n=12, chamfer=0.04, origin=(1.55, y, -2.1), axis=(1, 0, 0))
        cylinder(terminals, 0.3, 0.42, 0.24, n=6, chamfer=0.03, origin=(1.55, y, -2.1), axis=(1, 0, 0))
    for side in (1, -1):
        extrude(P("mag_glow_%s" % ("l" if side > 0 else "r"), "kpp_glow", "lun_mag"),
                chamfer_rect(0.5, 3.0, 0.08, cx=0.6, cy=-3.6), 0.06, 0.0, (0, side * 0.97, 0), (1, 0, 0), (0, 0, 1), (0, 1, 0))

    # ---- Рукоять, спуск, скоба --------------------------------------------
    grip = [(-5.7, -1.25), (-3.7, -1.25), (-5.2, -5.9), (-6.6, -6.1), (-7.4, -5.5)]
    side_extrude(P("grip", "kpp_bakelite"), chamfer_poly(grip, 0.45), 1.5, 0.25)

    guard_path = [(-3.6, 0, -1.25), (-3.65, 0, -2.15), (-3.35, 0, -2.65), (-2.4, 0, -2.75), (-1.75, 0, -2.6), (-1.55, 0, -2.1), (-1.5, 0, -1.25)]
    sweep(P("trigger_guard", "kpp_metal"), chamfer_rect(0.5, 0.22, 0.05), guard_path, (0, 1, 0))

    trig_path = [(-2.35, 0, -1.25), (-2.45, 0, -1.75), (-2.7, 0, -2.15), (-2.95, 0, -2.3)]
    sweep(P("trigger", "kpp_worn", "lun_trigger"), chamfer_rect(0.32, 0.16, 0.04), trig_path, (0, 1, 0))

    # ---- Скелетный приклад --------------------------------------------------
    # ---- Силовой блок вместо приклада: радиатор, фарфоровые изоляторы, кабель к баку -----
    side_extrude(P("power_block", "kpp_shell"), chamfer_rect(5.0, 3.0, 0.35, cx=-9.0, cy=0.5), 2.8, 0.25)
    side_extrude(P("power_bumper", "kpp_rubber", smooth=20), chamfer_rect(0.4, 2.6, 0.12, cx=-11.65, cy=0.5), 2.4, 0.12)
    fins = P("power_fins", "kpp_metal", smooth=20)
    for x in np.arange(-11.0, -6.99, 0.5):
        for side in (1, -1):
            extrude(fins, chamfer_rect(0.14, 2.4, 0.03, cx=x, cy=0.5), 0.5, 0.03, (0, side * 1.6, 0), (1, 0, 0), (0, 0, 1), (0, 1, 0))
    insulator_profile = [(0.0, 0.42), (0.15, 0.42), (0.2, 0.3), (0.35, 0.55), (0.5, 0.3), (0.65, 0.55),
                         (0.8, 0.3), (0.95, 0.5), (1.1, 0.28), (1.25, 0.28)]
    for y in (0.7, -0.7):
        revolve(P("insulator_%s" % ("l" if y > 0 else "r"), "kpp_porcelain", smooth=50), insulator_profile, 16,
                (-9.8, y, 2.0), (0, 0, 1))
        term = P("insulator_terminal_%s" % ("l" if y > 0 else "r"), "kpp_brass", smooth=50)
        cylinder(term, 1.2, 1.55, 0.18, n=12, chamfer=0.04, origin=(-9.8, y, 2.0), axis=(0, 0, 1))
        cylinder(term, 1.3, 1.45, 0.27, n=6, chamfer=0.03, origin=(-9.8, y, 2.0), axis=(0, 0, 1))
    power_cable = bezier((-9.8, -0.7, 3.5), (-8.0, -2.6, 3.8), (1.5, -2.3, 2.9), (5.2, -1.4, 2.0), 20)
    sweep(P("power_cable", "kpp_rubber", smooth=70), circle2d(0.3, 10), power_cable, (0, 0, 1))
    cylinder(P("power_cable_sleeve", "kpp_worn", smooth=50), -0.45, 0.05, 0.4, n=14, chamfer=0.06,
             origin=power_cable[-1], axis=unit(power_cable[-1] - power_cable[-2]))
    tape_wraps(P("power_cable_tape", "kpp_tape", smooth=60), power_cable, (6, 13), 0.3)

    # ---- Экран сверху: стойка, корпус, стекло, кабель -----------------------
    side_extrude(P("screen_post", "kpp_metal"), chamfer_rect(1.4, 1.1, 0.12, cx=-0.4, cy=3.15), 0.9, 0.1)
    extrude(P("screen_box", "kpp_metal", "lun_screen"), chamfer_rect(6.0, 3.1, 0.35, cy=5.15), 1.1, 0.15,
            (-0.5, 0, 0), (0, 1, 0), (0, 0, 1), (1, 0, 0))
    extrude(P("screen_glass", "kpp_screen", "lun_screen", smooth=10), [(-2.5, 3.9), (2.5, 3.9), (2.5, 6.4), (-2.5, 6.4)], 0.08, 0.0,
            (-1.07, 0, 0), (0, 1, 0), (0, 0, 1), (1, 0, 0))
    cylinder(P("screen_knob", "kpp_worn", "lun_screen"), 0, 0.5, 0.22, n=12, chamfer=0.05, origin=(-0.2, -2.2, 6.7), axis=(0, 0, 1))

    cable = []
    for k in range(17):
        t = k / 16
        p0, p1, p2, p3 = np.array([-0.2, 2.2, 3.7]), np.array([0.8, 3.6, 3.0]), np.array([2.8, 3.1, 2.0]), np.array([3.6, 1.2, 1.6])
        cable.append((1 - t) ** 3 * p0 + 3 * (1 - t) ** 2 * t * p1 + 3 * (1 - t) * t ** 2 * p2 + t ** 3 * p3)
    sweep(P("screen_cable", "kpp_bakelite", smooth=60), circle2d(0.16, 8), cable, (0, 0, 1))

    # ---- Генератор: оболочка с окнами, ремни, ядро с катушками ---------------
    xs = sorted(set([round(x, 4) for x in np.linspace(SHELL_X0, SHELL_X1, 23)] + [WIN_X0, WIN_X1]))
    thetas = []
    for (a0, a1, segs) in ((-WIN_HALF, WIN_HALF, 8), (WIN_HALF, math.pi - WIN_HALF, 9),
                           (math.pi - WIN_HALF, math.pi + WIN_HALF, 8), (math.pi + WIN_HALF, 2 * math.pi - WIN_HALF, 9)):
        thetas += [a0 + (a1 - a0) * s / segs for s in range(segs)]
    windows = [(WIN_X0, WIN_X1, -WIN_HALF, WIN_HALF), (WIN_X0, WIN_X1, math.pi - WIN_HALF, math.pi + WIN_HALF)]
    shell_with_windows(P("generator_shell", "kpp_shell", smooth=40), xs, shell_radius, thetas, 0.22, windows, origin=(0, 0, SHELL_Z))

    for x in (WIN_X0 - 0.45, WIN_X1 + 0.45):
        torus(P("shell_band_%d" % int(x * 10), "kpp_worn", smooth=60), (x, 0, SHELL_Z), (1, 0, 0), shell_radius(x) + 0.08, 0.17, n=48, m=8)
    for z_sign in (1, -1):
        strap = [(x, 0, SHELL_Z + z_sign * (shell_radius(x) + 0.07)) for x in np.linspace(SHELL_X0 + 0.3, SHELL_X1 - 0.3, 24)]
        sweep(P("shell_strap_%s" % ("top" if z_sign > 0 else "bottom"), "kpp_worn", smooth=40), chamfer_rect(0.7, 0.14, 0.03), strap, (0, 1, 0))

    # Колба с плазмой по оси бака.
    cylinder(P("generator_core", "kpp_glow", "lun_generator", smooth=50), WIN_X0 - 0.5, WIN_X1 + 0.5, 0.85, n=24, chamfer=0.25, origin=(0, 0, SHELL_Z))
    # Ротор: три латунные лопатки вокруг колбы — несимметричная деталь, вращение будет видно.
    vanes = P("generator_vanes", "kpp_brass", "lun_generator", smooth=20)
    for k in range(3):
        a = k * 2 * math.pi / 3
        radial = np.array([0.0, math.cos(a), math.sin(a)])
        tangential = np.array([0.0, -math.sin(a), math.cos(a)])
        extrude(vanes, chamfer_rect(2.6, 0.45, 0.08), 0.12, 0.03, np.array([9.5, 0, SHELL_Z]) + radial * 1.1, (1, 0, 0), radial, tangential)
    # Радиолампы на шасси по бокам, видны в окна.
    for side in (1, -1):
        extrude(P("tube_chassis_%s" % ("l" if side > 0 else "r"), "kpp_metal"), chamfer_rect(4.4, 0.5, 0.08, cx=9.5, cy=side * 1.7),
                0.1, 0.03, (0, 0, SHELL_Z - 1.45), (1, 0, 0), (0, 1, 0), (0, 0, 1))
        sockets = P("tube_sockets_%s" % ("l" if side > 0 else "r"), "kpp_metal", smooth=50)
        glass = P("tubes_%s" % ("l" if side > 0 else "r"), "kpp_tube", smooth=60)
        for x in (8.2, 9.5, 10.8):
            base = np.array([x, side * 1.7, SHELL_Z - 1.4])
            cylinder(sockets, 0, 0.25, 0.34, n=12, chamfer=0.04, origin=base, axis=(0, 0, 1))
            cylinder(glass, 0.25, 1.05, 0.26, n=12, origin=base, axis=(0, 0, 1))
            sphere(glass, base + np.array([0, 0, 1.05]), 0.26, n=12, m=6)
    # Катушки — парами у краёв окна, чтобы в середине было видно светящееся ядро.
    coils = P("generator_coils", "kpp_copper", "lun_generator", smooth=60)
    for x in (6.5, 7.25, 11.75, 12.5):
        torus(coils, (x, 0, SHELL_Z), (1, 0, 0), 1.75, 0.24, n=32, m=8)
    for x in (WIN_X0 - 0.6, WIN_X1 + 0.6):
        cylinder(P("core_cap_%d" % int(x * 10), "kpp_metal", "lun_generator"), x - 0.25, x + 0.25, 2.05, n=32, chamfer=0.08, origin=(0, 0, SHELL_Z))

    # ---- Ствол: муфты, труба, спираль-катушка, тяги, излучатель ------------
    revolve(P("barrel_collar", "kpp_metal"), [(14.4, 1.2), (14.5, 2.0), (15.5, 2.0), (15.7, 1.4), (15.7, 1.0)], 32, (0, 0, SHELL_Z))
    cylinder(P("barrel_tube", "kpp_metal"), 15.6, 24.0, 0.85, n=24, chamfer=0.08, origin=(0, 0, SHELL_Z))

    helix = []
    turns, segs_per_turn, hx0, hx1 = 13, 12, 16.2, 21.8
    for k in range(turns * segs_per_turn + 1):
        a = 2 * math.pi * k / segs_per_turn
        x = hx0 + (hx1 - hx0) * k / (turns * segs_per_turn)
        helix.append((x, 1.22 * math.cos(a), SHELL_Z + 1.22 * math.sin(a)))
    sweep(P("barrel_coil", "kpp_copper", smooth=70), circle2d(0.16, 6), helix, (1, 0, 0))

    for x in (16.0, 22.0):
        revolve(P("barrel_ring_%d" % int(x), "kpp_worn"), [(x - 0.3, 0.8), (x - 0.25, 1.75), (x + 0.25, 1.75), (x + 0.3, 0.8)], 32, (0, 0, SHELL_Z))
    rods = P("barrel_rods", "kpp_worn", smooth=60)
    for k in range(4):
        a = math.pi / 4 + k * math.pi / 2
        cylinder(rods, 15.6, 23.7, 0.16, n=10, chamfer=0.04, origin=(0, 1.65 * math.cos(a), SHELL_Z + 1.65 * math.sin(a)))

    revolve(P("emitter", "kpp_worn"), [(23.6, 0.7), (23.7, 2.15), (24.0, 2.35), (24.5, 2.35), (24.7, 2.0), (24.7, 0.9)], 40, (0, 0, SHELL_Z))

    # ---- Три когтя-захвата и шар ------------------------------------------
    claw_path_rt = [(24.3, 1.95), (25.3, 3.15), (26.6, 3.85), (28.1, 3.75), (29.3, 3.05), (30.0, 2.25), (30.2, 1.85)]
    for k in range(3):
        a = math.radians(90 + 120 * k)
        radial = np.array([0.0, math.cos(a), math.sin(a)])
        tangential = np.array([0.0, -math.sin(a), math.cos(a)])
        bone = "lun_claw_%d" % (k + 1)
        path = [np.array([x, 0, SHELL_Z]) + radial * r for (x, r) in claw_path_rt]
        sweep(P("claw_%d" % (k + 1), "kpp_worn", bone), chamfer_rect(1.25, 0.6, 0.14), path, tangential)
        band = np.array([27.4, 0, SHELL_Z]) + radial * 3.85
        cylinder(P("claw_band_%d" % (k + 1), "kpp_metal", bone), -0.75, 0.75, 0.4, n=12, chamfer=0.06, origin=band, axis=tangential)
        hinge = np.array([24.3, 0, SHELL_Z]) + radial * 1.95
        cylinder(P("claw_knuckle_%d" % (k + 1), "kpp_metal", bone), -0.75, 0.75, 0.55, n=16, chamfer=0.08, origin=hinge, axis=tangential)

    sphere(P("orb", "kpp_orb", smooth=80), (27.3, 0, SHELL_Z), 1.0, n=28, m=14)

    build_details(P)
    return parts


def tape_wraps(part, path, indices, radius):
    """Витки изоленты на кабеле: короткие муфты чуть толще кабеля в точках пути."""
    for i in indices:
        axis = unit(path[min(i + 1, len(path) - 1)] - path[max(i - 1, 0)])
        cylinder(part, -0.2, 0.2, radius + 0.05, n=12, chamfer=0.03, origin=path[i], axis=axis)


def rot_rect(w, h, deg, cx=0.0, cy=0.0):
    """Прямоугольник w x h, повёрнутый на deg, с центром (cx, cy) — для наклеек «как пришлось»."""
    a = math.radians(deg)
    c, s = math.cos(a), math.sin(a)
    return [(cx + x * c - y * s, cy + x * s + y * c) for (x, y) in ((-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2))]


def bolt(part, center, normal, r=0.13, h=0.08):
    """Шестигранная головка болта: чуть утоплена в поверхность, выступает на h по нормали."""
    cylinder(part, -0.03, h, r, n=6, chamfer=min(0.025, r * 0.2), origin=center, axis=normal)


def shell_point(x, theta, lift=0.0):
    """Точка на кожухе генератора (угол от +Y к +Z) и нормаль/касательная там."""
    r = shell_radius(x) + lift
    normal = np.array([0.0, math.cos(theta), math.sin(theta)])
    tangent = np.array([0.0, -math.sin(theta), math.cos(theta)])
    return np.array([x, 0.0, SHELL_Z]) + normal * r, normal, tangent


def bezier(p0, p1, p2, p3, n=16):
    p0, p1, p2, p3 = (np.asarray(p, float) for p in (p0, p1, p2, p3))
    return [(1 - t) ** 3 * p0 + 3 * (1 - t) ** 2 * t * p1 + 3 * (1 - t) * t ** 2 * p2 + t ** 3 * p3
            for t in np.linspace(0, 1, n + 1)]


def build_details(P):
    """
    Мелкие детали, которые делают силуэт и поверхности «живыми»: болты, лючки, решётки,
    радиатор на кожухе, шланги от батареи к генератору, козырёк и кнопки экрана,
    поршни когтей, батарея конденсаторов под стволом.
    """
    bolts = P("bolts", "kpp_worn", smooth=50)
    for side in (1, -1):
        n = (0, side, 0)
        # Ствольная коробка: углы, крепёж таблички, лючок с прорезями.
        for (x, z) in ((-6.0, 1.9), (-6.0, -0.9), (4.05, 1.55), (4.05, -0.55)):
            bolt(bolts, (x, side * 1.2, z), n, r=0.14)
        for (x, z) in ((-5.5, 0.53), (-1.5, 0.53), (-5.5, -0.23), (-1.5, -0.23)):
            bolt(bolts, (x, side * 1.26, z), n, r=0.075, h=0.05)
        extrude(P("access_panel_%s" % ("l" if side > 0 else "r"), "kpp_metal", smooth=10),
                chamfer_rect(3.0, 1.6, 0.14, cx=2.3, cy=0.1), 0.1, 0.03, (0, side * 1.25, 0), (1, 0, 0), (0, 0, 1), (0, 1, 0))
        for (x, z) in ((0.98, 0.72), (3.62, 0.72), (0.98, -0.52), (3.62, -0.52)):
            bolt(bolts, (x, side * 1.3, z), n, r=0.085, h=0.05)
        slots = P("access_slots_%s" % ("l" if side > 0 else "r"), "kpp_rubber", smooth=10)
        for z in (0.42, 0.17, -0.08, -0.33):
            extrude(slots, chamfer_rect(1.7, 0.11, 0.03, cx=2.3, cy=z), 0.05, 0.0, (0, side * 1.31, 0), (1, 0, 0), (0, 0, 1), (0, 1, 0))
        # Бока экрана и силового блока.
        for (x, z) in ((-11.0, 1.75), (-7.0, 1.75), (-11.0, -0.75), (-7.0, -0.75)):
            bolt(bolts, (x, side * 1.4, z), n, r=0.14, h=0.08)
        for (x, z) in ((-0.5, 3.95), (-0.5, 6.35)):
            bolt(bolts, (x, side * 3.0, z), n, r=0.12, h=0.07)

    # Болты по бандажам кожуха и по муфте ствола.
    for x in (WIN_X0 - 0.45, WIN_X1 + 0.45):
        for k in range(8):
            th = math.pi / 8 + k * math.pi / 4
            c, nrm, _ = shell_point(x, th, 0.2)
            bolt(bolts, c, nrm, r=0.14, h=0.1)
    for k in range(6):
        th = k * math.pi / 3 + math.pi / 6
        nrm = np.array([0.0, math.cos(th), math.sin(th)])
        bolt(bolts, np.array([15.0, 0, SHELL_Z]) + nrm * 2.0, nrm, r=0.13, h=0.08)

    # ---- «История»: записка, стикер на экране, трафарет на баке, изолента -----------------
    # Записка от руки на крышке силового блока (между изоляторами и коробкой); читается сверху-сзади.
    extrude(P("note_power", "kpp_note", smooth=10, uv_fit=((0, -1, 0), (1, 0, 0))),
            rot_rect(1.2, 1.6, 6, cx=-8.0, cy=0.0), 0.02, 0.0, (0, 0, 2.01), (1, 0, 0), (0, 1, 0), (0, 0, 1))
    # Стикер внизу экрана, правее центра (у правого угла проходит силовой кабель): чуть ближе
    # к стрелку, чем панель прибора, — заслоняет её край.
    extrude(P("note_screen", "kpp_sticky", "lun_screen", smooth=10, uv_fit=((0, -1, 0), (0, 0, 1))),
            rot_rect(1.1, 1.1, -8, cx=-1.3, cy=3.55), 0.02, 0.0, (-1.16, 0, 0), (0, 1, 0), (0, 0, 1), (1, 0, 0))
    # Трафарет «ВИСОКА НАПРУГА» на верхнем левом скате бака.
    th = 1.15
    c, nrm, tan = shell_point(SHELL_XC, th, 0.05)
    extrude(P("warn_tank", "kpp_warn", smooth=10, uv_fit=((-1, 0, 0), tuple(tan))),
            chamfer_rect(2.4, 1.2, 0.05), 0.02, 0.0, c, (1, 0, 0), tan, nrm)
    # Изолента на кабеле экрана и шлангах.
    tape_wraps(P("screen_cable_tape", "kpp_tape", smooth=60),
               bezier((-0.2, 2.2, 3.7), (0.8, 3.6, 3.0), (2.8, 3.1, 2.0), (3.6, 1.2, 1.6)), (9,), 0.16)

    # Заклёпки по торцам бака.
    rivets = P("shell_rivets", "kpp_worn", smooth=50)
    for x in (SHELL_X0 + 0.9, SHELL_X1 - 0.9):
        for k in range(14):
            c, nrm, _ = shell_point(x, k * 2 * math.pi / 14 + 0.1, 0.0)
            bolt(rivets, c, nrm, r=0.1, h=0.06)

    # Стрелочный прибор «напруженість поля» на левом боку коробки; стрелка — на своей кости.
    gauge_c = np.array([2.4, 1.2, 1.55])
    cylinder(P("gauge_body", "kpp_metal", smooth=40), 0, 0.3, 0.72, n=24, chamfer=0.06, origin=gauge_c, axis=(0, 1, 0))
    cylinder(P("gauge_face", "kpp_gauge", smooth=10, uv_fit=((-1, 0, 0), (0, 0, 1))), 0.29, 0.33, 0.6, n=24, origin=gauge_c, axis=(0, 1, 0))
    torus(P("gauge_bezel", "kpp_brass", smooth=60), gauge_c + np.array([0, 0.33, 0]), (0, 1, 0), 0.64, 0.07, n=24, m=6)
    extrude(P("gauge_needle", "kpp_led", "lun_needle", smooth=10), [(-0.035, -0.1), (0.035, -0.1), (0.012, 0.5), (-0.012, 0.5)],
            0.03, 0.0, gauge_c + np.array([0, 0.36, 0]), (1, 0, 0), (0, 0, 1), (0, 1, 0))

    # Шланги от магазина-батареи к низу генератора, с муфтами на концах.
    for side in (1, -1):
        path = bezier((1.62, side * 0.45, -3.2), (3.2, side * 0.5, -3.7), (5.6, side * 0.9, -3.0), (6.8, side * 0.9, -1.85))
        sweep(P("hose_%s" % ("l" if side > 0 else "r"), "kpp_rubber", smooth=70), circle2d(0.17, 10), path, (0, 0, 1))
        tape_wraps(P("hose_tape_%s" % ("l" if side > 0 else "r"), "kpp_tape", smooth=60), path, (8,), 0.17)
        sleeves = P("hose_sleeves_%s" % ("l" if side > 0 else "r"), "kpp_worn", smooth=50)
        cylinder(sleeves, -0.05, 0.35, 0.25, n=14, chamfer=0.05, origin=path[0], axis=unit(path[1] - path[0]))
        cylinder(sleeves, -0.35, 0.05, 0.25, n=14, chamfer=0.05, origin=path[-1], axis=unit(path[-1] - path[-2]))

    # Козырёк над экраном, кнопки и индикаторы на нём.
    extrude(P("screen_visor", "kpp_metal", "lun_screen", smooth=10), chamfer_rect(1.9, 6.2, 0.12, cx=-0.9), 0.14, 0.04,
            (0, 0, 6.78), (1, 0, 0), (0, 1, 0), (0, 0, 1))
    buttons = P("screen_buttons", "kpp_worn", "lun_screen", smooth=50)
    for y in (-1.45, -1.0):
        cylinder(buttons, 0, 0.1, 0.14, n=12, chamfer=0.03, origin=(-0.6, y, 6.84), axis=(0, 0, 1))
    leds = P("screen_leds", "kpp_led", "lun_screen", smooth=80)
    for y in (2.25, 1.85):
        sphere(leds, (-1.45, y, 6.87), 0.1, n=10, m=6)

    # Поршни когтей: гильза от кольца излучателя, шток к середине когтя (сбоку от него).
    for k in range(3):
        a = math.radians(90 + 120 * k)
        radial = np.array([0.0, math.cos(a), math.sin(a)])
        tangential = np.array([0.0, -math.sin(a), math.cos(a)])
        A = np.array([22.5, 0, SHELL_Z]) + radial * 1.85 + tangential * 0.6
        B = np.array([26.0, 0, SHELL_Z]) + radial * 3.45 + tangential * 0.6
        axis, length = unit(B - A), float(np.linalg.norm(B - A))
        piston = P("claw_piston_%d" % (k + 1), "kpp_metal", "lun_claw_%d" % (k + 1), smooth=50)
        cylinder(piston, 0, length * 0.55, 0.16, n=10, chamfer=0.03, origin=A, axis=axis)
        rod = P("claw_rod_%d" % (k + 1), "kpp_worn", "lun_claw_%d" % (k + 1), smooth=50)
        cylinder(rod, length * 0.45, length, 0.09, n=8, chamfer=0.02, origin=A, axis=axis)

    # Батарея конденсаторов под стволом: висит на кольцах ствола.
    caps = P("capacitors", "kpp_metal", smooth=50)
    ends = P("capacitor_ends", "kpp_worn", smooth=50)
    for (y, z) in ((-0.78, -1.62), (0.0, -1.66), (0.78, -1.62)):
        cylinder(caps, 15.9, 22.1, 0.36, n=16, chamfer=0.06, origin=(0, y, z))
        for x0 in (16.35, 21.35):
            cylinder(ends, x0, x0 + 0.3, 0.385, n=16, chamfer=0.04, origin=(0, y, z))

    # Муфты на концах кабеля экрана.
    cable = bezier((-0.2, 2.2, 3.7), (0.8, 3.6, 3.0), (2.8, 3.1, 2.0), (3.6, 1.2, 1.6))
    plugs = P("cable_plugs", "kpp_worn", smooth=50)
    cylinder(plugs, -0.05, 0.3, 0.24, n=12, chamfer=0.05, origin=cable[0], axis=unit(cable[1] - cable[0]))
    cylinder(plugs, -0.3, 0.05, 0.24, n=12, chamfer=0.05, origin=cable[-1], axis=unit(cable[-1] - cable[-2]))


# --------------------------------------------------------------------------
# Ориентация, нормали, UV, проверки
# --------------------------------------------------------------------------

def triangulate(poly_pts):
    """Отрезание ушей для плоского многоугольника (индексы в его локальном порядке)."""
    n = len(poly_pts)
    if n == 3:
        return [(0, 1, 2)]
    pts = np.array(poly_pts)
    normal = np.zeros(3)
    for i in range(n):
        a, b = pts[i], pts[(i + 1) % n]
        normal += np.array([(a[1] - b[1]) * (a[2] + b[2]), (a[2] - b[2]) * (a[0] + b[0]), (a[0] - b[0]) * (a[1] + b[1])])
    ax = int(np.argmax(np.abs(normal)))
    keep = [i for i in range(3) if i != ax]
    p2 = pts[:, keep]
    if normal[ax] < 0:
        p2 = p2[:, ::-1]

    def area2(a, b, c):
        return (p2[b][0] - p2[a][0]) * (p2[c][1] - p2[a][1]) - (p2[c][0] - p2[a][0]) * (p2[b][1] - p2[a][1])

    def inside(p, a, b, c):
        return area2(a, b, p) >= -1e-12 and area2(b, c, p) >= -1e-12 and area2(c, a, p) >= -1e-12

    idx = list(range(n))
    tris = []
    guard = 0
    while len(idx) > 3 and guard < 10000:
        guard += 1
        for k in range(len(idx)):
            a, b, c = idx[k - 1], idx[k], idx[(k + 1) % len(idx)]
            if area2(a, b, c) <= 1e-12:
                continue
            if any(inside(p, a, b, c) for p in idx if p not in (a, b, c)):
                continue
            tris.append((a, b, c))
            idx.pop(k)
            break
        else:
            tris += [(idx[0], idx[i], idx[i + 1]) for i in range(1, len(idx) - 1)]
            idx = []
            break
    if len(idx) == 3:
        tris.append(tuple(idx))
    return tris


def part_triangles(part):
    V = np.array(part.V)
    tris = []
    for f in part.F:
        for (a, b, c) in triangulate(V[f]):
            tris.append((f[a], f[b], f[c]))
    return V, tris


def orient(part):
    """Замкнутые детали разворачиваем так, чтобы объём был положительным (нормали наружу)."""
    V, tris = part_triangles(part)
    vol = sum(np.dot(V[a], np.cross(V[b], V[c])) for (a, b, c) in tris) / 6.0
    if vol < 0:
        part.F = [list(reversed(f)) for f in part.F]
    return abs(vol)


def check(part):
    edges = defaultdict(int)
    directed = defaultdict(int)
    degenerate = 0
    V = np.array(part.V)
    for f in part.F:
        if len(set(f)) < len(f):
            degenerate += 1
        for i in range(len(f)):
            a, b = f[i], f[(i + 1) % len(f)]
            edges[frozenset((a, b))] += 1
            directed[(a, b)] += 1
    boundary = sum(1 for c in edges.values() if c == 1)
    nonmanifold = sum(1 for c in edges.values() if c > 2)
    flipped = sum(1 for c in directed.values() if c > 1)
    _, tris = part_triangles(part)
    tiny = sum(1 for (a, b, c) in tris if np.linalg.norm(np.cross(V[b] - V[a], V[c] - V[a])) < 1e-9)
    quads = sum(1 for f in part.F if len(f) == 4)
    return {"verts": len(part.V), "faces": len(part.F), "quads": quads, "tris": len(tris),
            "boundary_edges": boundary, "nonmanifold_edges": nonmanifold, "flipped_edges": flipped,
            "degenerate_faces": degenerate + tiny}


def corner_data(part):
    """Треугольники с нормалями по углу сглаживания и UV по кубической проекции."""
    V, tris = part_triangles(part)
    fn = []
    for (a, b, c) in tris:
        fn.append(unit(np.cross(V[b] - V[a], V[c] - V[a])))
    by_vertex = defaultdict(list)
    for t, tri in enumerate(tris):
        for v in tri:
            by_vertex[v].append(t)
    cos_lim = math.cos(math.radians(part.smooth))
    fit = None
    if part.uv_fit:
        fu, fv = (np.asarray(a, float) for a in part.uv_fit)
        pu, pv = V @ fu, V @ fv
        fit = (fu, fv, pu.min(), pu.max() - pu.min(), pv.min(), pv.max() - pv.min())
    out = []
    for t, tri in enumerate(tris):
        n0 = fn[t]
        ax = int(np.argmax(np.abs(n0)))
        uv_axes = [i for i in range(3) if i != ax]
        corners = []
        for v in tri:
            acc = np.zeros(3)
            for t2 in by_vertex[v]:
                if np.dot(fn[t2], n0) >= cos_lim:
                    acc += fn[t2]
            nrm = unit(acc) if np.linalg.norm(acc) > 1e-9 else n0
            p = V[v]
            if fit:
                uv = ((p @ fit[0] - fit[2]) / fit[3], (p @ fit[1] - fit[4]) / fit[5])
            else:
                uv = (p[uv_axes[0]] / 8.0, p[uv_axes[1]] / 8.0)
            corners.append((p, nrm, uv))
        out.append(corners)
    return out


# --------------------------------------------------------------------------
# Экспорт
# --------------------------------------------------------------------------

def bone_positions(scale):
    pos = {name: (np.array(p, float) * scale if p is not None else None) for name, _, p in BONES}
    for k in range(3):
        a = math.radians(90 + 120 * k)
        pos["lun_claw_%d" % (k + 1)] = np.array([24.3, 1.95 * math.cos(a), SHELL_Z + 1.95 * math.sin(a)]) * scale
    return pos


def write_obj(path, parts, data):
    mtl_name = os.path.splitext(os.path.basename(path))[0] + ".mtl"
    with open(path, "w", encoding="utf-8") as f:
        f.write("# КПП «Лунь» — процедурный меш (Source: X вперёд, Z вверх)\n")
        f.write("mtllib %s\n" % mtl_name)
        vi = 1
        for part, tris in zip(parts, data):
            f.write("g %s\nusemtl %s\n" % (part.name, part.mat))
            for corners in tris:
                for (p, n, uv) in corners:
                    f.write("v %.5f %.5f %.5f\nvt %.5f %.5f\nvn %.5f %.5f %.5f\n" % (p[0], p[1], p[2], uv[0], uv[1], n[0], n[1], n[2]))
                f.write("f %d/%d/%d %d/%d/%d %d/%d/%d\n" % (vi, vi, vi, vi + 1, vi + 1, vi + 1, vi + 2, vi + 2, vi + 2))
                vi += 3
    with open(os.path.join(os.path.dirname(path), mtl_name), "w", encoding="utf-8") as f:
        for name, m in MATERIALS.items():
            c = m["color"]
            f.write("newmtl %s\nKd %.3f %.3f %.3f\n" % (name, c[0], c[1], c[2]))
            f.write("map_Kd materialsrc/%s/%s.tga\n" % (TEX_DIR, name))
            f.write("Pm %.2f\nPr %.2f\n" % (m["metal"], m["rough"]))  # PBR-расширение MTL (читает Blender)
            if "emissive" in m:
                e = m["emissive"]
                f.write("Ke %.3f %.3f %.3f\n" % (e[0], e[1], e[2]))
            f.write("\n")


def write_smd(path, parts, data, scale):
    names = [b[0] for b in BONES]
    index = {n: i for i, n in enumerate(names)}
    pos = bone_positions(scale)
    with open(path, "w", encoding="utf-8") as f:
        f.write("version 1\nnodes\n")
        for i, (name, parent, _) in enumerate(BONES):
            f.write('%d "%s" %d\n' % (i, name, index[parent] if parent else -1))
        f.write("end\nskeleton\ntime 0\n")
        for i, (name, parent, _) in enumerate(BONES):
            p = pos[name]
            local = p - (pos[parent] if parent else np.zeros(3))
            f.write("%d %.5f %.5f %.5f 0.000000 0.000000 0.000000\n" % (i, local[0], local[1], local[2]))
        f.write("end\ntriangles\n")
        for part, tris in zip(parts, data):
            b = index[part.bone]
            for corners in tris:
                f.write("%s\n" % part.mat)
                for (p, n, uv) in corners:
                    f.write("%d %.5f %.5f %.5f %.5f %.5f %.5f %.5f %.5f 1 %d 1.0\n" % (b, p[0], p[1], p[2], n[0], n[1], n[2], uv[0], uv[1], b))
        f.write("end\n")


def part_by_name(parts, name):
    for p in parts:
        if p.name == name:
            return np.array(p.V)
    raise SystemExit("нет детали %s" % name)


def write_qc(path, parts, scale):
    """
    Игровой QC: одна модель на вьюмодель и мировую (без рук).
    Точки экрана — углы лицевой (к стрелку, -X) грани стекла с зазором 0,02 к стрелку;
    оси: X -> вправо по стеклу (-Y модели), Y -> вверх по стеклу (+Z), Z -> к стрелку (-X).
    """
    glass = part_by_name(parts, "screen_glass")
    x = glass[:, 0].min() - 0.02
    tl = (x, glass[:, 1].max(), glass[:, 2].max())
    br = (x, glass[:, 1].min(), glass[:, 2].min())
    orb = part_by_name(parts, "orb").mean(axis=0)
    with open(path, "w", encoding="utf-8") as f:
        f.write("""// КПП «Лунь» — процедурный меш (tools/model/kpp_lun_mesh.py), одна модель на вьюмодель и мировую.
$modelname "map_singularity/kpp_lun.mdl"
$cdmaterials "models/map_singularity/kpp_lun/"
// studiomdl по умолчанию поворачивает всё на +90 град. вокруг Z; -90 отменяет: X — вперёд по стволу.
$origin 0 0 0 -90
$body "body" "kpp_lun_ref.smd"
$surfaceprop "metal"
$sequence "idle" "kpp_lun_ref.smd" loop fps 30
$collisionmodel "kpp_lun_ref.smd"
{
	$mass 8
}
// Шар между когтями; X — вперёд по стволу.
$attachment "muzzle" "lun_root" %.3f %.3f %.3f rotate 0 0 0
// Стекло экрана %.2f x %.2f: левый верхний (screen) и правый нижний (screen_br) углы от стрелка.
$attachment "screen" "lun_root" %.3f %.3f %.3f rotate 0 -90 90
$attachment "screen_br" "lun_root" %.3f %.3f %.3f rotate 0 -90 90
$attachment "generator" "lun_generator" 0 0 0 rotate 0 0 0
""" % (orb[0], orb[1], orb[2], tl[1] - br[1], tl[2] - br[2], tl[0], tl[1], tl[2], br[0], br[1], br[2]))
        # Кончики когтей (для молний к шару) — в осях своей кости.
        bones = bone_positions(scale)
        for k in range(3):
            a = math.radians(90 + 120 * k)
            tip = np.array([30.2, 1.85 * math.cos(a), SHELL_Z + 1.85 * math.sin(a)]) * scale - bones["lun_claw_%d" % (k + 1)]
            f.write('$attachment "claw%d_tip" "lun_claw_%d" %.3f %.3f %.3f rotate 0 0 0\n' % (k + 1, k + 1, tip[0], tip[1], tip[2]))
    return tl, br


def write_preview(out_dir, parts, data):
    payload = {"materials": MATERIALS, "parts": []}
    for part, tris in zip(parts, data):
        pos, nrm = [], []
        for corners in tris:
            for (p, n, _) in corners:
                pos += [round(float(p[0]), 3), round(float(p[1]), 3), round(float(p[2]), 3)]
                nrm += [round(float(n[0]), 3), round(float(n[1]), 3), round(float(n[2]), 3)]
        edges = set()
        for fc in part.F:
            for i in range(len(fc)):
                a, b = fc[i], fc[(i + 1) % len(fc)]
                edges.add((min(a, b), max(a, b)))
        lines = []
        for a, b in edges:
            for v in (part.V[a], part.V[b]):
                lines += [round(float(v[0]), 3), round(float(v[1]), 3), round(float(v[2]), 3)]
        payload["parts"].append({"name": part.name, "mat": part.mat, "pos": pos, "nrm": nrm, "edges": lines})
    with open(os.path.join(out_dir, "preview_data.js"), "w", encoding="utf-8") as f:
        f.write("window.KPP_LUN = ")
        json.dump(payload, f, separators=(",", ":"))
        f.write(";\n")
    template = os.path.join(os.path.dirname(os.path.abspath(__file__)), "preview_template.html")
    with open(template, encoding="utf-8") as src, open(os.path.join(out_dir, "preview.html"), "w", encoding="utf-8") as dst:
        dst.write(src.read())


# --------------------------------------------------------------------------

def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_out = os.path.normpath(os.path.join(here, "..", "..", "art", "kpp_lun"))
    ap = argparse.ArgumentParser(description="КПП «Лунь»: процедурный hard-surface меш")
    ap.add_argument("--out", default=default_out)
    ap.add_argument("--scale", type=float, default=0.9,
                    help="общий масштаб (0.9 -> длина ~43 юнита, как просит ТЗ)")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    parts = build()
    for part in parts:
        part.V = [v * args.scale for v in part.V]
    report = []
    totals = defaultdict(int)
    for part in parts:
        orient(part)
        st = check(part)
        for k in ("verts", "faces", "quads", "tris", "boundary_edges", "nonmanifold_edges", "flipped_edges", "degenerate_faces"):
            totals[k] += st[k]
        report.append("%-22s %-13s %-14s v=%5d f=%5d quads=%5d tris=%6d | дыр=%d немногообр=%d перевёрн=%d вырожд=%d" % (
            part.name, part.mat, part.bone, st["verts"], st["faces"], st["quads"], st["tris"],
            st["boundary_edges"], st["nonmanifold_edges"], st["flipped_edges"], st["degenerate_faces"]))

    data = [corner_data(p) for p in parts]

    allv = np.array([v for p in parts for v in p.V])
    lo, hi = allv.min(axis=0), allv.max(axis=0)

    write_obj(os.path.join(args.out, "kpp_lun.obj"), parts, data)
    write_smd(os.path.join(args.out, "kpp_lun_ref.smd"), parts, data, args.scale)
    tl, br = write_qc(os.path.join(args.out, "kpp_lun.qc"), parts, args.scale)
    write_preview(args.out, parts, data)
    write_textures(args.out)

    summary = [
        "КПП «Лунь» — процедурный меш",
        "деталей: %d, вершин: %d, полигонов: %d (квадов %d), треугольников после триангуляции: %d" % (
            len(parts), totals["verts"], totals["faces"], totals["quads"], totals["tris"]),
        "габарит (юниты): X %.2f..%.2f (длина %.2f), Y %.2f..%.2f, Z %.2f..%.2f" % (lo[0], hi[0], hi[0] - lo[0], lo[1], hi[1], lo[2], hi[2]),
        "чистота: дыр %d, немногообразных рёбер %d, перевёрнутых рёбер %d, вырожденных граней %d" % (
            totals["boundary_edges"], totals["nonmanifold_edges"], totals["flipped_edges"], totals["degenerate_faces"]),
        "стекло экрана: %.2f x %.2f, левый верх %s, правый низ %s" % (
            tl[1] - br[1], tl[2] - br[2], np.round(tl, 3).tolist(), np.round(br, 3).tolist()),
        "",
    ] + report
    with open(os.path.join(args.out, "report.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(summary) + "\n")
    print("\n".join(summary[:5]))
    print("выход:", args.out)


if __name__ == "__main__":
    main()
