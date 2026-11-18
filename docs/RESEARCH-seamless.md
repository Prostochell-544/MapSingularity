# Исследование: бесшовные переходы между картами (GMod / Source) — 2026-11-17

Вопрос: есть ли готовые проекты, которые делают смену карты в GMod незаметнее, чем наш
подход (затемнение → changelevel → чёрный экран → растворение), особенно для хоста.

## Что нашлось

| Проект | Что делает | Чем полезен нам |
|---|---|---|
| **Half-Life 2 Campaign** (hl2c, форк [hl2c Eternal](https://github.com/Uklejamini357/hl2c_ex-mode), обновлялся 2026-11) | Кооперативное прохождение HL2 в GMod | Тот же приём, что у нас: обычный `changelevel` + JSON на игрока в `data/` (HP, броня, оружие с обоймами, патроны, фраги/смерти). `trigger_changelevel` перехватывают через `GM:EntityKeyValue`. Подтверждает выбранную архитектуру. |
| **SourceBox** ([moddb](https://www.moddb.com/mods/sourcebox/features/sourcebox-build-20-showcase)) | Порт HL2 для GMod-мультиплеера | Поддержка `changelevel2` в мультиплеере с переносом энтити — нужна общая геометрия/лендмарки, к случайным картам не применимо. |
| **Level Transition Fix** ([каталог](https://catalogue.smods.ru/?p=101309)) | Чинит точку спавна после переходов в HL2-кампаниях | Только для карт с `info_landmark`. |
| **Thyper Space System** ([BuiltByBit](https://builtbybit.com/resources/thyper-space-system.104212/), платный) | «Гиперпространственный» интерфейс поверх `changelevel` | Ближе всего по идее (визуальная маскировка), код закрыт; перенос оружия не заявлен. |
| Платные экраны загрузки GModStore ([пример](https://gmodstore.com/market/view/80-aniq-load-gmod-loading-screen)) | HTML-экраны через `sv_loadingurl` | Работают только для подключающихся клиентов — то же ограничение, что у нас. |

## Нативные переходы Source (`changelevel2`, `trigger_changelevel` + `info_landmark`)

- По Valve настоящая бесшовность достигается **общей геометрией**: кусок следующей карты
  встроен в текущую, лендмарки с одинаковыми именами, `trigger_transition` переносит энтити.
  Для случайных карт мастерской это невозможно — общих зон и лендмарков нет.
- В GMod `changelevel2` работает только в одиночной игре, `game.MapLoadType()` тогда вернёт
  `"transition"` ([вики](https://wiki.facepunch.com/gmod/game.MapLoadType)).
- Экран загрузки GMod при переходах всё равно показывается — см.
  [garrysmod-issues#4817](https://github.com/Facepunch/garrysmod-issues/issues/4817)
  («loading screen would get stuck on 'Initializing world'» при `trigger_changelevel`).
  Значит, `changelevel2` не решает проблему стандартного экрана у хоста.
- Известные проблемы нативных переходов: SWEP-базы (ArcCW, MW Base) ломаются после перехода,
  NPC/рэгдоллы дублируются ([#6645](https://github.com/Facepunch/garrysmod-issues/issues/6645),
  [#5906](https://github.com/Facepunch/garrysmod-issues/issues/5906)). Наш перенос через JSON +
  `Give()` этих проблем не имеет.

## Вывод

Готового проекта, который скрывает экран загрузки у хоста, нет: это ограничение меню GMod,
а не аддонов. Для случайных карт наш подход совпадает с тем, что используют зрелые проекты
(HL2C), и дополнительно маскирует переход визуально.

## Что можно позаимствовать

- Переносить фраги/смерти (`ply:Frags()`, `ply:Deaths()`), как в HL2C.
- Быстрая проверка в одиночной игре: `changelevel2 gm_flatgrass` — убедиться, что экран загрузки
  тот же. Если окажется иначе (например, HL2-шная плашка LOADING поверх замороженного кадра),
  это меняет картину для хоста.
