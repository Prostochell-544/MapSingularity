--[[
	MapSingularity — поиск, фильтрация, скачивание и монтирование карт мастерской.

	Источники кандидатов (без Web API ключа):
	  * steamworks.GetList(..., {"map"}, ...)       — общий каталог мастерской GMod;
	  * ISteamRemoteStorage/GetCollectionDetails    — если задан ms_collection.
	Детали и фильтр: ISteamRemoteStorage/GetPublishedFileDetails (тег map, бан,
	размер, file_url). Рейтинг: steamworks.FileInfo (up/down/score).

	Маршруты скачивания:
	  * listen-сервер / одиночная игра: хост-клиент вызывает steamworks.DownloadUGC
	    (функция только клиентская) и присылает путь; сервер монтирует тот же файл
	    — процесс общий, файловая система тоже;
	  * выделенный сервер: http по file_url (LZMA в формате Bootil) ->
	    util.Decompress -> data/map_singularity/gma/<id>.dat -> game.MountGMA.
]]

local MS = MapSingularity
MS.Workshop = MS.Workshop or {}
local W = MS.Workshop

local API_DETAILS    = "https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/"
local API_COLLECTION = "https://api.steampowered.com/ISteamRemoteStorage/GetCollectionDetails/v1/"

local GMOD_APPID     = 4000
local BATCH          = 50
local HISTORY_SIZE   = 40
local CACHE_KEEP     = 6
local CLIENT_DL_TIMEOUT = 300
local RATING_TIMEOUT = 15

local BLOCKED_DESCRIPTORS = { adult_only = true, nudity = true, suggestive = true }

local LIST_SORTS = {
	{ "popular", 365 }, { "popular", 180 }, { "popular", 90 }, { "trending", 30 }, { "popular", 0 },
}

--------------------------------------------------------------------------------
-- Персистентные списки: история (не повторять) и битые предметы
--------------------------------------------------------------------------------

local HISTORY_FILE   = MS.DATA_DIR .. "/history.json"
local BLACKLIST_FILE = MS.DATA_DIR .. "/blacklist.json"

local function loadLists()
	local h = MS.ReadJSON(HISTORY_FILE)
	local b = MS.ReadJSON(BLACKLIST_FILE)
	W.History = istable(h) and istable(h.ids) and h.ids or {}
	W.Blacklist = {}
	if istable(b) and istable(b.items) then
		for _, rec in ipairs(b.items) do
			if istable(rec) and isstring(rec.id) then W.Blacklist[rec.id] = rec.reason or "" end
		end
	end
end

local function saveLists()
	MS.EnsureDataDir()
	MS.WriteJSON(HISTORY_FILE, { ids = W.History })
	local items = {}
	for id, reason in pairs(W.Blacklist) do items[#items + 1] = { id = id, reason = reason } end
	MS.WriteJSON(BLACKLIST_FILE, { items = items })
end

loadLists()

function W.MarkBroken(id, reason)
	W.Blacklist[id] = tostring(reason or "")
	saveLists()
end

-- Карта успешно смонтирована и разобрана: в историю, и из чёрного списка, если
-- она попала туда раньше (ms_force_fetch проходит мимо чёрного списка).
function W.Remember(id)
	W.Blacklist[id] = nil
	for i = #W.History, 1, -1 do
		if W.History[i] == id then table.remove(W.History, i) end
	end
	table.insert(W.History, id)
	while #W.History > HISTORY_SIZE do table.remove(W.History, 1) end
	saveLists()
end

local function inHistory(id)
	for _, v in ipairs(W.History) do
		if v == id then return true end
	end
	return false
end

--------------------------------------------------------------------------------
-- HTTP
--------------------------------------------------------------------------------

local function postForm(url, params, cb)
	local ok = HTTP({
		url = url,
		method = "POST",
		parameters = params,
		timeout = 30,
		success = function(code, body)
			if code ~= 200 then return cb(nil, "HTTP " .. tostring(code)) end
			local data = util.JSONToTable(body or "")
			if not istable(data) or not istable(data.response) then return cb(nil, "некорректный JSON ответа Steam") end
			cb(data.response)
		end,
		failed = function(reason)
			cb(nil, "HTTP: " .. tostring(reason))
		end,
	})
	if not ok then cb(nil, "HTTP недоступен (слишком ранний вызов?)") end
end

function W.FetchDetails(ids, cb)
	local params = { itemcount = tostring(#ids) }
	for i, id in ipairs(ids) do params["publishedfileids[" .. (i - 1) .. "]"] = id end

	postForm(API_DETAILS, params, function(resp, err)
		if not resp then return cb(nil, err) end
		if not istable(resp.publishedfiledetails) then return cb(nil, "нет publishedfiledetails") end
		cb(resp.publishedfiledetails)
	end)
end

--------------------------------------------------------------------------------
-- Источники кандидатов
--------------------------------------------------------------------------------

local function collectIDs(results)
	local ids, seen = {}, {}
	for _, v in ipairs(results or {}) do
		local id = MS.NormalizeID(v)
		if id and not seen[id] then
			seen[id] = true
			ids[#ids + 1] = id
		end
	end
	return ids
end

function W.ListWorkshop(cb, retried)
	if not (steamworks and steamworks.GetList) then
		return cb(nil, "steamworks.GetList недоступен; задайте ms_collection")
	end

	local sort = LIST_SORTS[math.random(#LIST_SORTS)]
	local depth = MS.CVars.Depth:GetInt()
	local offset = retried and 0 or math.random(0, math.max(0, depth - BATCH))

	steamworks.GetList(sort[1], { "map" }, offset, BATCH, sort[2], "0", function(data)
		if not istable(data) or not istable(data.results) then
			return cb(nil, "steamworks.GetList не ответил; задайте ms_collection")
		end
		local ids = collectIDs(data.results)
		if #ids == 0 and not retried then return W.ListWorkshop(cb, true) end
		MS.Log("каталог: %s/%dд, смещение %d, получено %d id", sort[1], sort[2], offset, #ids)
		cb(ids)
	end)
end

--[[
	«Вся мастерская»: случайная страница по всему каталогу карт (сортировка по дате —
	она равномерно покрывает весь каталог, без перекоса в популярное). Общее число
	карт узнаём первым запросом и кэшируем. Если Steam не отдаёт слишком глубокую
	страницу, повторяем в пределах первых 5000 карт.
]]
local UNIVERSE_SAFE_DEPTH = 5000

function W.ListUniverse(cb)
	if not (steamworks and steamworks.GetList) then
		return cb(nil, "steamworks.GetList недоступен; задайте ms_collection")
	end

	local function page(offset, onData)
		steamworks.GetList("latest", { "map" }, offset, BATCH, 0, "0", function(data)
			if not istable(data) or not istable(data.results) then return onData(nil) end
			onData(data)
		end)
	end

	local function pick(total, shallow)
		local limit = shallow and math.min(total, UNIVERSE_SAFE_DEPTH) or total
		local offset = math.random(0, math.max(0, math.floor(limit) - BATCH))
		page(offset, function(data)
			if not data then return cb(nil, "steamworks.GetList не ответил") end
			local ids = collectIDs(data.results)
			if #ids == 0 and not shallow then return pick(total, true) end
			MS.Log("вся вселенная: %d карт в каталоге, смещение %d, получено %d id", total, offset, #ids)
			cb(ids)
		end)
	end

	if W.UniverseTotal and W.UniverseTotal > 0 then return pick(W.UniverseTotal, false) end

	page(0, function(data)
		if not data then return cb(nil, "steamworks.GetList не ответил") end
		W.UniverseTotal = tonumber(data.totalresults) or 0
		if W.UniverseTotal <= 0 then return cb(nil, "каталог карт пуст") end
		pick(W.UniverseTotal, false)
	end)
end

function W.ListCollection(collectionId, cb)
	local id = MS.NormalizeID(collectionId)
	if not id then return cb(nil, "ms_collection: некорректный ID") end

	postForm(API_COLLECTION, { collectioncount = "1", ["publishedfileids[0]"] = id }, function(resp, err)
		if not resp then return cb(nil, err) end
		local det = istable(resp.collectiondetails) and resp.collectiondetails[1]
		if not istable(det) or not istable(det.children) then return cb(nil, "коллекция пуста или недоступна") end

		local raw = {}
		for _, child in ipairs(det.children) do
			if istable(child) and tonumber(child.filetype) == 0 then raw[#raw + 1] = child.publishedfileid end
		end
		local ids = MS.Shuffle(collectIDs(raw))
		while #ids > BATCH do table.remove(ids) end
		cb(ids)
	end)
end

--------------------------------------------------------------------------------
-- Фильтрация
--------------------------------------------------------------------------------

-- Названия из мастерской бывают с переводами строк и мусорными пробелами.
-- Обрезаем по границе UTF-8 символа, чтобы не порвать кириллицу.
local MAX_TITLE = 96
local function cleanTitle(s, fallback)
	s = string.gsub(tostring(s or ""), "%c", " ")
	s = string.Trim((string.gsub(s, "%s+", " ")))
	if s == "" then return fallback end
	if #s > MAX_TITLE then
		local cut = MAX_TITLE
		while cut > 1 do
			local b = string.byte(s, cut + 1)
			if not b or b < 0x80 or b >= 0xC0 then break end
			cut = cut - 1
		end
		s = string.sub(s, 1, cut)
	end
	return s
end

local function hasTag(tags, wanted)
	if not istable(tags) then return false end
	for _, t in ipairs(tags) do
		if istable(t) and isstring(t.tag) and string.lower(t.tag) == wanted then return true end
	end
	return false
end

function W.FilterDetails(details, forced)
	local maxBytes = MS.CVars.MaxSizeMB:GetFloat() * 1024 * 1024
	local needURL = W.GetClientRoute() == nil
	local list, rejected = {}, {}

	local function reject(why) rejected[why] = (rejected[why] or 0) + 1 end

	for _, d in ipairs(details) do
		local id = istable(d) and MS.NormalizeID(d.publishedfileid)
		local size = istable(d) and tonumber(d.file_size) or 0
		local url = istable(d) and isstring(d.file_url) and d.file_url or ""

		if not id or tonumber(d.result) ~= 1 then reject("нет данных")
		elseif tonumber(d.consumer_app_id) ~= GMOD_APPID then reject("не GMod")
		elseif tonumber(d.banned) ~= 0 then reject("забанен")
		elseif not hasTag(d.tags, "map") then reject("нет тега map")
		elseif size <= 0 or size > maxBytes then reject("размер")
		elseif needURL and url == "" then reject("нет file_url (выделенный сервер)")
		elseif not forced and W.Blacklist[id] then reject("в чёрном списке")
		elseif not forced and inHistory(id) then reject("уже был")
		else
			list[#list + 1] = {
				id = id,
				title = cleanTitle(d.title, id),
				size = size,
				url = url,
				updated = tonumber(d.time_updated) or 0,
				favorited = tonumber(d.lifetime_favorited) or 0,
			}
		end
	end

	local parts = {}
	for why, n in pairs(rejected) do parts[#parts + 1] = why .. ": " .. n end
	return list, table.concat(parts, ", ")
end

-- cb(list | nil, err)
function W.FindCandidates(forcedId, cb)
	local function withIDs(ids, err)
		if not ids or #ids == 0 then return cb(nil, err or "источник вернул пустой список") end

		W.FetchDetails(ids, function(details, derr)
			if not details then return cb(nil, derr) end
			local list, summary = W.FilterDetails(details, forcedId ~= nil)
			if not forcedId then MS.Shuffle(list) end
			if #list == 0 then return cb(nil, "все кандидаты отсеяны (" .. summary .. ")") end
			MS.Log("кандидатов после фильтра: %d из %d%s", #list, #details, summary ~= "" and (" — " .. summary) or "")
			cb(list)
		end)
	end

	if forcedId then return withIDs({ forcedId }) end

	local coll = string.Trim(MS.CVars.Collection:GetString())
	if coll ~= "" then
		W.ListCollection(coll, withIDs)
	elseif MS.IsUniverseMode() then
		W.ListUniverse(withIDs)
	else
		W.ListWorkshop(withIDs)
	end
end

-- Отсев карт с нулевым/плохим рейтингом. cb(ok, reason)
function W.CheckRating(cand, forced, cb)
	if forced then return cb(true) end

	-- «Вся мастерская» берёт любую карту: рейтинг не важен, проверяем только бан и 18+.
	local universe = MS.IsUniverseMode()
	local minVotes = universe and 0 or MS.CVars.MinVotes:GetInt()
	local minScore = universe and 0 or MS.CVars.MinScore:GetFloat()

	-- Запасной критерий, если Steam не отдал голоса: «живые» избранные.
	local function proxy()
		if universe or cand.favorited >= math.max(minVotes, 1) then return cb(true) end
		cb(false, "нет данных о рейтинге и мало добавлений в избранное")
	end

	if not (steamworks and steamworks.FileInfo) then return proxy() end

	local settled = false
	local tid = "MS_Rating_" .. cand.id
	timer.Create(tid, RATING_TIMEOUT, 1, function()
		if settled then return end
		settled = true
		proxy()
	end)

	steamworks.FileInfo(cand.id, function(info)
		if settled then return end
		settled = true
		timer.Remove(tid)

		if not istable(info) or info.error then return proxy() end
		if info.banned then return cb(false, "забанен") end

		if not MS.CVars.AllowMature:GetBool() and istable(info.content_descriptors) then
			for _, desc in ipairs(info.content_descriptors) do
				if BLOCKED_DESCRIPTORS[desc] then return cb(false, "контент для взрослых: " .. desc) end
			end
		end

		local total = tonumber(info.total) or 0
		local score = tonumber(info.score) or 0
		if total < minVotes then
			return cb(false, string.format("мало голосов: %d < %d", total, minVotes))
		end
		if score < minScore then
			return cb(false, string.format("рейтинг %.2f < %.2f", score, minScore))
		end

		cand.score, cand.votes = score, total
		cb(true)
	end)
end

--------------------------------------------------------------------------------
-- Скачивание
--------------------------------------------------------------------------------

-- Клиент, который может скачать GMA в общий с сервером процесс.
function W.GetClientRoute()
	if game.IsDedicated() then return nil end
	for _, ply in ipairs(player.GetHumans()) do
		if (game.SinglePlayer() or ply:IsListenServerHost()) and MS.IsClientReady(ply) then
			return ply
		end
	end
	return nil
end

function W.CancelPending()
	if W.PendingClientDL then
		W.PendingClientDL = nil
		timer.Remove("MS_ClientDL")
	end
end

local function downloadViaClient(host, cand, cb)
	W.CancelPending()
	W.PendingClientDL = { id = cand.id, ply = host, cb = cb }

	net.Start(MS.Net.DownloadReq)
	net.WriteString(cand.id)
	net.Send(host)

	timer.Create("MS_ClientDL", CLIENT_DL_TIMEOUT, 1, function()
		local pend = W.PendingClientDL
		if not pend then return end
		W.PendingClientDL = nil
		pend.cb(nil, "клиент не ответил за " .. CLIENT_DL_TIMEOUT .. " с")
	end)
end

net.Receive(MS.Net.DownloadResult, function(_, ply)
	local pend = W.PendingClientDL
	if not pend or ply ~= pend.ply then return end

	local id = net.ReadString()
	local ok = net.ReadBool()
	local path = net.ReadString()
	if id ~= pend.id then return end

	W.PendingClientDL = nil
	timer.Remove("MS_ClientDL")

	if not ok or path == "" or string.find(path, "..", 1, true) then
		return pend.cb(nil, "steamworks.DownloadUGC не смог скачать предмет")
	end
	pend.cb(path)
end)

local function cacheRel(id)
	return MS.DATA_DIR .. "/gma/" .. id .. ".dat"
end

local function cachedGMA(cand)
	local rel = cacheRel(cand.id)
	if not file.Exists(rel, "DATA") then return nil end
	if file.Time(rel, "DATA") < cand.updated then return nil end
	local f = file.Open(rel, "rb", "DATA")
	if not f then return nil end
	local magic = f:Read(4)
	f:Close()
	if magic ~= "GMAD" then return nil end
	return "data/" .. rel
end

function W.PruneCache(keepId)
	local files = file.Find(MS.DATA_DIR .. "/gma/*.dat", "DATA")
	if not files or #files <= CACHE_KEEP then return end

	local entries = {}
	for _, name in ipairs(files) do
		local rel = MS.DATA_DIR .. "/gma/" .. name
		entries[#entries + 1] = { rel = rel, time = file.Time(rel, "DATA"), id = string.StripExtension(name) }
	end
	table.sort(entries, function(a, b) return a.time > b.time end)

	for i = CACHE_KEEP + 1, #entries do
		if entries[i].id ~= keepId then file.Delete(entries[i].rel) end
	end
end

-- cb(path | nil, err, broken)
local function downloadViaHTTP(cand, cb)
	local cached = cachedGMA(cand)
	if cached then
		MS.Log("GMA %s взят из кэша", cand.id)
		return cb(cached)
	end

	local maxBytes = MS.CVars.MaxSizeMB:GetFloat() * 1024 * 1024
	local maxUnpacked = maxBytes * 4

	local ok = HTTP({
		url = cand.url,
		method = "GET",
		timeout = 600,
		success = function(code, body)
			if code ~= 200 or not body or #body < 16 then
				return cb(nil, "HTTP " .. tostring(code) .. " при скачивании", false)
			end

			local gma
			if string.sub(body, 1, 4) == "GMAD" then
				gma = body
			else
				local a, b, c, d = string.byte(body, 6, 9)
				local unpacked = a + b * 256 + c * 65536 + d * 16777216
				if unpacked <= 0 or unpacked > maxUnpacked then
					return cb(nil, "распакованный размер вне лимита", true)
				end
				gma = util.Decompress(body, unpacked + 1)
			end
			body = nil

			if not gma or string.sub(gma, 1, 4) ~= "GMAD" then
				return cb(nil, "содержимое не является GMA", true)
			end

			MS.EnsureDataDir("gma")
			local rel = cacheRel(cand.id)
			file.Write(rel, gma)
			if file.Size(rel, "DATA") ~= #gma then
				return cb(nil, "не удалось записать GMA на диск", false)
			end

			W.PruneCache(cand.id)
			cb("data/" .. rel)
		end,
		failed = function(reason)
			cb(nil, "HTTP: " .. tostring(reason), false)
		end,
	})

	if not ok then cb(nil, "HTTP недоступен", false) end
end

function W.Download(cand, cb)
	local host = W.GetClientRoute()

	if host then
		MS.Log("скачивание %s через клиент %s (DownloadUGC)", cand.id, host:Nick())
		return downloadViaClient(host, cand, function(path, err)
			if path then return cb(path) end
			if cand.url ~= "" then
				MS.Warn("%s; пробую прямую загрузку по file_url", err)
				return downloadViaHTTP(cand, cb)
			end
			cb(nil, err, false)
		end)
	end

	if cand.url ~= "" then
		MS.Log("скачивание %s по HTTP (%.1f МБ)", cand.id, cand.size / 1048576)
		return downloadViaHTTP(cand, cb)
	end

	cb(nil, "нет маршрута скачивания (выделенный сервер и предмет без file_url)", false)
end

--------------------------------------------------------------------------------
-- Монтирование и поиск .bsp
--------------------------------------------------------------------------------

--[[
	Возвращает имя карты (без maps/ и .bsp) либо nil, причина, broken.
	broken = true только для дефектов самого предмета (нет .bsp, недопустимое имя):
	«это текущая карта» и сбой монтирования в чёрный список не попадают.
]]
function W.Mount(path)
	local ok, files = game.MountGMA(path)
	if not ok then return nil, "game.MountGMA не смог смонтировать " .. path, false end

	local current = string.lower(game.GetMap())
	local maps = {}
	local sawCurrent, sawUnsafe = false, false

	for _, f in ipairs(files or {}) do
		local name = string.match(f, "^[Mm][Aa][Pp][Ss]/([^/]+)%.[Bb][Ss][Pp]$")
		if name then
			if string.lower(name) == current then
				sawCurrent = true
			elseif MS.IsSafeMapName(name) then
				maps[#maps + 1] = name
			else
				sawUnsafe = true
			end
		end
	end

	if #maps == 0 then
		if sawCurrent then return nil, "это текущая карта сервера (" .. current .. ")", false end
		if sawUnsafe then return nil, "имя .bsp недопустимо для changelevel", true end
		return nil, "в архиве нет .bsp", true
	end

	MS.Shuffle(maps)
	for _, name in ipairs(maps) do
		if file.Exists("maps/" .. name .. ".bsp", "GAME") then return name end
	end

	return nil, ".bsp смонтирован, но не виден в GAME", false
end
