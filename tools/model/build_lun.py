#!/usr/bin/env python3
"""
КПП «Лунь»: полная сборка процедурной модели одной командой.

  python tools/model/build_lun.py [--no-bake] [--size 2048] [--blender <blender.exe>]

1. kpp_lun_mesh.py  — меш, текстуры-плитки, QC, OBJ (art/kpp_lun)
2. bake_lun.py      — Blender: атлас, запекание AO/кромок/нормалей, рендеры render_*.png
3. compile_lun.py   — vtex + studiomdl, установка в аддон
--no-bake — без шага 2: модель на плиточных материалах (быстро, без Blender).
"""

import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.normpath(os.path.join(HERE, "..", ".."))
WORK = os.path.join(PROJECT, "art", "kpp_lun")
DEFAULT_BLENDER = r"C:\Program Files\Blender Foundation\Blender 5.3\blender.exe"


def step(title, cmd, cwd):
    print("\n=== %s" % title, flush=True)
    proc = subprocess.run(cmd, cwd=cwd)
    if proc.returncode != 0:
        raise SystemExit("шаг «%s» завершился с кодом %d" % (title, proc.returncode))


def main():
    ap = argparse.ArgumentParser(description="КПП «Лунь»: сборка процедурной модели")
    ap.add_argument("--no-bake", action="store_true")
    ap.add_argument("--size", type=int, default=2048)
    ap.add_argument("--blender", default=DEFAULT_BLENDER)
    args = ap.parse_args()

    py = sys.executable
    step("меш и текстуры", [py, os.path.join(HERE, "kpp_lun_mesh.py"), "--out", WORK], HERE)
    if not args.no_bake:
        if not os.path.exists(args.blender):
            raise SystemExit("нет Blender: %s (укажите --blender или --no-bake)" % args.blender)
        step("запекание в Blender", [args.blender, "--background", "--factory-startup", "--python",
                                     os.path.join(HERE, "bake_lun.py"), "--", WORK, "--size", str(args.size)], PROJECT)
    step("компиляция и установка", [py, os.path.join(HERE, "compile_lun.py"), "--work", WORK], PROJECT)
    print("\nготово. Рендеры: %s" % os.path.join(WORK, "render_*.png"))


if __name__ == "__main__":
    sys.exit(main())
