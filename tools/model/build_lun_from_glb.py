"""
КПП «Лунь»: GLB (Tripo) -> исходники Source-модели.

Запуск (Blender без интерфейса):
  blender --background --factory-startup --python tools/model/build_lun_from_glb.py -- <model.glb> <work_dir>

Что делает:
  1. Удаляет оторванные «острова» сетки вне основного корпуса (артефакты генерации).
  2. Разворачивает стволом по +X (Source), масштабирует до LENGTH юнитов, ставит начало
     координат на рукоять.
  3. Упрощает до TARGET_TRIS треугольников (Decimate collapse, UV сохраняются).
  4. Раздаёт вершины по костям ТЗ по областям: когти (3 кластера по углу), экран, магазин.
  5. Пишет текстуры для Source (base color, normal в DirectX-формате + блеск в альфе) как
     TGA для vtex, SMD (жёсткая привязка), QC с точками крепления, отчёт и превью.

Выход в <work_dir>: kpp_lun_ref.smd, kpp_lun.qc, materialsrc/models/map_singularity/kpp_lun/*.tga|txt,
report.txt, preview_*.png
"""

import math
import os
import sys

import bmesh
import bpy
import numpy as np
from mathutils import Matrix, Vector

LENGTH = 43.0
TARGET_TRIS = 18000
MAT = "kpp_lun"
TEX_DIR = "models/map_singularity/kpp_lun"

BONES = ["lun_root", "lun_claw_1", "lun_claw_2", "lun_claw_3", "lun_generator", "lun_screen", "lun_trigger", "lun_mag"]
BONE_COLORS = {
    "lun_root": (0.55, 0.55, 0.55), "lun_claw_1": (1.0, 0.25, 0.25), "lun_claw_2": (0.25, 1.0, 0.25),
    "lun_claw_3": (0.3, 0.45, 1.0), "lun_generator": (1.0, 0.6, 0.1), "lun_screen": (1.0, 1.0, 0.2),
    "lun_trigger": (1.0, 0.3, 1.0), "lun_mag": (0.2, 1.0, 1.0),
}

report = []


def log(fmt, *args):
    line = fmt % args if args else fmt
    report.append(line)
    print("[lun] " + line, flush=True)


def coords(me):
    a = np.empty(len(me.vertices) * 3, np.float64)
    me.vertices.foreach_get("co", a)
    return a.reshape(-1, 3)


# ---------------------------------------------------------------------------
# Импорт и текстуры
# ---------------------------------------------------------------------------

def import_glb(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=path)
    meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH']
    if not meshes:
        raise SystemExit("в GLB нет мешей")
    bpy.ops.object.select_all(action='DESELECT')
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    if len(meshes) > 1:
        bpy.ops.object.join()
    obj = bpy.context.view_layer.objects.active
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    return obj


def find_textures(obj):
    """Ищет base color, normal и metallic-roughness в узлах glTF-материала."""
    found = {}
    for slot in obj.material_slots:
        mat = slot.material
        if not mat or not mat.use_nodes:
            continue
        for node in mat.node_tree.nodes:
            if node.type == 'BSDF_PRINCIPLED':
                link = node.inputs['Base Color'].links
                if link and link[0].from_node.type == 'TEX_IMAGE':
                    found['base'] = link[0].from_node.image
            elif node.type == 'NORMAL_MAP':
                link = node.inputs['Color'].links
                if link and link[0].from_node.type == 'TEX_IMAGE':
                    found['normal'] = link[0].from_node.image
            elif node.type == 'SEPARATE_COLOR':
                link = node.inputs[0].links
                if link and link[0].from_node.type == 'TEX_IMAGE':
                    found['mr'] = link[0].from_node.image
    log("текстуры: %s", {k: (v.name, tuple(v.size)) for k, v in found.items()})
    return found


def image_array(img):
    w, h = img.size
    a = np.empty(w * h * 4, np.float32)
    img.pixels.foreach_get(a)
    return a.reshape(h, w, 4)


def resize_nearest(arr, w, h):
    if arr.shape[1] == w and arr.shape[0] == h:
        return arr
    ys = (np.arange(h) * arr.shape[0] / h).astype(int)
    xs = (np.arange(w) * arr.shape[1] / w).astype(int)
    return arr[ys][:, xs]


def save_tga(arr, path):
    h, w = arr.shape[:2]
    img = bpy.data.images.new(os.path.basename(path), w, h, alpha=True)
    img.pixels.foreach_set(np.clip(arr, 0, 1).astype(np.float32).ravel())
    img.filepath_raw = path
    img.file_format = 'TARGA_RAW'
    img.save()
    bpy.data.images.remove(img)


def write_textures(tex, work):
    out = os.path.join(work, "materialsrc", TEX_DIR)
    os.makedirs(out, exist_ok=True)
    if 'base' not in tex:
        raise SystemExit("не найдена base color текстура")

    base = image_array(tex['base'])
    h, w = base.shape[:2]
    base[..., 3] = 1.0
    save_tga(base, os.path.join(out, "kpp_lun_basecolor.tga"))
    with open(os.path.join(out, "kpp_lun_basecolor.txt"), "w") as f:
        f.write("nocompress 0\n")

    if 'normal' in tex:
        nrm = resize_nearest(image_array(tex['normal']), w, h).copy()
        nrm[..., 1] = 1.0 - nrm[..., 1]  # glTF (OpenGL) -> Source (DirectX)
        if 'mr' in tex:
            mr = resize_nearest(image_array(tex['mr']), w, h)
            gloss = 1.0 - mr[..., 1]          # G — шероховатость
            metal = mr[..., 2]                # B — металличность
            nrm[..., 3] = np.clip(gloss * (0.35 + 0.65 * metal) * 1.2, 0.04, 1.0)  # маска phong
        else:
            nrm[..., 3] = 0.5
        save_tga(nrm, os.path.join(out, "kpp_lun_normal.tga"))
        with open(os.path.join(out, "kpp_lun_normal.txt"), "w") as f:
            f.write("normal 1\n")
    log("текстуры записаны: %s (%dx%d)", out, w, h)
    return 'normal' in tex


# ---------------------------------------------------------------------------
# Геометрия
# ---------------------------------------------------------------------------

def remove_stray_islands(obj):
    me = obj.data
    bm = bmesh.new()
    bm.from_mesh(me)
    bm.verts.ensure_lookup_table()
    seen = np.zeros(len(bm.verts), bool)
    islands = []
    for v in bm.verts:
        if seen[v.index]:
            continue
        comp, stack = [], [v]
        seen[v.index] = True
        while stack:
            x = stack.pop()
            comp.append(x.index)
            for e in x.link_edges:
                o = e.other_vert(x)
                if not seen[o.index]:
                    seen[o.index] = True
                    stack.append(o)
        islands.append(comp)

    co = np.array([v.co[:] for v in bm.verts])
    boxes = [(co[c].min(0), co[c].max(0)) for c in islands]
    margin = 0.01 * (co.max(0) - co.min(0)).max()

    # Граф касаний: остров связан с корпусом, если его рамка (с запасом) пересекается
    # с рамкой уже связанного острова. Висящие в воздухе куски — недостижимы.
    main = max(range(len(islands)), key=lambda i: len(islands[i]))
    linked = {main}
    frontier = [main]
    while frontier:
        i = frontier.pop()
        lo_i, hi_i = boxes[i][0] - margin, boxes[i][1] + margin
        for j in range(len(islands)):
            if j in linked:
                continue
            lo_j, hi_j = boxes[j]
            if np.all(hi_j >= lo_i) and np.all(lo_j <= hi_i):
                linked.add(j)
                frontier.append(j)

    doomed = []
    for i, comp in enumerate(islands):
        if i not in linked:
            doomed += comp
            lo, hi = boxes[i]
            log("удалён висящий кусок: %d вершин, центр %s, размер %s", len(comp),
                np.round((lo + hi) / 2, 3).tolist(), np.round(hi - lo, 3).tolist())
    log("островов: %d, связано с корпусом: %d, удалено вершин: %d", len(islands), len(linked), len(doomed))
    if doomed:
        bmesh.ops.delete(bm, geom=[bm.verts[i] for i in doomed], context='VERTS')
    bm.to_mesh(me)
    bm.free()
    me.update()


def orient_and_scale(obj):
    me = obj.data
    me.transform(Matrix.Rotation(math.pi, 4, 'Z'))  # ствол Tripo смотрит в -X
    co = coords(me)
    lo, hi = co.min(0), co.max(0)
    me.transform(Matrix.Scale(LENGTH / (hi[0] - lo[0]), 4))
    co = coords(me)
    lo, hi = co.min(0), co.max(0)
    L, H = hi[0] - lo[0], hi[2] - lo[2]

    # Начало координат — на рукояти: нижние вершины в зоне 15–32 % длины от затыльника.
    grip = co[(co[:, 0] > lo[0] + 0.15 * L) & (co[:, 0] < lo[0] + 0.32 * L) & (co[:, 2] < lo[2] + 0.25 * H)]
    gx = grip[:, 0].mean() if len(grip) else lo[0] + 0.23 * L
    origin = Vector((gx, (lo[1] + hi[1]) / 2, lo[2] + 0.45 * H))
    me.transform(Matrix.Translation(-origin))
    me.update()
    co = coords(me)
    log("после ориентации: X %.2f..%.2f, Y %.2f..%.2f, Z %.2f..%.2f",
        co[:, 0].min(), co[:, 0].max(), co[:, 1].min(), co[:, 1].max(), co[:, 2].min(), co[:, 2].max())


def decimate(obj):
    me = obj.data
    tris = sum(len(p.vertices) - 2 for p in me.polygons)
    if tris > TARGET_TRIS:
        mod = obj.modifiers.new("decimate", 'DECIMATE')
        mod.decimate_type = 'COLLAPSE'
        mod.ratio = TARGET_TRIS / tris
        bpy.ops.object.modifier_apply(modifier=mod.name)
    after = sum(len(p.vertices) - 2 for p in obj.data.polygons)
    log("треугольников: %d -> %d", tris, after)
    try:
        bpy.ops.object.shade_smooth_by_angle(angle=math.radians(40))
    except Exception as exc:  # старые версии Blender
        log("shade_smooth_by_angle недоступен (%s), гладкое затенение", exc)
        bpy.ops.object.shade_smooth()


# ---------------------------------------------------------------------------
# Кости по областям
# ---------------------------------------------------------------------------

def angle_peaks(angles, weights, count=3, min_sep=math.radians(60)):
    bins = 72
    hist, edges = np.histogram(angles, bins=bins, range=(-math.pi, math.pi), weights=weights)
    smooth = np.convolve(np.concatenate([hist[-2:], hist, hist[:2]]), np.ones(5) / 5, mode='valid')
    centers = (edges[:-1] + edges[1:]) / 2
    peaks = []
    for i in np.argsort(-smooth):
        a = centers[i]
        if all(abs((a - p + math.pi) % (2 * math.pi) - math.pi) >= min_sep for p in peaks):
            peaks.append(a)
        if len(peaks) == count:
            break
    return sorted(peaks, key=lambda a: -math.sin(a))  # первый — верхний коготь


def source_angles(fwd, left, up):
    """Матрица (столбцы — оси X, Y, Z точки крепления) -> углы Source (pitch, yaw, roll) в градусах."""
    xy = math.hypot(fwd[0], fwd[1])
    if xy > 1e-3:
        return (math.degrees(math.atan2(-fwd[2], xy)), math.degrees(math.atan2(fwd[1], fwd[0])),
                math.degrees(math.atan2(left[2], up[2])))
    return (math.degrees(math.atan2(-fwd[2], xy)), math.degrees(math.atan2(-left[0], left[1])), 0.0)


def fit_screen_glass(me, slo, shi, inset=(0.15, 0.07, 0.10, 0.18), lift=0.03):
    """
    Стекло экрана — плоская грань блока экрана, обращённая к стрелку (нормаль к -X).
    Берётся самая большая по площади плоскость таких граней (рамка и козырёк ближе к стрелку
    отсекаются), по её вершинам — плоскость наименьших квадратов x = a + b*y + c*z.
    Отступы (доли грани: слева, справа, сверху, снизу) — по лучам из глаза в позе от первого
    лица: стекло утоплено в рамку на ~2 юнита и видно слева, поэтому левую полосу закрывает
    стенка рамки, нижнюю — корпус (проверено трассировкой, 2026-11-18).
    Возвращает углы точки крепления (X -> вправо по стеклу, Y -> вверх по стеклу, Z -> к стрелку),
    левый верхний и правый нижний углы стекла (с отступом внутрь и на lift к стрелку) и размеры.
    """
    n = len(me.polygons)
    nrm, cen, area = np.empty(n * 3), np.empty(n * 3), np.empty(n)
    me.polygons.foreach_get("normal", nrm)
    me.polygons.foreach_get("center", cen)
    me.polygons.foreach_get("area", area)
    nrm, cen = nrm.reshape(-1, 3), cen.reshape(-1, 3)

    pad = 0.05
    inside = np.all((cen >= slo - pad) & (cen <= shi + pad), axis=1)
    facing = inside & (nrm[:, 0] < -0.75)
    if not facing.any():
        raise SystemExit("не найдена грань экрана, обращённая к стрелку")
    hist, edges = np.histogram(cen[facing, 0], bins=max(4, int((shi[0] - slo[0]) / 0.25)), weights=area[facing])
    peak = (edges[np.argmax(hist)] + edges[np.argmax(hist) + 1]) / 2
    face = facing & (np.abs(cen[:, 0] - peak) < 0.4)

    verts = np.array([me.vertices[v].co[:] for i in np.nonzero(face)[0] for v in me.polygons[i].vertices])
    A = np.column_stack([np.ones(len(verts)), verts[:, 1], verts[:, 2]])
    (a, b, c), *_ = np.linalg.lstsq(A, verts[:, 0], rcond=None)
    z_axis = np.array([-1.0, b, c])
    z_axis /= np.linalg.norm(z_axis)
    x_axis = np.array([0.0, -1.0, 0.0])
    x_axis -= z_axis * x_axis.dot(z_axis)
    x_axis /= np.linalg.norm(x_axis)
    y_axis = np.cross(z_axis, x_axis)

    origin = verts.mean(0)
    origin[0] = a + b * origin[1] + c * origin[2]
    u, v = (verts - origin) @ x_axis, (verts - origin) @ y_axis
    fw, fh = u.max() - u.min(), v.max() - v.min()
    left, right, top, bottom = inset
    tl = origin + x_axis * (u.min() + fw * left) + y_axis * (v.max() - fh * top) + z_axis * lift
    br = origin + x_axis * (u.max() - fw * right) + y_axis * (v.min() + fh * bottom) + z_axis * lift
    w, h = fw * (1 - left - right), fh * (1 - top - bottom)
    tilt = math.degrees(math.asin(max(-1.0, min(1.0, z_axis[2]))))
    log("стекло: плоскость x=%.2f (граней %d, площадь %.2f), наклон %.1f град, %.2f x %.2f юнита",
        origin[0], int(face.sum()), float(area[face].sum()), tilt, w, h)
    return source_angles(x_axis, y_axis, z_axis), tl, br, (w, h)


def assign_bones(obj):
    co = coords(obj.data)
    lo, hi = co.min(0), co.max(0)
    L, H = hi[0] - lo[0], hi[2] - lo[2]
    bone = np.zeros(len(co), int)
    idx = {b: i for i, b in enumerate(BONES)}

    # Ось ствола — по зоне катушек.
    barrel = co[(co[:, 0] > hi[0] - 0.35 * L) & (co[:, 0] < hi[0] - 0.18 * L)]
    cy = (barrel[:, 1].min() + barrel[:, 1].max()) / 2
    cz = (barrel[:, 2].min() + barrel[:, 2].max()) / 2

    # Когти и шар: передние 11,5 % длины (за кольцом излучателя).
    front = co[:, 0] > hi[0] - 0.115 * L
    dy, dz = co[:, 1] - cy, co[:, 2] - cz
    r = np.hypot(dy, dz)
    r_orb = 0.025 * L
    claw_mask = front & (r >= r_orb)
    ang = np.arctan2(dz, dy)
    peaks = angle_peaks(ang[claw_mask], r[claw_mask])
    log("ось ствола y=%.2f z=%.2f; пики когтей (град): %s", cy, cz, [round(math.degrees(p)) for p in peaks])
    claw_pos = {}
    for vi in np.nonzero(claw_mask)[0]:
        d = [abs((ang[vi] - p + math.pi) % (2 * math.pi) - math.pi) for p in peaks]
        bone[vi] = idx["lun_claw_%d" % (int(np.argmin(d)) + 1)]
    for k in range(len(peaks)):
        sel = co[bone == idx["lun_claw_%d" % (k + 1)]]
        if len(sel):
            base = sel[sel[:, 0] < sel[:, 0].min() + 0.01 * L]
            claw_pos["lun_claw_%d" % (k + 1)] = base.mean(0)
    orb = co[front & (r < r_orb)]
    muzzle = orb.mean(0) if len(orb) else np.array([hi[0] - 0.06 * L, cy, cz])

    # Экран: верхние 24 % высоты рядом с самой высокой точкой.
    top_x = co[np.argmax(co[:, 2]), 0]
    screen = (co[:, 2] > hi[2] - 0.24 * H) & (np.abs(co[:, 0] - top_x) < 0.07 * L)
    bone[screen] = idx["lun_screen"]
    s = co[screen]
    slo, shi = s.min(0), s.max(0)

    # Магазин: низ средней части (34–46 % длины от затыльника).
    mag = (co[:, 2] < lo[2] + 0.30 * H) & (co[:, 0] > lo[0] + 0.33 * L) & (co[:, 0] < lo[0] + 0.47 * L)
    bone[mag] = idx["lun_mag"]
    m = co[mag]

    positions = {
        "lun_root": np.zeros(3),
        "lun_generator": np.array([lo[0] + 0.58 * L, cy, cz]),
        "lun_screen": s.mean(0),
        "lun_trigger": np.array([lo[0] + 0.29 * L, 0.0, lo[2] + 0.33 * H]),
        "lun_mag": np.array([m[:, 0].mean(), m[:, 1].mean(), m[:, 2].max()]) if len(m) else np.array([0.0, 0, lo[2]]),
    }
    positions.update(claw_pos)
    for k in range(3):
        positions.setdefault("lun_claw_%d" % (k + 1), np.array([hi[0] - 0.115 * L, cy, cz]))

    # Стекло экрана: углы — две точки крепления, код берёт из них положение и размер 3D2D-экрана.
    screen_ang, screen_tl, screen_br, glass = fit_screen_glass(obj.data, slo, shi)

    counts = {b: int((bone == i).sum()) for b, i in idx.items()}
    log("вершин по костям: %s", counts)
    log("блок экрана: %.2f x %.2f юнита", shi[1] - slo[1], shi[2] - slo[2])
    log("muzzle %s, screen %s .. %s, углы %s", np.round(muzzle, 2).tolist(), np.round(screen_tl, 2).tolist(),
        np.round(screen_br, 2).tolist(), [round(x, 1) for x in screen_ang])
    att = {"muzzle": muzzle, "screen": screen_tl, "screen_br": screen_br, "screen_ang": screen_ang,
           "generator": positions["lun_generator"]}
    return bone, positions, att, glass


# ---------------------------------------------------------------------------
# Экспорт
# ---------------------------------------------------------------------------

def write_smd(obj, bone, positions, path):
    me = obj.data
    me.calc_loop_triangles()
    uv = me.uv_layers.active.data
    normals = me.corner_normals
    with open(path, "w", encoding="ascii") as f:
        f.write("version 1\nnodes\n")
        for i, b in enumerate(BONES):
            f.write('%d "%s" %d\n' % (i, b, -1 if i == 0 else 0))
        f.write("end\nskeleton\ntime 0\n")
        for i, b in enumerate(BONES):
            p = positions[b]
            f.write("%d %.5f %.5f %.5f 0 0 0\n" % (i, p[0], p[1], p[2]))
        f.write("end\ntriangles\n")
        for tri in me.loop_triangles:
            f.write(MAT + "\n")
            for li in tri.loops:
                vi = me.loops[li].vertex_index
                c = me.vertices[vi].co
                n = normals[li].vector
                u, v = uv[li].uv
                b = int(bone[vi])
                f.write("%d %.5f %.5f %.5f %.5f %.5f %.5f %.5f %.5f 1 %d 1\n" % (b, c.x, c.y, c.z, n.x, n.y, n.z, u, v, b))
        f.write("end\n")
    log("SMD: %s (%d треугольников)", path, len(me.loop_triangles))


def write_qc(path, att, positions):
    gen = att["generator"] - positions["lun_generator"]
    p, y, r = att["screen_ang"]
    with open(path, "w", encoding="utf-8") as f:
        f.write("""// КПП «Лунь» — модель для GMod (одна на вьюмодель и мировую, без рук).
$modelname "map_singularity/kpp_lun.mdl"
$cdmaterials "%s/"
// studiomdl по умолчанию поворачивает всё на +90 град. вокруг Z (ствол уезжает в +Y);
// -90 отменяет поворот: в модели, как в SMD, X — вперёд по стволу.
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
// Стекло экрана: левый верхний (screen) и правый нижний (screen_br) углы видимой стрелку области.
// Оси: X -> вправо по стеклу, Y -> вверх по стеклу, Z -> из стекла к стрелку (как ждёт cam.Start3D2D).
$attachment "screen" "lun_root" %.3f %.3f %.3f rotate %.2f %.2f %.2f
$attachment "screen_br" "lun_root" %.3f %.3f %.3f rotate %.2f %.2f %.2f
$attachment "generator" "lun_generator" %.3f %.3f %.3f rotate 0 0 0
""" % (TEX_DIR, att["muzzle"][0], att["muzzle"][1], att["muzzle"][2],
       att["screen"][0], att["screen"][1], att["screen"][2], p, y, r,
       att["screen_br"][0], att["screen_br"][1], att["screen_br"][2], p, y, r,
       gen[0], gen[1], gen[2]))


def render_previews(obj, bone, work):
    me = obj.data
    attr = me.color_attributes.new("bone_col", 'FLOAT_COLOR', 'POINT')
    for vi, b in enumerate(bone):
        c = BONE_COLORS[BONES[int(b)]]
        attr.data[vi].color = (c[0], c[1], c[2], 1.0)

    scene = bpy.context.scene
    scene.render.engine = 'BLENDER_WORKBENCH'
    scene.display.shading.light = 'STUDIO'
    scene.render.resolution_x, scene.render.resolution_y = 1100, 520
    world = bpy.data.worlds.new("w")
    scene.world = world
    world.color = (0.09, 0.09, 0.1)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    scene.collection.objects.link(cam)
    scene.camera = cam
    co = coords(me)
    lo, hi = co.min(0), co.max(0)
    center, size = Vector(((lo + hi) / 2).tolist()), float(np.linalg.norm(hi - lo))

    # Раскраска по атрибуту: 'VERTEX' в Blender 5.x, 'ATTRIBUTE' в 4.x.
    by_attr = 'VERTEX' if 'VERTEX' in scene.display.shading.bl_rna.properties['color_type'].enum_items.keys() else 'ATTRIBUTE'
    shots = [("textured_side", 'TEXTURE', Vector((0, -1, 0)), 'ORTHO'),
             ("bones_side", by_attr, Vector((0, -1, 0)), 'ORTHO'),
             ("bones_front", by_attr, Vector((1, 0, 0)), 'ORTHO'),
             ("textured_persp", 'TEXTURE', Vector((0.9, -0.8, 0.45)), 'PERSP')]
    for name, color_type, d, kind in shots:
        scene.display.shading.color_type = color_type
        d = d.normalized()
        cam.location = center + d * size * 1.5
        look = (center - cam.location).normalized()
        cam.rotation_euler = look.to_track_quat('-Z', 'Y').to_euler()
        cam.data.type = kind
        cam.data.ortho_scale = size * 1.0
        scene.render.filepath = os.path.join(work, "preview_%s.png" % name)
        bpy.ops.render.render(write_still=True)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:]
    glb, work = argv[0], argv[1]
    os.makedirs(work, exist_ok=True)

    obj = import_glb(glb)
    tex = find_textures(obj)
    remove_stray_islands(obj)
    orient_and_scale(obj)
    decimate(obj)
    bone, positions, att, glass = assign_bones(obj)
    write_textures(tex, work)
    write_smd(obj, bone, positions, os.path.join(work, "kpp_lun_ref.smd"))
    write_qc(os.path.join(work, "kpp_lun.qc"), att, positions)
    render_previews(obj, bone, work)

    with open(os.path.join(work, "report.txt"), "w", encoding="utf-8") as f:
        f.write("\n".join(report) + "\n")
    print("[lun] DONE", flush=True)


main()
