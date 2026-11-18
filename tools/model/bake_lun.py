"""
КПП «Лунь»: запекание текстур процедурной модели в Blender (Cycles), без интерфейса.

  "C:/Program Files/Blender Foundation/Blender 5.3/blender.exe" --background --factory-startup \
      --python tools/model/bake_lun.py -- art/kpp_lun [--size 2048]

Почему: плиточные текстуры одинаковы по всей модели и не знают формы — модель выглядит
«примитивами». Здесь все непрозрачные детали получают уникальную развёртку (атлас), и в неё
запекаются:
  цвет      — альбедо плиточных материалов (через Emission, чтобы металличность не гасила цвет);
  AO        — затенение в щелях и стыках, плюс тёплая грязь в углублениях;
  кромки    — маска рёбер (Bevel против нормали поверхности), рваная шумом -> потёртости;
  нормали   — скруглённые фаски (Bevel в нормали) -> блик бежит по рёбрам; карта DirectX (-Y);
  блеск     — по материалам (металл блестит, резина нет), сильнее на потёртых кромках, слабее в AO.
Светящиеся материалы (ядро, шар, стекло, светодиоды) и табличка с маркировкой остаются со своими текстурами.

Пишет в <work>:
  materialsrc/.../kpp_body.tga (2048², цвет) и kpp_body_normal.tga (1024², нормали + блеск в альфе)
  kpp_lun_body.smd — тот же меш, что kpp_lun_ref.smd, но с UV атласа и материалом kpp_body;
  kpp_lun.qc       — $body переключается на kpp_lun_body.smd;
  materials.json   — kpp_body вместо запечённых материалов (исходный список — в "source");
  render_*.png     — рендер EEVEE с запечёнными текстурами.
Повторный запуск безопасен: исходники (kpp_lun_ref.smd, "source") не меняются.
"""

import json
import math
import os
import sys

import bmesh
import bpy
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import render_lun  # noqa: E402  (рядом лежащий модуль Blender-скрипта)

TEX_DIR = "models/map_singularity/kpp_lun"
BODY = "kpp_body"
# Не запекаются, остаются со своими текстурами: светящиеся (им нужен $selfillum) и табличка —
# в атласе 2048² на неё приходится ~160 пикселей и текст размывается.
SELF_LIT = ("kpp_glow", "kpp_orb", "kpp_screen", "kpp_led", "kpp_label", "kpp_tube", "kpp_gauge",
            "kpp_note", "kpp_sticky", "kpp_warn")
FLAT_NORMAL = "kpp_flat_normal"
# Блеск (R) и сила потёртостей на кромках (G) по материалам.
PARAMS = {
    "kpp_shell": (0.35, 0.75), "kpp_metal": (0.70, 1.00), "kpp_worn": (1.00, 0.45), "kpp_copper": (1.00, 0.15),
    "kpp_bakelite": (0.40, 0.35), "kpp_hazard": (0.30, 1.00), "kpp_label": (0.30, 0.60), "kpp_rubber": (0.10, 0.0),
    "kpp_brass": (1.00, 0.30), "kpp_porcelain": (0.60, 0.20), "kpp_tape": (0.50, 0.20),
}
WEAR_COLOR = np.array([0.56, 0.56, 0.54])     # металл под краской (sRGB)
DIRT_TINT = np.array([0.80, 0.72, 0.60])
BODY_VMT = {
    "$basetexture": TEX_DIR + "/" + BODY,
    "$bumpmap": TEX_DIR + "/" + BODY + "_normal",
    "$phong": "1",
    "$phongexponent": "22",
    "$phongboost": "2.4",
    "$phongfresnelranges": "[0.35 0.7 1]",
    # Отражения карты (как у тулгана), маска — та же альфа нормалей, что и для блеска.
    "$envmap": "env_cubemap",
    "$normalmapalphaenvmapmask": "1",
    "$envmaptint": "[0.22 0.22 0.22]",
    "$envmapcontrast": "0.6",
}


def log(msg, *args):
    print("[bake] " + (msg % args if args else msg), flush=True)


def base_name(mat):
    """Имя материала без суффиксов Blender (.001)."""
    return mat.name.split(".")[0]


# ---------------------------------------------------------------------------
# Сцена и развёртка
# ---------------------------------------------------------------------------

def setup_cycles(scene):
    scene.render.engine = "CYCLES"
    scene.cycles.use_denoising = False
    prefs = bpy.context.preferences.addons["cycles"].preferences
    for kind in ("OPTIX", "CUDA", "HIP", "ONEAPI", "METAL"):
        try:
            prefs.compute_device_type = kind
            prefs.get_devices()
        except (TypeError, ValueError):
            continue
        devices = [d for d in prefs.devices if d.type == kind]
        if devices:
            for d in devices:
                d.use = True
            scene.cycles.device = "GPU"
            log("Cycles: GPU (%s: %s)", kind, ", ".join(d.name for d in devices))
            return
    scene.cycles.device = "CPU"
    log("Cycles: CPU")


def atlas_unwrap(obj, self_lit_slots):
    me = obj.data
    me.uv_layers.new(name="atlas")
    me.uv_layers["UVMap"].active_render = True     # плиточные текстуры читают исходную UV
    me.uv_layers.active = me.uv_layers["atlas"]     # запекание пишет в атлас

    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    # В OBJ у каждого угла треугольника своя вершина — без сварки каждый треугольник стал бы
    # отдельным островом атласа. Порядок граней и углов сварка не меняет (проверяется при записи SMD).
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.mesh.remove_doubles(threshold=0.0005)
    bm = bmesh.from_edit_mesh(me)
    for f in bm.faces:
        f.select_set(False)
    for f in bm.faces:
        if f.material_index not in self_lit_slots:
            f.select_set(True)
    bmesh.update_edit_mesh(me)
    bpy.ops.uv.smart_project(angle_limit=math.radians(60), island_margin=0.004, area_weight=0.0,
                             correct_aspect=True, scale_to_bounds=True)
    bpy.ops.object.mode_set(mode="OBJECT")

    # После переключения режимов старые ссылки на данные меша недействительны (Blender их
    # перевыделяет; обращение по старой — падение) — берём слой заново, пачкой через foreach.
    atlas = me.uv_layers["atlas"]
    mat_idx = np.empty(len(me.polygons), np.int32)
    me.polygons.foreach_get("material_index", mat_idx)
    loop_start = np.empty(len(me.polygons), np.int32)
    me.polygons.foreach_get("loop_start", loop_start)
    uv = np.empty(len(me.loops) * 2, np.float32)
    atlas.data.foreach_get("uv", uv)
    uv = uv.reshape(-1, 2)
    # Светящиеся детали в атлас не попадают: их UV атласа — точка, пикселей у них нет.
    for p in np.nonzero(np.isin(mat_idx, list(self_lit_slots)))[0]:
        uv[loop_start[p]:loop_start[p] + 3] = 0.0
    atlas.data.foreach_set("uv", uv.ravel())
    me.update()
    log("атлас: %d граней в развёртке", int((~np.isin(mat_idx, list(self_lit_slots))).sum()))


# ---------------------------------------------------------------------------
# Узлы материалов для проходов
# ---------------------------------------------------------------------------

class BakeMaterial:
    """Переключает выход материала между исходным BSDF и служебными Emission для проходов."""

    def __init__(self, mat):
        self.mat = mat
        nt = mat.node_tree
        self.nodes, self.links = nt.nodes, nt.links
        self.out = next(n for n in self.nodes if n.type == "OUTPUT_MATERIAL")
        self.bsdf = next(n for n in self.nodes if n.type == "BSDF_PRINCIPLED")
        base = self.bsdf.inputs["Base Color"]
        self.albedo_src = base.links[0].from_socket if base.is_linked else None
        self.albedo_value = tuple(base.default_value)

        self.emit = self.nodes.new("ShaderNodeEmission")
        self.target = self.nodes.new("ShaderNodeTexImage")
        self.nodes.active = self.target

        geo = self.nodes.new("ShaderNodeNewGeometry")
        bevel = self.nodes.new("ShaderNodeBevel")
        bevel.samples = 8
        bevel.inputs["Radius"].default_value = 0.05
        dot = self.nodes.new("ShaderNodeVectorMath")
        dot.operation = "DOT_PRODUCT"
        self.links.new(bevel.outputs["Normal"], dot.inputs[0])
        self.links.new(geo.outputs["Normal"], dot.inputs[1])
        inv = self.nodes.new("ShaderNodeMath")
        inv.operation = "SUBTRACT"
        inv.inputs[0].default_value = 1.0
        self.links.new(dot.outputs["Value"], inv.inputs[1])
        gain = self.nodes.new("ShaderNodeMath")
        gain.operation = "MULTIPLY"
        gain.use_clamp = True
        gain.inputs[1].default_value = 14.0
        self.links.new(inv.outputs[0], gain.inputs[0])
        self.edge_src = gain.outputs[0]

        self.round = self.nodes.new("ShaderNodeBevel")
        self.round.samples = 8
        self.round.inputs["Radius"].default_value = 0.035

        # Потёки: шум в координатах объекта, вытянутый по вертикали (Z сжат), только на боках
        # (на смотрящих вверх гранях грязь не стекает).
        coords = self.nodes.new("ShaderNodeTexCoord")
        mapping = self.nodes.new("ShaderNodeMapping")
        mapping.inputs["Scale"].default_value = (5.0, 5.0, 0.35)
        self.links.new(coords.outputs["Object"], mapping.inputs["Vector"])
        streak_noise = self.nodes.new("ShaderNodeTexNoise")
        streak_noise.inputs["Scale"].default_value = 2.5
        streak_noise.inputs["Detail"].default_value = 3.0
        self.links.new(mapping.outputs["Vector"], streak_noise.inputs["Vector"])
        sharpen = self.nodes.new("ShaderNodeMapRange")
        sharpen.inputs["From Min"].default_value = 0.52
        sharpen.inputs["From Max"].default_value = 0.72
        self.links.new(streak_noise.outputs["Fac"], sharpen.inputs["Value"])
        sep = self.nodes.new("ShaderNodeSeparateXYZ")
        self.links.new(geo.outputs["Normal"], sep.inputs["Vector"])
        side = self.nodes.new("ShaderNodeMapRange")          # nz 0.2..0.8 -> 1..0
        side.inputs["From Min"].default_value = 0.2
        side.inputs["From Max"].default_value = 0.8
        side.inputs["To Min"].default_value = 1.0
        side.inputs["To Max"].default_value = 0.0
        self.links.new(sep.outputs["Z"], side.inputs["Value"])
        streak = self.nodes.new("ShaderNodeMath")
        streak.operation = "MULTIPLY"
        self.links.new(sharpen.outputs["Result"], streak.inputs[0])
        self.links.new(side.outputs["Result"], streak.inputs[1])
        self.params_rgb = self.nodes.new("ShaderNodeCombineColor")
        self.links.new(streak.outputs[0], self.params_rgb.inputs[2])

    def _emit_from(self, socket=None, color=None):
        for link in list(self.emit.inputs["Color"].links):
            self.links.remove(link)
        if socket is not None:
            self.links.new(socket, self.emit.inputs["Color"])
        else:
            self.emit.inputs["Color"].default_value = color
        self.links.new(self.emit.outputs["Emission"], self.out.inputs["Surface"])

    def albedo(self):
        self._emit_from(self.albedo_src, self.albedo_value)

    def params(self):
        spec, wear = PARAMS.get(base_name(self.mat), (0.3, 0.5))
        self.params_rgb.inputs[0].default_value = spec
        self.params_rgb.inputs[1].default_value = wear
        self._emit_from(self.params_rgb.outputs["Color"])           # B — маска потёков

    def edges(self):
        self._emit_from(self.edge_src)

    def surface_with_round_edges(self):
        self.links.new(self.bsdf.outputs[0], self.out.inputs["Surface"])
        self.links.new(self.round.outputs["Normal"], self.bsdf.inputs["Normal"])

    def set_target(self, image):
        self.target.image = image


def new_image(name, size, color_data):
    img = bpy.data.images.new(name, size, size, alpha=False, float_buffer=not color_data)
    img.colorspace_settings.name = "sRGB" if color_data else "Non-Color"
    return img


def bake(obj, mats, image, kind, samples, setup):
    scene = bpy.context.scene
    scene.cycles.samples = samples
    for m in mats:
        setup(m)
        m.set_target(image)
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    if kind == "NORMAL":
        scene.render.bake.normal_space = "TANGENT"
        scene.render.bake.normal_r, scene.render.bake.normal_g, scene.render.bake.normal_b = "POS_X", "NEG_Y", "POS_Z"
    bpy.ops.object.bake(type=kind, margin=8, use_clear=True)
    log("проход %s: %s", kind, image.name)


def pixels(img):
    w, h = img.size
    a = np.empty(w * h * 4, np.float32)
    img.pixels.foreach_get(a)
    return a.reshape(h, w, 4)


# ---------------------------------------------------------------------------
# Сборка текстур
# ---------------------------------------------------------------------------

def soft_noise(shape, sigma, seed):
    rng = np.random.default_rng(seed)
    h, w = shape
    f = np.fft.fft2(rng.standard_normal((h, w)))
    ky, kx = np.fft.fftfreq(h)[:, None], np.fft.fftfreq(w)[None, :]
    n = np.real(np.fft.ifft2(f * np.exp(-2 * np.pi ** 2 * sigma ** 2 * (kx ** 2 + ky ** 2))))
    return (n - n.mean()) / (n.std() + 1e-9)


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def compose(col, ao, par, edge, nrm):
    shape = ao.shape
    spec, wear_amount, streak = par[..., 0], par[..., 1], par[..., 2]
    breakup = smoothstep(-0.4, 0.9, soft_noise(shape, 3.0, 1)) * (0.6 + 0.4 * smoothstep(-1, 1, soft_noise(shape, 40.0, 2)))
    wear = np.clip(edge * breakup * 1.6, 0, 1) * wear_amount
    dirt = np.clip(1 - ao, 0, 1)

    out = col * (0.38 + 0.62 * ao[..., None] ** 0.8)
    out = out * (1 - 0.5 * dirt[..., None]) + out * DIRT_TINT * 0.5 * dirt[..., None]
    out = out * (1 - 0.85 * wear[..., None]) + WEAR_COLOR * 0.85 * wear[..., None]
    # Потёки грязи сверху вниз: темнее и теплее, блеск в них гаснет.
    out = out * (1 - 0.28 * streak[..., None]) + out * DIRT_TINT * 0.12 * streak[..., None]
    spec = spec * (1 - 0.5 * streak)

    gloss = np.clip(spec * (0.35 + 0.65 * ao) + 0.55 * wear, 0, 1)
    # Приглушённая палитра Source: на 18 % к серому.
    gray = out.mean(axis=2, keepdims=True)
    out = gray + (out - gray) * 0.82
    return np.clip(out, 0, 1), gloss, nrm


def half(a):
    return 0.25 * (a[0::2, 0::2] + a[1::2, 0::2] + a[0::2, 1::2] + a[1::2, 1::2])


def save_tga(path, rgb, alpha=None, color_data=True):
    h, w = rgb.shape[:2]
    rgba = np.ones((h, w, 4), np.float32)
    rgba[..., :3] = rgb
    if alpha is not None:
        rgba[..., 3] = alpha
    img = bpy.data.images.new(os.path.basename(path), w, h, alpha=alpha is not None)
    img.colorspace_settings.name = "sRGB" if color_data else "Non-Color"
    img.pixels.foreach_set(rgba.ravel())
    img.filepath_raw = path
    img.file_format = "TARGA_RAW"
    img.save()
    return img


# ---------------------------------------------------------------------------
# SMD, QC, materials.json
# ---------------------------------------------------------------------------

def write_body_smd(work, obj, self_lit_names):
    """kpp_lun_ref.smd с UV атласа и материалом kpp_body; порядок треугольников — как в OBJ."""
    me = obj.data
    loop_start = np.empty(len(me.polygons), np.int32)
    me.polygons.foreach_get("loop_start", loop_start)
    loop_total = np.empty(len(me.polygons), np.int32)
    me.polygons.foreach_get("loop_total", loop_total)
    corner_vert = np.empty(len(me.loops), np.int32)
    me.loops.foreach_get("vertex_index", corner_vert)
    co = np.empty(len(me.vertices) * 3, np.float32)
    me.vertices.foreach_get("co", co)
    co = co.reshape(-1, 3)
    uv = np.empty(len(me.loops) * 2, np.float32)
    me.uv_layers["atlas"].data.foreach_get("uv", uv)
    uv = uv.reshape(-1, 2)
    if (loop_total != 3).any():
        raise SystemExit("в меше есть не треугольники")

    with open(os.path.join(work, "kpp_lun_ref.smd"), encoding="utf-8") as f:
        lines = f.read().splitlines()
    start = lines.index("triangles") + 1
    out = lines[:start]
    i, t, worst = start, 0, 0.0
    while i < len(lines) and lines[i] != "end":
        if t >= len(loop_start):
            raise SystemExit("в SMD треугольников больше, чем в меше Blender")
        mat = lines[i]
        baked = mat not in self_lit_names
        out.append(BODY if baked else mat)
        for k in range(3):
            li = loop_start[t] + k
            parts = lines[i + 1 + k].split()
            pos = np.array([float(parts[1]), float(parts[2]), float(parts[3])])
            worst = max(worst, float(np.abs(co[corner_vert[li]] - pos).max()))
            if baked:
                parts[7], parts[8] = "%.6f" % uv[li, 0], "%.6f" % uv[li, 1]
            out.append(" ".join(parts))
        i += 4
        t += 1
    out += lines[i:]
    if t != len(loop_start) or worst > 2e-3:
        raise SystemExit("меш в Blender не совпал с SMD: треугольников %d/%d, расхождение %.4f" % (t, len(loop_start), worst))
    with open(os.path.join(work, "kpp_lun_body.smd"), "w", encoding="utf-8") as f:
        f.write(chr(10).join(out) + chr(10))
    log("kpp_lun_body.smd: %d треугольников, совпадение с исходным мешем %.5f", t, worst)


def update_qc_and_materials(work):
    qc_path = os.path.join(work, "kpp_lun.qc")
    with open(qc_path, encoding="utf-8") as f:
        qc = f.read()
    # Все ссылки ($body, $sequence, $collisionmodel): studiomdl берёт в MDL материалы из каждого
    # SMD, и старые плиточные остались бы в списке текстур (игра ругалась бы на их отсутствие).
    qc = qc.replace('"kpp_lun_ref.smd"', '"kpp_lun_body.smd"')
    with open(qc_path, "w", encoding="utf-8") as f:
        f.write(qc)

    spec_path = os.path.join(work, "materials.json")
    with open(spec_path, encoding="utf-8") as f:
        spec = json.load(f)
    source = spec.get("source") or {"materials": spec["materials"], "textures": spec["textures"]}
    mats = {k: v for k, v in source["materials"].items() if k in SELF_LIT}
    mats[BODY] = {"shader": "VertexLitGeneric", "params": BODY_VMT}
    textures = [t for t in source["textures"] if t in SELF_LIT or t == FLAT_NORMAL] + [BODY, BODY + "_normal"]
    with open(spec_path, "w", encoding="utf-8") as f:
        json.dump({"tex_dir": TEX_DIR, "materials": mats, "textures": textures, "source": source}, f,
                  ensure_ascii=False, indent=1)
    log("QC и materials.json: материалы %s", ", ".join(sorted(mats)))


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    work = os.path.abspath(argv[0] if argv else "art/kpp_lun")
    size = int(argv[argv.index("--size") + 1]) if "--size" in argv else 2048

    scene = render_lun.setup_scene()
    render_lun.import_model(work)
    obj = next(o for o in scene.objects if o.type == "MESH")
    names = [base_name(m) for m in obj.data.materials]
    self_lit_slots = {i for i, n in enumerate(names) if n in SELF_LIT}
    log("материалы: %s", ", ".join(names))

    setup_cycles(scene)
    if scene.world and hasattr(scene.world, "light_settings"):
        scene.world.light_settings.distance = 2.5
    atlas_unwrap(obj, self_lit_slots)
    write_body_smd(work, obj, set(SELF_LIT))       # до долгих проходов: несовпадение всплывёт сразу
    bake_mats = [BakeMaterial(m) for i, m in enumerate(obj.data.materials) if i not in self_lit_slots]

    img_col = new_image("bake_color", size, True)
    img_ao = new_image("bake_ao", size, False)
    img_par = new_image("bake_params", size, False)
    img_edge = new_image("bake_edges", size, False)
    img_nrm = new_image("bake_normal", size, False)
    bake(obj, bake_mats, img_col, "EMIT", 4, BakeMaterial.albedo)
    bake(obj, bake_mats, img_par, "EMIT", 4, BakeMaterial.params)
    bake(obj, bake_mats, img_edge, "EMIT", 24, BakeMaterial.edges)
    bake(obj, bake_mats, img_ao, "AO", 64, BakeMaterial.albedo)
    bake(obj, bake_mats, img_nrm, "NORMAL", 24, BakeMaterial.surface_with_round_edges)

    col, gloss, nrm = compose(pixels(img_col)[..., :3], pixels(img_ao)[..., 0], pixels(img_par),
                              pixels(img_edge)[..., 0], pixels(img_nrm)[..., :3])
    src = os.path.join(work, "materialsrc", *TEX_DIR.split("/"))
    os.makedirs(src, exist_ok=True)
    col_img = save_tga(os.path.join(src, BODY + ".tga"), col)
    n_small = half(nrm * 2 - 1)
    n_small /= np.maximum(np.linalg.norm(n_small, axis=2, keepdims=True), 1e-6)
    nrm_img = save_tga(os.path.join(src, BODY + "_normal.tga"), n_small * 0.5 + 0.5, half(gloss), color_data=False)
    with open(os.path.join(src, BODY + ".txt"), "w", encoding="ascii") as f:
        f.write("nocompress 0\n")
    with open(os.path.join(src, BODY + "_normal.txt"), "w", encoding="ascii") as f:
        f.write("normal 1\nnocompress 0\n")
    log("текстуры: %s (%d²), %s (%d²)", BODY + ".tga", size, BODY + "_normal.tga", size // 2)

    update_qc_and_materials(work)

    # Рендер с запечёнными текстурами с чистой сцены — ровно то, что уйдёт в игру.
    render_lun.render_work(work)


main()
