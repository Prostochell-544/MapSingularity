#!/usr/bin/env python3
"""
КПП «Лунь»: компиляция исходников в модель GMod и установка в аддон.

  python tools/model/compile_lun.py [--work art/kpp_lun] [--addon <папка аддона>] [--gmod <GarrysMod>]

  --work art/kpp_lun        — процедурная модель (kpp_lun_mesh.py), по умолчанию
  --work art/kpp_lun_tripo  — модель из Tripo (build_lun_from_glb.py)

1. vtex.exe (из GMod)     — materialsrc/*.tga -> materials/*.vtf (DXT, мипмапы)
2. studiomdl.exe (из GMod) — kpp_lun.qc -> models/map_singularity/kpp_lun.{mdl,vvd,vtx,phy}
3. VMT: из materials.json (процедурная модель) или один материал kpp_lun (Tripo).
4. Копирует модель и материалы в аддон; материалы прошлой сборки из папки
   materials/models/map_singularity/kpp_lun аддона удаляет — там всегда ровно текущая сборка.
Рабочая папка служит «игрой» для инструментов (gameinfo.txt создаётся сам) — папка GMod не трогается.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.normpath(os.path.join(HERE, "..", ".."))
DEFAULT_GMOD = r"C:\Program Files (x86)\Steam\steamapps\common\GarrysMod"
TEX_DIR = "models/map_singularity/kpp_lun"
MODEL_DIR = "models/map_singularity"

GAMEINFO = '''"GameInfo"
{
	game "kpp_lun_build"
	FileSystem
	{
		SteamAppId 4000
		SearchPaths
		{
			game |gameinfo_path|.
		}
	}
}
'''

# Материал модели из Tripo: одна текстура цвета + normal.
TRIPO_VMT = '''"VertexLitGeneric"
{
	"$basetexture"        "%(dir)s/kpp_lun_basecolor"
%(bump)s	"$phong"              "1"
	"$phongexponent"      "18"
	"$phongboost"         "1.5"
	"$phongfresnelranges" "[0.2 0.5 1]"
	"$halflambert"        "1"
}
'''


def run(cmd, cwd):
    print(">", " ".join('"%s"' % c if " " in c else c for c in cmd))
    proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, errors="replace")
    out = (proc.stdout or "") + (proc.stderr or "")
    for line in out.splitlines():
        low = line.lower()
        if "error" in low or "warning" in low or "completed" in low:
            print("   ", line.strip())
    if proc.returncode != 0 or "ERROR" in out:
        raise SystemExit("ошибка: %s (код %d)" % (cmd[0], proc.returncode))
    return out


def write_vmts(work, mat_out):
    """Пишет VMT; возвращает имена файлов материалов (.vmt и .vtf) этой сборки."""
    spec_path = os.path.join(work, "materials.json")
    names = []
    if os.path.exists(spec_path):
        with open(spec_path, encoding="utf-8") as f:
            spec = json.load(f)
        for name, m in spec["materials"].items():
            lines = ['"%s"' % m["shader"], "{"]
            for key, value in m["params"].items():
                lines.append('\t"%s" "%s"' % (key, value))
            lines.append("}")
            with open(os.path.join(mat_out, name + ".vmt"), "w", encoding="ascii") as f:
                f.write("\n".join(lines) + "\n")
            names.append(name + ".vmt")
        names += [t + ".vtf" for t in spec["textures"]]
    else:
        has_normal = os.path.exists(os.path.join(mat_out, "kpp_lun_normal.vtf"))
        bump = '\t"$bumpmap"            "%s/kpp_lun_normal"\n' % TEX_DIR if has_normal else ""
        with open(os.path.join(mat_out, "kpp_lun.vmt"), "w", encoding="ascii") as f:
            f.write(TRIPO_VMT % {"dir": TEX_DIR, "bump": bump})
        names = ["kpp_lun.vmt", "kpp_lun_basecolor.vtf"] + (["kpp_lun_normal.vtf"] if has_normal else [])
    return names


def main():
    ap = argparse.ArgumentParser(description="Компиляция КПП «Лунь» для GMod")
    ap.add_argument("--work", default=os.path.join(PROJECT, "art", "kpp_lun"))
    ap.add_argument("--gmod", default=DEFAULT_GMOD)
    ap.add_argument("--addon", default=None)
    args = ap.parse_args()

    work = os.path.abspath(args.work)
    gmod_bin = os.path.join(args.gmod, "bin")
    addon = args.addon or os.path.join(args.gmod, "garrysmod", "addons", "map_singularity")
    for tool in ("vtex.exe", "studiomdl.exe"):
        if not os.path.exists(os.path.join(gmod_bin, tool)):
            raise SystemExit("не найден %s в %s" % (tool, gmod_bin))
    qc = os.path.join(work, "kpp_lun.qc")
    if not os.path.exists(qc):
        raise SystemExit("нет %s — сначала kpp_lun_mesh.py или build_lun_from_glb.py" % qc)

    with open(os.path.join(work, "gameinfo.txt"), "w", encoding="ascii") as f:
        f.write(GAMEINFO)

    src_dir = os.path.join(work, "materialsrc", *TEX_DIR.split("/"))
    spec_path = os.path.join(work, "materials.json")
    if os.path.exists(spec_path):  # только текстуры, которые нужны материалам этой сборки
        with open(spec_path, encoding="utf-8") as f:
            wanted = [t + ".tga" for t in json.load(f)["textures"]]
    else:
        wanted = [n for n in sorted(os.listdir(src_dir)) if n.endswith(".tga")]
    for name in wanted:
        run([os.path.join(gmod_bin, "vtex.exe"), "-nopause", "-game", work, os.path.join(src_dir, name)], work)

    run([os.path.join(gmod_bin, "studiomdl.exe"), "-nop4", "-game", work, qc], work)

    mat_out = os.path.join(work, "materials", *TEX_DIR.split("/"))
    material_files = write_vmts(work, mat_out)
    missing = [n for n in material_files if not os.path.exists(os.path.join(mat_out, n))]
    if missing:
        raise SystemExit("не собрались материалы: %s" % ", ".join(missing))

    # Установка в аддон
    model_src = os.path.join(work, *MODEL_DIR.split("/"))
    model_dst = os.path.join(addon, *MODEL_DIR.split("/"))
    mat_dst = os.path.join(addon, "materials", *TEX_DIR.split("/"))
    os.makedirs(model_dst, exist_ok=True)
    os.makedirs(mat_dst, exist_ok=True)
    copied = []
    for name in sorted(os.listdir(model_src)):
        if name.startswith("kpp_lun."):
            shutil.copy2(os.path.join(model_src, name), os.path.join(model_dst, name))
            copied.append("%s/%s" % (MODEL_DIR, name))
    for name in material_files:
        shutil.copy2(os.path.join(mat_out, name), os.path.join(mat_dst, name))
        copied.append("materials/%s/%s" % (TEX_DIR, name))
    stale = [n for n in sorted(os.listdir(mat_dst)) if n.endswith((".vtf", ".vmt")) and n not in material_files]
    for name in stale:
        os.remove(os.path.join(mat_dst, name))

    print("установлено в аддон:", addon)
    total = 0
    for c in copied:
        size = os.path.getsize(os.path.join(addon, *c.split("/")))
        total += size
        print("   %-60s %8.1f КБ" % (c, size / 1024))
    print("   всего %.1f МБ" % (total / 1024 / 1024))
    if stale:
        print("удалены материалы прошлой сборки:", ", ".join(stale))


if __name__ == "__main__":
    sys.exit(main())
