--[[
	MapSingularity — общая конфигурация, константы, сетевые строки и утилиты.
]]

MapSingularity = MapSingularity or {}
local MS = MapSingularity

MS.VERSION = "1.0.0"

-- URL экрана загрузки на время прыжка. Меню GMod принимает только адреса,
-- начинающиеся с "http" или "asset://" (lua/menu/loading.lua, GameDetails).
-- asset://garrysmod/ читает через файловую систему движка, поэтому PNG из
-- аддона виден как обычный ассет. Переопределяется конваром ms_loading_url.
MS_LOADING_URL = "asset://garrysmod/materials/map_singularity/portal_void.png"

MS.FADE_OUT_TIME = 1.5   -- растяжение FOV + блюр + затемнение до чёрного
MS.FADE_IN_TIME  = 2.0   -- растворение чёрного экрана на новой карте
MS.TRANSIT_MARGIN = 0.35 -- запас на пинг, прежде чем сервер выполнит changelevel

MS.STATE_FILE    = "map_singularity_state.json"         -- data/, сервер
MS.DATA_DIR      = "map_singularity"
MS.CLIENT_MARKER = "map_singularity/client_transit.json" -- data/, клиент
MS.STATE_TTL     = 600 -- секунд; более старый state считается протухшим

MS.PORTAL_DSP = 14 -- "Water S": глушит высокие частоты, как под водой
MS.PORTAL_RADIUS = 46  -- полуширина триггера портала (юниты)
MS.PORTAL_HEIGHT = 110 -- высота триггера портала
MS.SUPPORTED_BSP = { [19] = true, [20] = true } -- форматы, которые грузит движок GMod

MS.MAX_NET_BLOB = 60000 -- байт сжатых данных в одном net-сообщении

MS.Phase = {
	IDLE     = 0,
	DISCOVER = 1,
	DOWNLOAD = 2,
	MOUNT    = 3,
	PRECACHE = 4,
	SYNC     = 5,
	READY    = 6,
	TRANSIT  = 7,
}

MS.PhaseName = {
	[0] = "IDLE", "DISCOVER", "DOWNLOAD", "MOUNT", "PRECACHE", "SYNC", "READY", "TRANSIT",
}

MS.Net = {
	Phase          = "ms_phase",          -- S->C: фаза подготовки для HUD
	Prefetch       = "ms_prefetch",       -- S->C: id, карта, список ассетов
	PrefetchDone   = "ms_prefetch_done",  -- C->S: клиент скачал и прогрел ассеты
	DownloadReq    = "ms_dl_request",     -- S->C: хост listen-сервера качает GMA
	DownloadResult = "ms_dl_result",      -- C->S: путь к скачанному GMA
	Transit        = "ms_transit",        -- S->C: начало / отмена прыжка
	ClientReady    = "ms_client_ready",   -- C->S: клиент прогрузился (InitPostEntity)
	Arrival        = "ms_arrival",        -- S->C: состояние восстановлено, растворяем чёрный
	Setting        = "ms_setting",        -- C->S: админ меняет настройку из панели «Утилиты»
	Notice         = "ms_notice",         -- S->C: сообщение игроку (ключ фразы + аргументы, sh_lang)
}

MS.TRANSIT_BEGIN = 1
MS.TRANSIT_ABORT = 2

-- Режимы поиска карт.
MS.SEARCH_TOP = "top"           -- «Лучшие карты»: популярные и хорошо оценённые
MS.SEARCH_UNIVERSE = "universe" -- «Вся мастерская»: случайная карта из всего каталога

if SERVER then
	for _, name in pairs(MS.Net) do
		util.AddNetworkString(name)
	end
end

--[[
	Настройки, которые видит и меняет панель в «Утилитах»: реплицируются клиентам,
	чтобы панель показывала текущие значения. Меняются только на сервере (net-сообщение
	ms_setting с проверкой прав) — список разрешённых имён в MS.Settings.
]]
local SHARED_FLAGS = { FCVAR_ARCHIVE, FCVAR_REPLICATED }
MS.CVars = {
	SearchMode  = CreateConVar("ms_search_mode", MS.SEARCH_TOP, SHARED_FLAGS, "Где искать карты: top (лучшие карты) или universe (вся мастерская)."),
	AutoFetch   = CreateConVar("ms_auto_fetch", "1", SHARED_FLAGS, "Автоматически готовить портал после загрузки карты.", 0, 1),
	AutoDelay   = CreateConVar("ms_auto_fetch_delay", "45", SHARED_FLAGS, "Задержка (сек) перед автоматическим поиском карты.", 5, 3600),
	MinScore    = CreateConVar("ms_min_score", "0.6", SHARED_FLAGS, "Лучшие карты: минимальная доля положительных оценок (0..1).", 0, 1),
	MinVotes    = CreateConVar("ms_min_votes", "10", SHARED_FLAGS, "Лучшие карты: минимальное число голосов у карты.", 0, 100000),
	MaxSizeMB   = CreateConVar("ms_max_size_mb", "200", SHARED_FLAGS, "Максимальный размер скачиваемого архива карты (МБ, сжатый).", 1, 4096),
	AllowMature = CreateConVar("ms_allow_mature", "0", SHARED_FLAGS, "Разрешить карты с пометками adult/nudity/suggestive.", 0, 1),
	Pull        = CreateConVar("ms_portal_pull", "1", SHARED_FLAGS, "Стабильный портал притягивает игроков.", 0, 1),
	Autoplace   = CreateConVar("ms_portal_autoplace", "0", SHARED_FLAGS, "Ставить готовый портал самому (1) или ждать выстрела КПП «Лунь» (0).", 0, 1),
}

-- Имя конвара -> проверка значения (строка -> нормализованная строка или nil).
local function numberIn(lo, hi, integer)
	return function(v)
		local n = tonumber(v)
		if not n then return nil end
		n = math.Clamp(n, lo, hi)
		if integer then n = math.floor(n + 0.5) end
		return tostring(n)
	end
end
MS.Settings = {
	ms_search_mode = function(v)
		if v == MS.SEARCH_TOP or v == MS.SEARCH_UNIVERSE then return v end
	end,
	ms_auto_fetch = numberIn(0, 1, true),
	ms_auto_fetch_delay = numberIn(5, 3600, true),
	ms_min_score = numberIn(0, 1, false),
	ms_min_votes = numberIn(0, 100000, true),
	ms_max_size_mb = numberIn(1, 4096, true),
	ms_allow_mature = numberIn(0, 1, true),
	ms_portal_pull = numberIn(0, 1, true),
	ms_portal_autoplace = numberIn(0, 1, true),
}

if SERVER then
	local FLAGS = { FCVAR_ARCHIVE }
	MS.CVars.Collection     = CreateConVar("ms_collection", "", FLAGS, "ID коллекции мастерской как пул карт (пусто = режим поиска ms_search_mode).")
	MS.CVars.Depth          = CreateConVar("ms_discovery_depth", "600", FLAGS, "Лучшие карты: глубина выборки популярных карт.", 50, 5000)
	MS.CVars.LoadingURL     = CreateConVar("ms_loading_url", MS_LOADING_URL, FLAGS, "URL экрана загрузки на время прыжка (http(s):// или asset://). Пусто = не трогать sv_loadingurl.")
	MS.CVars.ClientWait     = CreateConVar("ms_client_wait", "60", FLAGS, "Сколько секунд ждать префетча клиентов перед открытием портала.", 0, 600)
	MS.CVars.UrlRestore     = CreateConVar("ms_url_restore_timeout", "120", FLAGS, "Через сколько секунд после прибытия вернуть sv_loadingurl принудительно.", 10, 900)
	MS.CVars.ModelBudget    = CreateConVar("ms_precache_models", "384", FLAGS, "Лимит моделей для прекэша (защита таблицы прекэша, 4096 слотов).", 0, 2048)
	MS.CVars.MaterialBudget = CreateConVar("ms_precache_materials", "1024", FLAGS, "Лимит материалов для прогрева.", 0, 8192)
	MS.CVars.SliceMs        = CreateConVar("ms_precache_slice_ms", "3", FLAGS, "Бюджет времени на прекэш за один тик (мс).", 1, 50)
else
	MS.CVars.Prefetch = CreateClientConVar("ms_cl_prefetch", "1", true, false, "Заранее скачивать и прогревать карту портала.", 0, 1)
	MS.CVars.Hud      = CreateClientConVar("ms_cl_hud", "1", true, false, "Устарело: строку статуса теперь включает отладка (ms_cl_debug).", 0, 1)
	MS.CVars.SliceMs  = CreateClientConVar("ms_cl_precache_slice_ms", "2", true, false, "Бюджет времени клиента на прогрев за кадр (мс).", 1, 20)
end

function MS.IsUniverseMode()
	return MS.CVars.SearchMode:GetString() == MS.SEARCH_UNIVERSE
end

--------------------------------------------------------------------------------
-- Логирование
--------------------------------------------------------------------------------

local COLOR_TAG  = Color(170, 120, 255)
local COLOR_TEXT = Color(230, 230, 230)
local COLOR_WARN = Color(255, 170, 60)

local function format(fmt, ...)
	if select("#", ...) == 0 then return tostring(fmt) end
	return string.format(fmt, ...)
end

function MS.Log(fmt, ...)
	MsgC(COLOR_TAG, "[MapSingularity] ", COLOR_TEXT, format(fmt, ...), "\n")
end

function MS.Warn(fmt, ...)
	MsgC(COLOR_TAG, "[MapSingularity] ", COLOR_WARN, format(fmt, ...), "\n")
end

--------------------------------------------------------------------------------
-- Утилиты
--------------------------------------------------------------------------------

-- Workshop ID -> строка из цифр. Числа форматируем без экспоненты.
function MS.NormalizeID(id)
	local s
	if isnumber(id) then
		s = string.format("%.0f", id)
	else
		s = string.Trim(tostring(id or ""))
	end
	if not string.match(s, "^%d+$") or string.match(s, "^0+$") then return nil end
	return s
end

function MS.Shuffle(list)
	for i = #list, 2, -1 do
		local j = math.random(i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

function MS.SmoothStep(t)
	t = math.Clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Строка безопасна для подстановки в консольную команду в кавычках.
function MS.ConsoleSafe(s)
	return (string.gsub(tostring(s or ""), "[\"\r\n;]", ""))
end

-- Корректное имя карты для changelevel.
function MS.IsSafeMapName(name)
	return isstring(name) and #name > 0 and #name <= 64 and string.match(name, "^[%w_%-%.]+$") ~= nil
end

-- Таблица -> сжатый JSON в net-сообщение. Возвращает false, если не влезло.
function MS.NetWriteTable(tbl)
	local blob = util.Compress(util.TableToJSON(tbl)) or ""
	if #blob > MS.MAX_NET_BLOB then
		net.WriteUInt(0, 32)
		return false
	end
	net.WriteUInt(#blob, 32)
	if #blob > 0 then net.WriteData(blob, #blob) end
	return true
end

function MS.NetReadTable()
	local len = net.ReadUInt(32)
	if len == 0 or len > MS.MAX_NET_BLOB then return nil end
	local json = util.Decompress(net.ReadData(len), MS.MAX_NET_BLOB * 64)
	if not json or json == "" then return nil end
	return util.JSONToTable(json)
end

--[[
	Амортизированная обработка списка: каждый тик обрабатываем элементы, пока
	не исчерпан бюджет времени sliceMs. Никаких фризов на больших списках.
	worker(item) -> любое значение; onProgress(done, total); onDone(done, total).
]]
function MS.Amortize(timerName, items, sliceMsFn, worker, onProgress, onDone)
	timer.Remove(timerName)

	local total = #items
	local index = 0

	if total == 0 then
		if onDone then onDone(0, 0) end
		return
	end

	timer.Create(timerName, 0, 0, function()
		local deadline = SysTime() + math.max(sliceMsFn(), 0.5) / 1000

		repeat
			index = index + 1
			local ok, err = pcall(worker, items[index])
			if not ok then MS.Warn("ошибка обработки %s: %s", tostring(items[index]), tostring(err)) end
		until index >= total or SysTime() >= deadline

		if onProgress then onProgress(index, total) end

		if index >= total then
			timer.Remove(timerName)
			if onDone then onDone(index, total) end
		end
	end)
end

function MS.EnsureDataDir(sub)
	if not file.IsDir(MS.DATA_DIR, "DATA") then file.CreateDir(MS.DATA_DIR) end
	if sub then
		local path = MS.DATA_DIR .. "/" .. sub
		if not file.IsDir(path, "DATA") then file.CreateDir(path) end
	end
end

function MS.ReadJSON(path)
	local raw = file.Read(path, "DATA")
	if not raw or raw == "" then return nil end
	return util.JSONToTable(raw)
end

function MS.WriteJSON(path, tbl)
	local json = util.TableToJSON(tbl, false)
	if not json then return false end
	file.Write(path, json)
	return file.Size(path, "DATA") == #json
end
