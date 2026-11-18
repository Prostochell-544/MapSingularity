#!/usr/bin/env python3
"""
Сборка самодостаточного установщика экрана загрузки для хоста (раздаётся отдельно от
мастерской: в GMA нельзя .ps1/.js/.html).

  python tools/build_host_installer.py
  -> release/MapSingularity_HostLoadingScreen/  (ps1 со встроенными web/ms_tunnel.js и ms_prime.html,
     install.bat, uninstall.bat, status.bat, README.txt) и release/MapSingularity_HostLoadingScreen.zip

Шаблон — tools/host_installer_template.ps1; файлы тоннеля встраиваются base64 из web/ при каждой
сборке, так что установщик не расходится с кодом. PS1 пишется в UTF-8 с BOM — иначе Windows
PowerShell 5.1 ломает кириллицу.
"""

import base64
import os
import shutil
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.normpath(os.path.join(HERE, ".."))
NAME = "MapSingularity_HostLoadingScreen"
PS1 = "MapSingularity-HostLoadingScreen.ps1"

BAT = '@echo off\r\npowershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0' + PS1 + '" {action}\r\npause\r\n'

README = """MapSingularity — Host loading screen / Екран завантаження для хоста / Экран загрузки для хоста
================================================================================================

EN
--
Garry's Mod always shows its own loading page to whoever hosts the game (singleplayer or the host
of a listen server), so the addon's portal tunnel is only visible to players who connect to you.
This installer adds the tunnel to the host's loading page too. It only appears while jumping
through a portal; normal map loads look the same as before.

  install.bat    — install (double-click). Restart Garry's Mod afterwards.
  uninstall.bat  — remove, the game file goes back to the original.
  status.bat     — check whether it is installed.

The game folder is found automatically (all Steam libraries). It changes a file of the game itself
(garrysmod\\html\\loading.html) and keeps a backup next to it. A GMod update or "Verify integrity of
game files" in Steam restores the original — just run install.bat again.
If the game is in Program Files, Windows will ask for administrator rights.

UK
--
Тому, хто сам запускає гру (одиночна гра або хост listen-сервера), Garry's Mod завжди показує
свою сторінку завантаження, тож тунель порталу бачать лише ті, хто до вас підключається.
Цей інсталятор додає тунель і на сторінку хоста. Він з'являється тільки під час стрибка через
портал; звичайні завантаження карт не змінюються.

  install.bat    — встановити (подвійний клік). Потім перезапустіть Garry's Mod.
  uninstall.bat  — прибрати, файл гри повернеться до початкового.
  status.bat     — перевірити, чи встановлено.

Папку гри знайде сам (усі бібліотеки Steam). Змінюється файл самої гри
(garrysmod\\html\\loading.html), поруч лишається резервна копія. Оновлення GMod або «Перевірити
цілісність файлів гри» в Steam повернуть оригінал — просто запустіть install.bat ще раз.
Якщо гра лежить у Program Files, Windows попросить права адміністратора.

RU
--
Тому, кто сам запускает игру (одиночная игра или хост listen-сервера), Garry's Mod всегда
показывает свою страницу загрузки, поэтому тоннель портала видят только те, кто к вам
подключается. Этот установщик добавляет тоннель и на страницу хоста. Он появляется только во
время прыжка через портал; обычные загрузки карт не меняются.

  install.bat    — установить (двойной щелчок). Потом перезапустите Garry's Mod.
  uninstall.bat  — убрать, файл игры вернётся к исходному.
  status.bat     — проверить, установлено ли.

Папку игры найдёт сам (все библиотеки Steam). Меняется файл самой игры
(garrysmod\\html\\loading.html), рядом остаётся резервная копия. Обновление GMod или «Проверить
целостность файлов игры» в Steam вернут оригинал — просто запустите install.bat ещё раз.
Если игра лежит в Program Files, Windows попросит права администратора.
"""


def b64(path):
    with open(path, "rb") as f:
        return base64.b64encode(f.read()).decode("ascii")


def main():
    out = os.path.join(PROJECT, "release", NAME)
    if os.path.isdir(out):
        shutil.rmtree(out)
    os.makedirs(out)

    with open(os.path.join(HERE, "host_installer_template.ps1"), encoding="utf-8-sig") as f:
        script = f.read()
    script = script.replace("@@TUNNEL_B64@@", b64(os.path.join(PROJECT, "web", "ms_tunnel.js")))
    script = script.replace("@@PRIME_B64@@", b64(os.path.join(PROJECT, "web", "ms_prime.html")))
    assert "@@" not in script
    with open(os.path.join(out, PS1), "w", encoding="utf-8-sig", newline="\r\n") as f:
        f.write(script)

    for action in ("install", "uninstall", "status"):
        with open(os.path.join(out, action + ".bat"), "w", encoding="ascii", newline="") as f:
            f.write(BAT.format(action=action))
    with open(os.path.join(out, "README.txt"), "w", encoding="utf-8-sig", newline="\r\n") as f:
        f.write(README)

    zpath = os.path.join(PROJECT, "release", NAME + ".zip")
    with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
        for name in sorted(os.listdir(out)):
            z.write(os.path.join(out, name), os.path.join(NAME, name))
    print("->", out)
    print("->", zpath, "(%.1f КБ)" % (os.path.getsize(zpath) / 1024))


if __name__ == "__main__":
    main()
