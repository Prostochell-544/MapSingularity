# MapSingularity: Seamless Workshop Roulette (Garry's Mod)

Аддон на чистом GLua: в фоне находит случайную хорошо оценённую карту мастерской,
скачивает и монтирует её, прогревает ассеты из BSP и открывает портал. Вход в портал —
FOV-растяжение, радиальный блюр, глушение звука, затемнение; пробуждение на новой
карте с сохранёнными HP/бронёй/оружием/патронами. Без `.dll` и внешних бинарников.

## Папки

| Что | Где |
|---|---|
| Документация, заметки, `NEXT-SESSION.md` | `C:\Project-work\garry_roulette` |
| **Живой код аддона** (весь `.lua`, `addon.json`, ассеты) | `C:\Program Files (x86)\Steam\steamapps\common\GarrysMod\garrysmod\addons\map_singularity` |

Код пишем только в папку аддона — GMod подхватывает правки на лету (Lua autorefresh).
**Git:** репозиторий — папка проекта (`https://github.com/Prostochell-544/MapSingularity`, ветка `main`). Аддон в нём — копия `addon/map_singularity/`: перед коммитом `python tools/sync_addon.py`. Не коммитятся (`.gitignore`): сгенерированные `art/kpp_lun*` (кроме рендеров), производные Tripo, текстуры Valve, `release/*.gma`, `*.zip` — GMA и `MapSingularity_HostLoadingScreen.zip` прикладываются к GitHub Release (ссылка в описаниях: `releases/latest/download/MapSingularity_HostLoadingScreen.zip`). Мастерская: ID 3842113997.
`docs/ARCHITECTURE.md` — подробная архитектура, `NEXT-SESSION.md` — состояние и план.
`docs/HOST-GUIDE.md` — инструкция: тоннель для подключающихся игроков и для хоста.
`web/ms_tunnel.js` — анимация тоннеля (canvas, ES5); `web/portal_loading.html` — страница для `ms_loading_url`.
**Модель «Луня» в аддоне** (`models/map_singularity/kpp_lun.mdl`) — **процедурная** (с 2026-11-18, по выбору пользователя: модель из Tripo «оплывшая»). Сборка одной командой `python tools/model/build_lun.py` (меш → запекание в Blender → компиляция; `--no-bake` — без Blender). По шагам: `python tools/model/kpp_lun_mesh.py` (numpy, без Blender: меш → `art/kpp_lun/` — SMD с костями ТЗ, игровой QC, OBJ+MTL, отчёт о чистоте; текстуры — `kpp_lun_textures.py`: бесшовный шум через БПФ под кубическую UV, табличка с маркировкой шрифтом Bahnschrift под подогнанную UV, `materials.json` с параметрами VMT) и `python tools/model/compile_lun.py` (`vtex` + `studiomdl` из `GarrysMod/bin` → аддон; VMT из `materials.json`; удаляет из аддона материалы прошлой сборки). Запекание — `tools/model/bake_lun.py` (Blender, Cycles): сварка вершин OBJ → умная развёртка в атлас для непрозрачных деталей → проходы цвет/параметры/кромки (Emission), AO, нормали скруглённых фасок (Bevel, DirectX −Y) → сборка в numpy: `kpp_body.tga` 2048² и `kpp_body_normal.tga` 1024² (блеск в альфе), `kpp_lun_body.smd` (UV атласа, материал `kpp_body`), QC и `materials.json` переключаются на него; светящиеся материалы и табличка остаются со своими текстурами; в конце — рендеры `render_*.png`. `tools/model/render_lun.py` (EEVEE) сам узнаёт запечённую модель и берёт UV атласа из `kpp_lun_body.smd`. В Blender 5.3 ссылки на данные меша после смены режима недействительны (падение `attribute_type_to_cpp_type`) — брать заново, пачкой через `foreach_get/set`; studiomdl кладёт в MDL материалы из всех SMD в QC — `$sequence`/`$collisionmodel` на тот же SMD. Модель из Tripo осталась альтернативой: `build_lun_from_glb.py` → `art/kpp_lun_tripo/`, затем `compile_lun.py --work art/kpp_lun_tripo`. MCP для Blender не нужен — всё через CLI. От первого лица «Лунь» — ClientsideModel, поставленная **от камеры вьюмодели** (`vm:GetPos()`/`GetAngles()`, конвары `ms_lunk_vm_*`; при смене модели поднимать `TUNE_VERSION` — сохранённая подгонка сбросится один раз), без рук: `c_physcannon` — лишь скрытый (`render.SetBlend(0)`) носитель кадра. К костям донорской вьюмодели не привязываться: аддоны мастерской подменяют `c_physcannon` (у пользователя в подменённой нет костей `Base`/`Handle`, кисть за кадром). Мировая модель — от `ValveBiped.Bip01_R_Hand` по прицелу (`ms_lunk_wm_*`). Экран прибора — 3D2D между точками крепления `screen` (левый верх) и `screen_br` (правый низ): размер и масштаб модели берутся из них; в процедурной модели это углы детали `screen_glass`, в модели из Tripo стекло ищет `fit_screen_glass` (там стекло утоплено в рамку на ~2 юнита — отступы подобраны трассировкой лучей из глаза). Кадр без игры — `tools/model/preview_viewmodel.py --x --y --z --p --yw --r --s` (та же математика, что в Lua; поворот, панель экрана и материалы — из QC/SMD папки `--work`). В Blender 5.3 раскраска по атрибуту — `color_type = 'VERTEX'`. `vtex` без `-nopause` висит в ожидании клавиши.
`tools/host-tunnel-patch.ps1` — патч `garrysmod/html/loading.html` у хоста (install/uninstall/status). Файл в UTF-8 **с BOM** — иначе PowerShell 5.1 ломает кириллицу.
Для игроков из мастерской — самодостаточный установщик того же патча: `python tools/build_host_installer.py` → `release/MapSingularity_HostLoadingScreen.zip` (ps1 из шаблона `tools/host_installer_template.ps1` со встроенными base64 `web/ms_tunnel.js` и `ms_prime.html`, сам ищет GMod по реестру Steam и `libraryfolders.vdf`, сам просит права администратора, сообщения uk/ru/en по языку системы; `install.bat`/`uninstall.bat`/`status.bat`, README на трёх языках). В GMA его не положить (нет `.ps1/.js/.html` в whitelist) — раздаётся ссылкой. **PowerShell считает типографские ‘ ’ “ ” кавычками** — в строках скрипта их быть не должно (сборщик проверяет).
`CLAUDE.md.md` — исходный черновик брифа, оставлен для истории.

## Карта файлов аддона

| Файл | Реалм | Ответственность |
|---|---|---|
| `lua/autorun/ms_init.lua` | shared | порядок загрузки, `AddCSLuaFile`, `resource.AddSingleFile` |
| `lua/map_singularity/sh_config.lua` | shared | константы, фазы, net-строки, конвары, лог, `MS.Amortize` |
| `lua/map_singularity/sh_lang.lua` | shared | переводы en/uk/ru (`MS.T`, язык `ms_cl_language`, auto = язык GMod), `MS.Notice` (сервер шлёт ключ фразы — переводит клиент), клиентские `ms_cl_notices` / `ms_cl_debug` / `ms_cl_portal_style` |
| `lua/map_singularity/sv_workshop.lua` | server | поиск кандидатов, фильтры, рейтинг, скачивание, `MountGMA`, выбор `.bsp` |
| `lua/map_singularity/sv_precache.lua` | server | бинарный разбор BSP (Lump 0 + game lump `sprp`), амортизированный прекэш |
| `lua/map_singularity/sv_inventory.lua` | server | снимок/восстановление игроков, хайджек `sv_loadingurl`, changelevel, откат |
| `lua/map_singularity/sv_director.lua` | server | машина состояний, портал, синхронизация клиентов, консольные команды |
| `lua/map_singularity/cl_prefetch.lua` | client | `DownloadUGC` для хоста, префетч карты, сигнал готовности |
| `lua/map_singularity/cl_visuals.lua` | client | FOV, вихревой блюр, спагеттификация, чёрный оверлей, HUD-статус |
| `lua/map_singularity/cl_settings.lua` | client | панель Q → «Утилиты» → MapSingularity → «Настройки»: язык, сервер, вид портала, сообщения/отладка, действия, сворачиваемая «Положение пушки» |
| `lua/entities/roulette_portal/` | shared | энтити портала: триггер, притяжение (`Move`), окно-тоннель (stencil), радужный диск |
| `lua/weapons/weapon_singularity.lua` | shared | КПП «Лунь» (Комплекс Просторового Переходу): ЛКМ портал, ПКМ другая карта, R схлопнуть; экран прибора `MS.DrawLunScreen`; сам берёт модель `models/map_singularity/kpp_lun.mdl` (от камеры, процедурные доставание/отдача), пока её нет — пистолет HL2; диагностика `ms_lun_where`. ТЗ на модель — `docs/MODEL-SPEC-LUN.md` |
| `lua/effects/ms_singularity_shot.lua` | client | луч выстрела пушки |
| `materials/map_singularity/portal_void.png` | — | чёрный экран загрузки для `asset://` |

## Проверенные факты движка (не переоткрывать)

- `steamworks.DownloadUGC` — **только Client/Menu**. На listen/SP качает хост-клиент, сервер монтирует тот же путь (процесс общий). На выделенном сервере — HTTP по `file_url`.
- `steamworks.GetList` и `steamworks.FileInfo` — **Shared**: работают на сервере, ключ Web API не нужен. `FileInfo` отдаёт `up/down/total/score`.
- `IPublishedFileService/QueryFiles` без ключа → 403. `ISteamRemoteStorage/GetPublishedFileDetails` (POST, без ключа) отдаёт `tags`, `banned`, `file_size`, `file_url`, но не голоса. Регистр тегов разный (`map`, `Weapon`) — сравнивать в нижнем регистре.
- `file_url` отдаёт GMA в формате Bootil LZMA (`props[5] + uint64 size + поток`, первый байт `0x5D`) — это ровно то, что ест `util.Decompress`.
- Меню GMod показывает `sv_loadingurl` только если URL начинается с `http` или `asset://`, `maxplayers > 1` и у клиента `cl_enable_loadingurl 1` (`lua/menu/loading.lua`, `GameDetails`). Для того, кто сам хостит игру (`IsHostingGame()`: одиночная игра **и хост listen-сервера**), меню вызывает `GameDetails(..., "127.0.0.1", map, 1, ...)` — кастомный экран загрузки там не показывается никогда, видна стандартная страница. Подтверждено в игре 2026-11-17. Чёрный экран увидят только подключённые к серверу клиенты.
- Сервер отдаёт клиентам serverinfo (и URL загрузки) после активации карты, т.е. **после** `InitPostEntity`. Поэтому `sv_loadingurl` возвращаем, когда все путешественники уже в игре (или по таймауту), а не в `InitPostEntity`.
- `util.JSONToTable` превращает числовые строковые ключи в числа (SteamID64 теряет точность, аммо `"357"` становится ID 357). Игроки и патроны хранятся массивами.
- `Material()` на несуществующий `.vmt` кэширует error-материал, который `MountGMA` потом не перезагружает. Перед `Material()`/`util.PrecacheModel` всегда `file.Exists(..., "GAME")`. Ассеты из pakfile BSP недоступны до загрузки карты — их пропускаем.
- `prop_static` нет в Entity Lump — модели берём из словаря game lump `sprp` (lump 35).
- Свежие компиляторы (VRAD++ и др.) сжимают Entity Lump и game lump'ы Valve-LZMA: заголовок 17 байт (`LZMA`, actual, packed, props[5]) — в Lua это `sub(13,17)` для props и поток с 18-го байта. У сжатого game lump поле `filelen` в каталоге = распакованный размер, сжатый берём из LZMA-заголовка. Проверено на gm_titan (3796444652). Сбой распаковки не повод отбраковывать карту — движок её грузит.
- `Couldn't write cache/map_pack.bsp to mount embedded content!` в одиночной игре — норма: файл уже записал и смонтировал другой реалм того же процесса (размер `cache/map_pack.bsp` совпал с BSP новой карты байт в байт). `BSP embedded file failed whitelist check` — особенность конкретной карты.
- Консоль Source считает `//` началом комментария: URL в консоли **только в кавычках**, иначе от `asset://…` остаётся `asset:` (так и случилось в игре). Аддон распознаёт обрезанное значение (`^%a+:/?$`) и берёт `MS_LOADING_URL` по умолчанию.
- В whitelist GMA (Facepunch/gmad `AddonWhiteList.h`) нет `.html`, `.js`, `.gif` — анимированный экран через мастерскую не раздать, только http-страница для гостей или локальный патч для хоста.
- Из Lua заблокированы `connect`, `map`, `exec`, `quit`; `hostname` и `sv_loadingurl` — нет. Перевести игрока на другой сервер можно только с подтверждением (`permissions.AskToConnect`). Запускать программы Lua не может.
- Страница загрузки меню не объявляет charset — внешние `.js` декодируются как windows-1252. В JS для меню только ASCII в коде (не-ASCII символы — через `String.fromCharCode`). И помнить: инструмент Write превращает `'\uXXXX'` в литеральный символ.
- При `changelevel` меню вызывает `GameDetails` для хоста поздно — после загрузки серверной части (подтверждено логом). Ранний сигнал — localStorage через невидимый клиентский DHTML с `asset://garrysmod/html/ms_prime.html`.
- Хосту меню передаёт в `GameDetails` только `hostname`: метка U+2063 в конце hostname — канал «это прыжок» для патча хоста (проверено в браузере: с меткой тоннель, без метки и без вызова — обычная страница).
- `studiomdl` по умолчанию поворачивает модель на +90° вокруг Z (ось X из SMD становится +Y модели). `$origin 0 0 0 -90` отменяет поворот — проверено по габаритам скомпилированного MDL (hull по X −9,75…33,75). Точки крепления поворачиваются вместе с мешем. Изменённую модель игра подхватывает только после перезапуска.
- vtex не собирает DXT из TGA со сторонами не степени двойки (`Can't convert image ... in CalcLowResImage`).
- Звуки/материалы портала проверены по VPK: `ambient/levels/citadel/portal_beam_loop1.wav`, `ambient/levels/labs/teleport_*`, `effects/strider_pinch_dudv`, `sprites/light_glow02_add`, `effects/select_ring`, `sprites/physbeama`.

## Правила кода

- Чистый GLua, синтаксис Lua 5.1 (без `continue`, `!=`, `&&`, `//`), чтобы файлы проверялись стандартным парсером.
- Никаких заглушек и `TODO`: каждый асинхронный шаг имеет таймаут и путь отката.
- Глобально только `MapSingularity` (и константа `MS_LOADING_URL`). Внутри файлов — `local MS = MapSingularity`.
- Любой асинхронный колбэк режиссёра проверяет `token` — после отмены старые колбэки молча выходят.
- Тяжёлая работа — только через `MS.Amortize` с бюджетом времени на тик.
- Лог — `MS.Log` / `MS.Warn`, сообщения на русском (служебные, для консоли).
- Всё, что видит игрок (кроме модели), — через `MS.T(key)` на трёх языках (`sh_lang.lua`); сервер
  игроку пишет только `MS.Notice(ply, kind, key, ...)`: важное (`NOTICE_CHAT`/`NOTICE_POPUP`, по
  `ms_cl_notices`) или отладку (`NOTICE_DEBUG`, сырой текст, только при `ms_cl_debug`). Причины отказа
  из режиссёра (`D.Start`, `SpotFromAim`) — ключи фраз. Без англицизмов в названиях («Лучшие карты»,
  «Вся мастерская»).
- Net-строки регистрируются только в `sh_config.lua` (`MS.Net`).

## Проверка без запуска игры

```bash
node <scratch>/check.js <scratch>/lp "<addon>/lua"    # luaparse: синтаксис + список глобалов
node <scratch>/bsptest.js <scratch>/lp "<addon>/lua/map_singularity/sv_precache.lua" "<gmod>/maps/gm_construct.bsp"
```
Скрипты лежат во временной папке сессии; при необходимости пересоздать (luaparse 0.3.1 + fengari 0.1.4 через npm).

## Тест в игре

`ms_force_fetch` (рулетка) или `ms_force_fetch <workshop id|ссылка>` → дождаться «Портал стабилен» → войти.
`ms_status`, `ms_abort`, `ms_portal_here`. Нужны права superadmin (или хост/консоль).
