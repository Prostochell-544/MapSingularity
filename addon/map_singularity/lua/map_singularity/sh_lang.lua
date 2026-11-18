--[[
	MapSingularity — переводы (en / uk / ru) и уведомления игрокам.

	MS.T(key, ...)  — фраза на языке клиента (ms_cl_language: auto = язык GMod), с форматом.
	MS.Notice(target, kind, key, ...) (сервер) — сообщение игроку (nil = всем):
	  NOTICE_CHAT   — важное, в чат;          показывается, если включено ms_cl_notices;
	  NOTICE_POPUP  — важное, всплывашкой;    тоже по ms_cl_notices;
	  NOTICE_DEBUG  — отладка, сырой текст;   только при ms_cl_debug.
	Сервер шлёт ключ и аргументы, переводит клиент — у каждого свой язык.
	Консольные логи (MS.Log) — служебные, остаются на русском.
]]

local MS = MapSingularity

MS.NOTICE_CHAT, MS.NOTICE_POPUP, MS.NOTICE_DEBUG = 0, 1, 2

local L = {}
MS.Phrases = L

L.en = {
	portal_name = "Roulette Portal",
	portal_purpose = "A portal to a random Workshop map.",
	portal_instructions = "Step into a stable portal.",
	gun_name = "STC \"Harrier\"",
	gun_purpose = "Spatial Transition Complex: opens a portal to a random Workshop map.",
	gun_instructions = "LMB — portal where you aim. RMB — another map. R — collapse the portal.",
	gun_hint = "LMB portal · RMB another map · R collapse",
	gun_given = "You got the STC \"Harrier\": LMB — portal, RMB — another map, R — collapse.",
	gun_admin_only = "Only admins can use the STC \"Harrier\"",

	portal_stable = "The singularity is stable: %s",
	map_ready = "Map ready: %s — open a portal with the STC \"Harrier\" (spawn menu → MapSingularity)",
	portal_unstable = "The singularity is unstable — the map is still being prepared",
	roulette_spinning = "The roulette is spinning...",
	busy_transit = "A jump is already in progress",
	busy_prepare = "A map is already being prepared — wait",
	prepare_failed = "Could not prepare the map — try again",
	jump_failed = "The jump is impossible right now",
	jump_aborted = "The jump was aborted",
	aim_miss = "Missed — aim at a surface",
	aim_sky = "Can't open a portal in the sky",
	aim_far = "Too far",
	aim_space = "Not enough room for a portal here",

	hud_discover = "Singularity: finding coordinates",
	hud_download = "Singularity: downloading",
	hud_mount = "Singularity: mounting",
	hud_precache = "Singularity: warming up the server",
	hud_sync = "Singularity: syncing",
	hud_ready = "The portal is stable",

	term_header = " STC HARRIER // NDI-TERM 2.4 ",
	term_state = "> STATE: ",
	term_target = "> TARGET: ",
	term_idle = "> AWAITING COMMAND",
	st_idle = "STANDBY", st_discover = "SEARCHING", st_download = "DOWNLOADING", st_mount = "MOUNTING",
	st_precache = "WARMING UP", st_sync = "SYNCING", st_ready = "READY", st_transit = "BREACH!",
	boot1 = "NDI-TERM 2.4  (C) 1987", boot2 = "MEMORY 64K ......... OK", boot3 = "GENERATOR .......... OK",
	boot4 = "GRAPPLERS .......... OK", boot5 = "SPACE CALIBRATION .. OK",

	set_title = "Settings",
	set_help = "Workshop map roulette. Hosts and superadmins can change server settings.",
	set_language = "Language",
	set_lang_auto = "Automatic (game language)",
	set_where = "Where to look for maps",
	mode_top = "Best maps — popular and well rated",
	mode_universe = "Whole Workshop — any map",
	set_where_help = "With «Whole Workshop» the rating filter is off: anything goes.",
	set_rating = "Rating filter (Best maps)",
	set_min_score = "Min. share of likes",
	set_min_votes = "Min. number of votes",
	set_search = "Search and portal",
	set_max_size = "Max. map size, MB",
	set_auto = "Search for a map right after a level loads",
	set_auto_delay = "Auto search delay, s",
	set_pull = "The portal pulls players in",
	set_autoplace = "Place the portal without the STC (next to the player)",
	set_mature = "Allow maps marked 18+",
	set_portal_style = "Portal look (only for you)",
	style_standard = "Classic — violet rings",
	style_fun = "Fun — rainbow tunnel",
	style_minimal = "Minimal — black hole",
	set_client = "Messages",
	set_notices = "Important messages in chat",
	set_debug = "Debug: status line and technical messages",
	set_actions = "Actions",
	act_give = "Give the STC \"Harrier\"",
	act_spin = "Spin the roulette now",
	act_abort = "Stop and remove the portal",
	act_status = "Status to console",
	tune_title = "Gun position",
	tune_help = "First person — from the eye to the top of the grip (forward / right / up), positive pitch raises the barrel. In other players' hands — from the hand along the aim.",
	tune_vm = "First person",
	tune_wm = "In other players' hands",
	tune_x = "Forward", tune_y = "Right", tune_z = "Up", tune_p = "Pitch", tune_yw = "Yaw", tune_r = "Roll", tune_s = "Scale",
	tune_reset = "Reset to defaults",
	tune_where = "Where is the model? (console)",
	tune_dump = "Print values to console",
}

L.uk = {
	portal_name = "Портал рулетки",
	portal_purpose = "Портал на випадкову карту майстерні.",
	portal_instructions = "Увійдіть у стабільний портал.",
	gun_name = "КПП «Лунь»",
	gun_purpose = "Комплекс Просторового Переходу: відкриває портал на випадкову карту майстерні.",
	gun_instructions = "ЛКМ — портал туди, куди дивишся. ПКМ — інша карта. R — згорнути портал.",
	gun_hint = "ЛКМ портал · ПКМ інша карта · R згорнути",
	gun_given = "Видано КПП «Лунь»: ЛКМ — портал, ПКМ — інша карта, R — згорнути.",
	gun_admin_only = "КПП «Лунь» доступний лише адмінам",

	portal_stable = "Сингулярність стабілізовано: %s",
	map_ready = "Карта готова: %s — відкрийте портал з КПП «Лунь» (меню спавну → MapSingularity)",
	portal_unstable = "Сингулярність нестабільна — карта ще готується",
	roulette_spinning = "Рулетка крутиться...",
	busy_transit = "Перехід уже триває",
	busy_prepare = "Карта вже готується — зачекайте",
	prepare_failed = "Не вдалося підготувати карту — спробуйте ще раз",
	jump_failed = "Перехід зараз неможливий",
	jump_aborted = "Перехід зірвано",
	aim_miss = "Мимо — цільтеся в поверхню",
	aim_sky = "У небо портал не поставити",
	aim_far = "Надто далеко",
	aim_space = "Тут замало місця для порталу",

	hud_discover = "Сингулярність: пошук координат",
	hud_download = "Сингулярність: завантаження",
	hud_mount = "Сингулярність: монтування",
	hud_precache = "Сингулярність: прогрів сервера",
	hud_sync = "Сингулярність: синхронізація",
	hud_ready = "Портал стабільний",

	term_header = " КПП ЛУНЬ // НДІ-ТЕРМ 2.4 ",
	term_state = "> СТАН: ",
	term_target = "> ЦІЛЬ: ",
	term_idle = "> ОЧІКУЮ КОМАНДУ",
	st_idle = "ОЧІКУВАННЯ", st_discover = "ПОШУК КООРДИНАТ", st_download = "ЗАВАНТАЖЕННЯ", st_mount = "МОНТУВАННЯ",
	st_precache = "ПРОГРІВ", st_sync = "СИНХРОНІЗАЦІЯ", st_ready = "ГОТОВНІСТЬ", st_transit = "ПРОРИВ!",
	boot1 = "НДІ-ТЕРМ 2.4  (C) 1987", boot2 = "ПАМ'ЯТЬ 64К ......... OK", boot3 = "ГЕНЕРАТОР ........... OK",
	boot4 = "ЗАХОПЛЮВАЧІ ......... OK", boot5 = "КАЛІБРУВАННЯ ПРОСТОРУ OK",

	set_title = "Налаштування",
	set_help = "Рулетка карт майстерні. Серверні налаштування змінюють хост і суперадміни.",
	set_language = "Мова",
	set_lang_auto = "Автоматично (мова гри)",
	set_where = "Де шукати карти",
	mode_top = "Найкращі карти — популярні, з добрим рейтингом",
	mode_universe = "Уся майстерня — будь-яка карта",
	set_where_help = "У режимі «Уся майстерня» фільтр рейтингу не діє: трапиться що завгодно.",
	set_rating = "Фільтр рейтингу (Найкращі карти)",
	set_min_score = "Мін. частка лайків",
	set_min_votes = "Мін. кількість голосів",
	set_search = "Пошук і портал",
	set_max_size = "Макс. розмір карти, МБ",
	set_auto = "Шукати карту одразу після завантаження рівня",
	set_auto_delay = "Затримка автопошуку, с",
	set_pull = "Портал притягує гравців",
	set_autoplace = "Ставити портал без КПП (поруч із гравцем)",
	set_mature = "Дозволити карти з позначкою 18+",
	set_portal_style = "Вигляд порталу (лише для вас)",
	style_standard = "Класичний — фіолетові обручі",
	style_fun = "Веселий — райдужний тунель",
	style_minimal = "Мінімалістичний — чорна діра",
	set_client = "Повідомлення",
	set_notices = "Важливі повідомлення в чат",
	set_debug = "Налагодження: рядок стану та технічні повідомлення",
	set_actions = "Дії",
	act_give = "Видати КПП «Лунь»",
	act_spin = "Крутити рулетку зараз",
	act_abort = "Зупинити й прибрати портал",
	act_status = "Стан у консоль",
	tune_title = "Положення пушки",
	tune_help = "Від першої особи — від ока до верху руків'я (вперед / вправо / вгору), тангаж «плюс» піднімає ствол. У руках інших — від кисті за прицілом.",
	tune_vm = "Від першої особи",
	tune_wm = "У руках інших гравців",
	tune_x = "Вперед", tune_y = "Вправо", tune_z = "Вгору", tune_p = "Тангаж", tune_yw = "Рискання", tune_r = "Крен", tune_s = "Масштаб",
	tune_reset = "Скинути до типових значень",
	tune_where = "Де модель? (у консоль)",
	tune_dump = "Вивести значення в консоль",
}

L.ru = {
	portal_name = "Портал рулетки",
	portal_purpose = "Портал на случайную карту мастерской.",
	portal_instructions = "Войдите в стабильный портал.",
	gun_name = "КПП «Лунь»",
	gun_purpose = "Комплекс Пространственного Перехода: открывает портал на случайную карту мастерской.",
	gun_instructions = "ЛКМ — портал туда, куда смотришь. ПКМ — другая карта. R — схлопнуть портал.",
	gun_hint = "ЛКМ портал · ПКМ другая карта · R схлопнуть",
	gun_given = "Выдан КПП «Лунь»: ЛКМ — портал, ПКМ — другая карта, R — схлопнуть.",
	gun_admin_only = "КПП «Лунь» доступен только админам",

	portal_stable = "Сингулярность стабилизирована: %s",
	map_ready = "Карта готова: %s — откройте портал из КПП «Лунь» (меню спавна → MapSingularity)",
	portal_unstable = "Сингулярность нестабильна — карта ещё готовится",
	roulette_spinning = "Рулетка крутится...",
	busy_transit = "Переход уже идёт",
	busy_prepare = "Карта уже готовится — подождите",
	prepare_failed = "Не удалось подготовить карту — попробуйте ещё раз",
	jump_failed = "Переход сейчас невозможен",
	jump_aborted = "Переход сорван",
	aim_miss = "Мимо — целься в поверхность",
	aim_sky = "В небо портал не поставить",
	aim_far = "Слишком далеко",
	aim_space = "Здесь не хватает места для портала",

	hud_discover = "Сингулярность: поиск координат",
	hud_download = "Сингулярность: загрузка",
	hud_mount = "Сингулярность: монтирование",
	hud_precache = "Сингулярность: прогрев сервера",
	hud_sync = "Сингулярность: синхронизация",
	hud_ready = "Портал стабилен",

	term_header = " КПП ЛУНЬ // НИИ-ТЕРМ 2.4 ",
	term_state = "> СОСТ: ",
	term_target = "> ЦЕЛЬ: ",
	term_idle = "> ЖДУ КОМАНДУ",
	st_idle = "ОЖИДАНИЕ", st_discover = "ПОИСК КООРДИНАТ", st_download = "ЗАГРУЗКА", st_mount = "МОНТИРОВАНИЕ",
	st_precache = "ПРОГРЕВ", st_sync = "СИНХРОНИЗАЦИЯ", st_ready = "ГОТОВНОСТЬ", st_transit = "ПРОРЫВ!",
	boot1 = "НИИ-ТЕРМ 2.4  (C) 1987", boot2 = "ПАМЯТЬ 64К ......... OK", boot3 = "ГЕНЕРАТОР .......... OK",
	boot4 = "ЗАХВАТЫ ............ OK", boot5 = "КАЛИБРОВКА ПРОСТР. . OK",

	set_title = "Настройки",
	set_help = "Рулетка карт мастерской. Серверные настройки меняют хост и суперадмины.",
	set_language = "Язык",
	set_lang_auto = "Автоматически (язык игры)",
	set_where = "Где искать карты",
	mode_top = "Лучшие карты — популярные, с хорошим рейтингом",
	mode_universe = "Вся мастерская — любая карта",
	set_where_help = "В режиме «Вся мастерская» фильтр рейтинга не действует: попадётся что угодно.",
	set_rating = "Фильтр рейтинга (Лучшие карты)",
	set_min_score = "Мин. доля лайков",
	set_min_votes = "Мин. число голосов",
	set_search = "Поиск и портал",
	set_max_size = "Макс. размер карты, МБ",
	set_auto = "Искать карту сразу после загрузки уровня",
	set_auto_delay = "Задержка автопоиска, с",
	set_pull = "Портал притягивает игроков",
	set_autoplace = "Ставить портал без КПП (рядом с игроком)",
	set_mature = "Разрешить карты с пометкой 18+",
	set_portal_style = "Вид портала (только для вас)",
	style_standard = "Классический — фиолетовые обручи",
	style_fun = "Весёлый — радужный тоннель",
	style_minimal = "Минималистичный — чёрная дыра",
	set_client = "Сообщения",
	set_notices = "Важные сообщения в чат",
	set_debug = "Отладка: строка статуса и технические сообщения",
	set_actions = "Действия",
	act_give = "Выдать КПП «Лунь»",
	act_spin = "Крутить рулетку сейчас",
	act_abort = "Остановить и убрать портал",
	act_status = "Статус в консоль",
	tune_title = "Положение пушки",
	tune_help = "От первого лица — от глаза до верха рукояти (вперёд / вправо / вверх), тангаж «плюс» поднимает ствол. В руках у других — от кисти по прицелу.",
	tune_vm = "От первого лица",
	tune_wm = "В руках у других игроков",
	tune_x = "Вперёд", tune_y = "Вправо", tune_z = "Вверх", tune_p = "Тангаж", tune_yw = "Рыскание", tune_r = "Крен", tune_s = "Масштаб",
	tune_reset = "Сбросить к значениям по умолчанию",
	tune_where = "Где модель? (в консоль)",
	tune_dump = "Вывести значения в консоль",
}

MS.Languages = { { "en", "English" }, { "uk", "Українська" }, { "ru", "Русский" } }

if CLIENT then
	MS.CVars = MS.CVars or {}
	MS.CVars.Language = CreateClientConVar("ms_cl_language", "auto", true, false, "Язык аддона: auto (язык игры), en, uk, ru.")
	MS.CVars.Notices  = CreateClientConVar("ms_cl_notices", "1", true, false, "Важные сообщения аддона в чат и всплывашками.", 0, 1)
	MS.CVars.Debug    = CreateClientConVar("ms_cl_debug", "0", true, false, "Отладка: строка статуса подготовки и технические сообщения в чат.", 0, 1)
	MS.CVars.PortalStyle = CreateClientConVar("ms_cl_portal_style", "standard", true, false, "Вид портала: standard, fun, minimal.")
end

function MS.Lang()
	if SERVER then return "ru" end
	local lang = MS.CVars.Language:GetString()
	if L[lang] then return lang end
	local game = GetConVar("gmod_language")
	local code = game and string.lower(game:GetString()) or "en"
	if string.sub(code, 1, 2) == "ru" then return "ru" end
	if string.sub(code, 1, 2) == "uk" then return "uk" end
	return "en"
end

function MS.T(key, ...)
	local phrase = (L[MS.Lang()] or L.en)[key] or L.en[key] or key
	if select("#", ...) > 0 then return string.format(phrase, ...) end
	return phrase
end

if SERVER then
	-- target: игрок, список игроков или nil (все). Аргументы уходят строками.
	function MS.Notice(target, kind, key, ...)
		local args = { ... }
		net.Start(MS.Net.Notice)
		net.WriteUInt(kind, 2)
		net.WriteString(key)
		net.WriteUInt(#args, 4)
		for i = 1, #args do net.WriteString(tostring(args[i])) end
		if target == nil then net.Broadcast() else net.Send(target) end
	end
else
	local COL_TAG, COL_DEBUG = Color(255, 170, 60), Color(150, 150, 150)

	net.Receive(MS.Net.Notice, function()
		local kind = net.ReadUInt(2)
		local key = net.ReadString()
		local args = {}
		for i = 1, net.ReadUInt(4) do args[i] = net.ReadString() end

		if kind == MS.NOTICE_DEBUG then
			if MS.CVars.Debug:GetBool() then chat.AddText(COL_DEBUG, "[MapSingularity] " .. key) end
			return
		end
		if not MS.CVars.Notices:GetBool() then return end
		local text = MS.T(key, unpack(args))
		if kind == MS.NOTICE_POPUP then
			notification.AddLegacy(text, NOTIFY_HINT, 4)
		else
			chat.AddText(COL_TAG, "[MapSingularity] ", color_white, text)
		end
	end)
end
