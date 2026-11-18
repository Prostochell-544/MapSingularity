#!/usr/bin/env python3
"""
Копия живого аддона (папка GMod) в репозиторий: addon/map_singularity/.

  python tools/sync_addon.py [--src "<GarrysMod>/garrysmod/addons/map_singularity"]

Код пишется в папку аддона (GMod подхватывает правки на лету); перед коммитом эта
команда приводит addon/map_singularity в репозитории к ней точно — лишние файлы удаляются.
"""

import argparse
import os
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.normpath(os.path.join(HERE, ".."))
DEFAULT_SRC = r"C:\Program Files (x86)\Steam\steamapps\common\GarrysMod\garrysmod\addons\map_singularity"


def main():
    ap = argparse.ArgumentParser(description="Синхронизация аддона в репозиторий")
    ap.add_argument("--src", default=DEFAULT_SRC)
    args = ap.parse_args()
    dst = os.path.join(PROJECT, "addon", "map_singularity")
    if not os.path.isfile(os.path.join(args.src, "addon.json")):
        raise SystemExit("нет addon.json в %s" % args.src)
    if os.path.isdir(dst):
        shutil.rmtree(dst)
    shutil.copytree(args.src, dst)
    count = sum(len(files) for _, _, files in os.walk(dst))
    print("-> %s (%d файлов)" % (dst, count))


if __name__ == "__main__":
    main()
