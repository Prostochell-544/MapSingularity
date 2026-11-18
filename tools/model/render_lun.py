"""
КПП «Лунь»: «красивый» рендер процедурной модели в Blender без интерфейса — для оценки вида.

  "C:/Program Files/Blender Foundation/Blender 5.3/blender.exe" --background --factory-startup \
      --python tools/model/render_lun.py -- art/kpp_lun

Импортирует kpp_lun.obj (материалы, текстуры, металличность/шероховатость/свечение — из MTL),
ставит трёхточечный свет и рендерит три ракурса в <папка>/render_*.png:
  three_quarter — слева спереди сверху, side — левый бок, shooter — из-за плеча стрелка.
Если модель запечена (QC указывает на kpp_lun_body.smd), атлас и kpp_body берутся из этого SMD —
рендер показывает ровно то, что уйдёт в игру. Тот же рендер вызывает в конце bake_lun.py.
"""

import math
import os
import sys

import bpy
from mathutils import Vector

ENGINES = ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "CYCLES")
VIEWS = {
    "three_quarter": Vector((22.0, 66.0, 26.0)),
    "side": Vector((0.0, 62.0, 3.0)),
    "shooter": Vector((-34.0, 16.0, 14.0)),
}


def log(msg, *args):
    print("[render] " + (msg % args if args else msg), flush=True)


def setup_scene():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    use_engine(scene, ENGINES)
    if scene.render.engine == "CYCLES":
        scene.cycles.samples = 48
    scene.render.resolution_x, scene.render.resolution_y = 1400, 800
    scene.render.film_transparent = False
    scene.view_settings.view_transform = "AgX" if "AgX" in [v.identifier for v in
                                                           scene.view_settings.bl_rna.properties["view_transform"].enum_items] else "Filmic"
    world = bpy.data.worlds.new("world")
    scene.world = world
    world.use_nodes = True
    bg = world.node_tree.nodes.get("Background")
    bg.inputs[0].default_value = (0.045, 0.05, 0.06, 1.0)
    bg.inputs[1].default_value = 0.8
    log("движок: %s", scene.render.engine)
    return scene


def use_engine(scene, engines):
    for engine in engines:
        try:
            scene.render.engine = engine
            return engine
        except TypeError:
            continue
    return scene.render.engine


def import_model(work):
    path = os.path.join(work, "kpp_lun.obj")
    # OBJ уже в осях Source (X вперёд, Z вверх) — как у Blender.
    bpy.ops.wm.obj_import(filepath=path, forward_axis="Y", up_axis="Z")
    objs = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    lo = Vector((min(min((o.matrix_world @ Vector(c))[i] for c in o.bound_box) for o in objs) for i in range(3)))
    hi = Vector((max(max((o.matrix_world @ Vector(c))[i] for c in o.bound_box) for o in objs) for i in range(3)))
    log("модель: %d объектов, габарит %s .. %s", len(objs), tuple(round(v, 2) for v in lo), tuple(round(v, 2) for v in hi))
    for o in objs:
        for poly in o.data.polygons:
            poly.use_smooth = True
    for mat in bpy.data.materials:
        if mat.node_tree and mat.name.startswith(("kpp_glow", "kpp_orb", "kpp_screen", "kpp_led", "kpp_tube")):
            bsdf = next((n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
            if bsdf and "Emission Strength" in bsdf.inputs:
                bsdf.inputs["Emission Strength"].default_value = 4.0 if not mat.name.startswith("kpp_screen") else 1.0
    return (lo + hi) / 2, (hi - lo).length


def add_light(name, loc, energy, size, color=(1, 1, 1)):
    data = bpy.data.lights.new(name, "AREA")
    data.energy, data.size, data.color = energy, size, color
    obj = bpy.data.objects.new(name, data)
    obj.location = loc
    bpy.context.scene.collection.objects.link(obj)
    return obj


def aim(obj, target):
    obj.rotation_euler = (target - obj.location).to_track_quat("-Z", "Y").to_euler()


def render_views(scene, center, work, prefix="render_"):
    """Трёхточечный свет, камера и три ракурса в <work>/<prefix><ракурс>.png."""
    for name, offset, energy, s, color in (("key", (10, 40, 45), 9000, 30, (1, 0.97, 0.92)),
                                           ("fill", (-30, 30, 5), 2500, 40, (0.85, 0.9, 1)),
                                           ("rim", (-10, -45, 30), 6000, 25, (0.9, 0.95, 1))):
        aim(add_light(name, center + Vector(offset), energy, s, color), center)

    cam_data = bpy.data.cameras.new("cam")
    cam_data.lens = 50
    cam = bpy.data.objects.new("cam", cam_data)
    scene.collection.objects.link(cam)
    scene.camera = cam
    for view, offset in VIEWS.items():
        cam.location = center + offset
        aim(cam, center + Vector((0, 0, -0.5)))
        scene.render.filepath = os.path.join(work, "%s%s.png" % (prefix, view))
        bpy.ops.render.render(write_still=True)
        log("%s -> %s", view, scene.render.filepath)


BODY = "kpp_body"
TEX_SUBDIR = os.path.join("materialsrc", "models", "map_singularity", "kpp_lun")


def baked_smd(work):
    """kpp_lun_body.smd, если QC модели на него переключён (модель запечена), иначе None."""
    qc = os.path.join(work, "kpp_lun.qc")
    path = os.path.join(work, "kpp_lun_body.smd")
    if os.path.exists(qc) and os.path.exists(path):
        with open(qc, encoding="utf-8") as f:
            if '"kpp_lun_body.smd"' in f.read():
                return path
    return None


def baked_material(work):
    """Запечённый материал: цвет атласа, нормали DirectX (зелёный перевёрнут), блеск из альфы."""
    mat = bpy.data.materials.new("kpp_body_preview")
    mat.use_nodes = True
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    bsdf = next(n for n in nodes if n.type == "BSDF_PRINCIPLED")
    uv = nodes.new("ShaderNodeUVMap")
    uv.uv_map = "atlas"
    col = nodes.new("ShaderNodeTexImage")
    col.image = bpy.data.images.load(os.path.join(work, TEX_SUBDIR, BODY + ".tga"))
    nrm = nodes.new("ShaderNodeTexImage")
    nrm.image = bpy.data.images.load(os.path.join(work, TEX_SUBDIR, BODY + "_normal.tga"))
    nrm.image.colorspace_settings.name = "Non-Color"
    for t in (col, nrm):
        links.new(uv.outputs["UV"], t.inputs["Vector"])
    links.new(col.outputs["Color"], bsdf.inputs["Base Color"])
    sep = nodes.new("ShaderNodeSeparateColor")
    links.new(nrm.outputs["Color"], sep.inputs["Color"])
    flip = nodes.new("ShaderNodeMath")
    flip.operation = "SUBTRACT"
    flip.inputs[0].default_value = 1.0
    links.new(sep.outputs[1], flip.inputs[1])
    comb = nodes.new("ShaderNodeCombineColor")
    links.new(sep.outputs[0], comb.inputs[0])
    links.new(flip.outputs[0], comb.inputs[1])
    links.new(sep.outputs[2], comb.inputs[2])
    nmap = nodes.new("ShaderNodeNormalMap")
    nmap.uv_map = "atlas"
    links.new(comb.outputs["Color"], nmap.inputs["Color"])
    links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
    rough = nodes.new("ShaderNodeMath")
    rough.operation = "MULTIPLY_ADD"
    rough.inputs[1].default_value = -0.55
    rough.inputs[2].default_value = 0.85
    links.new(nrm.outputs["Alpha"], rough.inputs[0])
    links.new(rough.outputs[0], bsdf.inputs["Roughness"])
    return mat


def apply_baked(obj, work, smd_path):
    """
    UV атласа и материал kpp_body — из kpp_lun_body.smd: треугольники в нём идут в том же
    порядке, что грани OBJ. Остальные детали (свечение, табличка) — со своими материалами
    и исходной UV, которая остаётся активной.
    """
    with open(smd_path, encoding="utf-8") as f:
        lines = f.read().splitlines()
    i = lines.index("triangles") + 1
    mats, uvs = [], []
    while lines[i] != "end":
        mats.append(lines[i])
        for k in range(3):
            p = lines[i + 1 + k].split()
            uvs.append((float(p[7]), float(p[8])))
        i += 4
    me = obj.data
    if len(mats) != len(me.polygons):
        raise SystemExit("SMD (%d) и OBJ (%d) разошлись — пересоберите модель" % (len(mats), len(me.polygons)))
    loop_start = [0] * len(me.polygons)
    me.polygons.foreach_get("loop_start", loop_start)
    uv = [0.0] * (len(me.loops) * 2)
    me.uv_layers["UVMap"].data.foreach_get("uv", uv)
    for t, start in enumerate(loop_start):
        if mats[t] == BODY:
            for k in range(3):
                uv[(start + k) * 2], uv[(start + k) * 2 + 1] = uvs[t * 3 + k]
    atlas = me.uv_layers.new(name="atlas")
    atlas.data.foreach_set("uv", uv)
    me.uv_layers.active = me.uv_layers["UVMap"]
    me.uv_layers["UVMap"].active_render = True

    me.materials.append(baked_material(work))
    slot = len(me.materials) - 1
    idx = [0] * len(me.polygons)
    me.polygons.foreach_get("material_index", idx)
    idx = [slot if mats[t] == BODY else m for t, m in enumerate(idx)]
    me.polygons.foreach_set("material_index", idx)
    me.update()
    log("запечённая модель: %d граней на атласе", sum(1 for m in mats if m == BODY))


def render_work(work):
    """Чистая сцена -> импорт OBJ (+ атлас, если модель запечена) -> три ракурса."""
    scene = setup_scene()
    center, _ = import_model(work)
    smd = baked_smd(work)
    if smd:
        apply_baked(next(o for o in scene.objects if o.type == "MESH"), work, smd)
    render_views(scene, center, work)


def main():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    render_work(os.path.abspath(argv[0] if argv else "art/kpp_lun"))


if __name__ == "__main__":
    main()
