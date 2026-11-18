"""
Иконка аддона для мастерской (512x512 JPG), минималистичная: плоский фон, один предмет,
без свечений и градиентов. Три варианта:
  hole       — знак чёрной дыры: чёрный круг и тонкое оранжевое кольцо диска;
  silhouette — силуэт «Луня» сбоку и оранжевая точка шара между когтями;
  render     — чистый боковой рендер «Луня» (запечённые текстуры) на ровном фоне.

1) Blender рендерит бок пушки с прозрачным фоном (для silhouette и render):
   "C:/Program Files/Blender Foundation/Blender 5.3/blender.exe" --background --factory-startup \
       --python tools/model/render_icon.py -- art/kpp_lun release/gun_side.png
2) Обычный Python собирает иконки:
   python tools/model/render_icon.py --compose release/gun_side.png release "<папка аддона>"
   -> release/icon.jpg (чёрная дыра + название — выбор пользователя), а в аддоне
      materials/entities/weapon_singularity.png и roulette_portal.png (меню спавна, 256²)
"""

import os
import sys

BG = (232, 227, 214)        # тёплый светлый «бумажный»
INK = (28, 28, 26)
ORANGE = (232, 120, 40)
SIZE = 512
SS = 4                      # суперсэмплинг для ровных краёв

# Габарит модели по X и Z и положение шара (из отчёта kpp_lun_mesh.py / QC).
MODEL_X = (-10.66, 27.42)
MODEL_Z = (-5.45, 6.48)
ORB = (24.57, 0.45)


def blender_side(work, out):
    import bpy
    from mathutils import Vector
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import render_lun

    scene = render_lun.setup_scene()
    center, _ = render_lun.import_model(work)
    smd = render_lun.baked_smd(work)
    if smd:
        render_lun.apply_baked(next(o for o in scene.objects if o.type == "MESH"), work, smd)
    scene.render.film_transparent = True
    scene.render.resolution_x, scene.render.resolution_y = 2048, 1024
    scene.view_settings.view_transform = "Standard"
    for name, offset, energy, s in (("key", (6, 40, 40), 9000, 30), ("fill", (-20, 40, -5), 3000, 40)):
        render_lun.aim(render_lun.add_light(name, center + Vector(offset), energy, s), center)
    cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
    cam.data.type = "ORTHO"
    cam.data.ortho_scale = 44
    scene.collection.objects.link(cam)
    scene.camera = cam
    cam.location = center + Vector((0, 80, 0))
    render_lun.aim(cam, center)
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.filepath = os.path.abspath(out)
    bpy.ops.render.render(write_still=True)
    render_lun.log("бок пушки -> %s", out)


FONTS = ["C:/Windows/Fonts/bahnschrift.ttf", "C:/Windows/Fonts/arialbd.ttf"]


def font(size, variation="Bold"):
    from PIL import ImageFont
    for path in FONTS:
        if os.path.exists(path):
            f = ImageFont.truetype(path, size)
            try:
                f.set_variation_by_name(variation)
            except Exception:
                pass
            return f
    return ImageFont.load_default()


def draw_hole(d, cx, cy, r):
    """Чёрная дыра: дальняя половина кольца диска, круг поверх, ближняя половина."""
    ring = [cx - r * 1.8, cy - r * 0.42, cx + r * 1.8, cy + r * 0.42]
    w = max(2, int(r * 0.09))
    d.arc(ring, 180, 360, fill=ORANGE, width=w)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=INK)
    d.arc(ring, 0, 180, fill=ORANGE, width=w)


def centered_text(d, text, cy, f, fill, S, spacing=0):
    """Строка по центру; spacing — разрядка между буквами (доля размера шрифта)."""
    if spacing:
        widths = [f.getlength(ch) for ch in text]
        gap = f.size * spacing
        total = sum(widths) + gap * (len(text) - 1)
        x = (S - total) / 2
        for ch, wch in zip(text, widths):
            d.text((x, cy), ch, font=f, fill=fill, anchor="lm")
            x += wch + gap
    else:
        d.text((S / 2, cy), text, font=f, fill=fill, anchor="mm")


def compose(side_png, out_dir, addon_dir=None):
    """Иконка мода (icon.jpg) и, если указан аддон, иконки меню спавна (materials/entities)."""
    from PIL import Image, ImageDraw

    S = SIZE * SS

    def canvas(size=S):
        return Image.new("RGB", (size, size), BG)

    # Иконка мода: чёрная дыра и название под ней.
    img = canvas()
    d = ImageDraw.Draw(img)
    draw_hole(d, S / 2, S * 0.40, S * 0.165)
    title = "MapSingularity"
    size = int(S * 0.13)
    f = font(size)
    while f.getlength(title) > S * 0.84:
        size -= 4
        f = font(size)
    centered_text(d, title, S * 0.735, f, INK, S)
    centered_text(d, "WORKSHOP ROULETTE", S * 0.84, font(int(S * 0.045), "Regular"), (120, 116, 106), S, spacing=0.35)
    path = os.path.join(out_dir, "icon.jpg")
    img.resize((SIZE, SIZE), Image.LANCZOS).save(path, quality=94)
    print("->", path)

    if not addon_dir:
        return
    ent_dir = os.path.join(addon_dir, "materials", "entities")
    os.makedirs(ent_dir, exist_ok=True)
    E = 256 * SS

    # Портал в меню спавна — та же чёрная дыра без текста.
    img = canvas(E)
    draw_hole(ImageDraw.Draw(img), E / 2, E / 2, E * 0.22)
    img.resize((256, 256), Image.LANCZOS).save(os.path.join(ent_dir, "roulette_portal.png"))

    # Пушка — цветной рендер по диагонали (длинная модель иначе мелкая в квадрате).
    side = Image.open(side_png).convert("RGBA")
    side = side.crop(side.getbbox())
    side = side.transpose(Image.FLIP_LEFT_RIGHT)  # стволом вправо-вверх
    side = side.rotate(32, resample=Image.BICUBIC, expand=True)
    side = side.crop(side.getbbox())
    k = E * 0.9 / max(side.width, side.height)
    side = side.resize((int(side.width * k), int(side.height * k)), Image.LANCZOS)
    img = canvas(E)
    img.paste(side, ((E - side.width) // 2, (E - side.height) // 2), side)
    img.resize((256, 256), Image.LANCZOS).save(os.path.join(ent_dir, "weapon_singularity.png"))
    print("-> иконки меню спавна:", ent_dir)


if __name__ == "__main__":
    if "--compose" in sys.argv:
        i = sys.argv.index("--compose")
        compose(sys.argv[i + 1], sys.argv[i + 2], sys.argv[i + 3] if len(sys.argv) > i + 3 else None)
    else:
        argv = sys.argv[sys.argv.index("--") + 1:]
        blender_side(os.path.abspath(argv[0]), argv[1])
