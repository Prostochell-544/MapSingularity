--[[
	MapSingularity — перенос состояния игроков и временный хайджек sv_loadingurl.

	Отправление:
	  BeginTransit -> всем клиентам эффект (1.5 с), DSP, бессмертие на время эффекта
	  Commit       -> JSON (map_singularity_state.json): игроки по SteamID64 +
	                  исходный sv_loadingurl; sv_loadingurl := MS_LOADING_URL; changelevel
	  Watchdog     -> если через 20 с мы всё ещё на этой карте — Rollback.

	Прибытие (новая карта):
	  загрузка файла -> читаем и удаляем JSON, resource.AddWorkshop(wsid)
	  PlayerSpawn    -> подавляем стандартный лоадаут и выдаём сохранённое
	  ClientReady    -> клиент прогрузился; когда он ещё и восстановлен — Arrival
	  sv_loadingurl  -> возвращаем, когда все путешественники уже в игре
	                    (или по таймауту ms_url_restore_timeout). Возвращать в
	                    InitPostEntity нельзя: движок отдаёт клиентам serverinfo
	                    (и URL экрана загрузки) только после активации карты,
	                    то есть уже после InitPostEntity.

	Журнал (data/map_singularity/loadingurl_ledger.json) хранит исходный URL,
	пока он подменён. Если сервер сменил карту не через портал до восстановления,
	следующая загрузка Lua вернёт исходное значение.
]]

local MS = MapSingularity
MS.Inventory = MS.Inventory or {}
local I = MS.Inventory

local LEDGER = MS.DATA_DIR .. "/loadingurl_ledger.json"
local WATCHDOG = 20

local function weak() return setmetatable({}, { __mode = "k" }) end

I.Pending   = I.Pending or {}      -- key -> сохранённая запись игрока
I.Restoring = I.Restoring or weak() -- ply -> запись, пока идёт спавн
I.Spawned   = I.Spawned or weak()   -- ply -> первый спавн на карте обработан
I.Ready     = I.Ready or weak()     -- ply -> клиент прислал ClientReady
I.Notified  = I.Notified or weak()  -- ply -> Arrival отправлен
I.HostTunnel = I.HostTunnel or weak() -- ply (хост) -> установлен патч экрана загрузки

--------------------------------------------------------------------------------
-- Метка прыжка в hostname для патча экрана загрузки хоста
--------------------------------------------------------------------------------

--[[
	Хосту меню передаёт в страницу загрузки только hostname (GameDetails). Если у
	хоста стоит патч (web/ms_tunnel.js в garrysmod/html/), на время прыжка дописываем
	в конец hostname невидимый символ U+2063 — по нему патч включает тоннель вместо
	стандартного экрана. Метка видна в значении конвара, поэтому журнал не нужен:
	любая следующая загрузка Lua без прибытия просто её снимает.
]]
local HOST_MARK = "\226\129\163"

local function currentHostname()
	local cv = GetConVar("hostname")
	return cv and cv:GetString() or ""
end

local function setHostname(name)
	game.ConsoleCommand("hostname \"" .. MS.ConsoleSafe(name) .. "\"\n")
end

local function stripMark(name)
	return (string.gsub(name, HOST_MARK, ""))
end

-- Хост, у которого установлен патч экрана загрузки, либо nil.
function I.PatchedHost()
	for _, ply in ipairs(player.GetHumans()) do
		if MS.IsHost(ply) and I.HostTunnel[ply] then return ply end
	end
	return nil
end

function I.MarkHostname()
	if not I.PatchedHost() then return false end
	setHostname(stripMark(currentHostname()) .. HOST_MARK)
	return true
end

-- Диагностика: ставит метку, через полсекунды читает hostname обратно и снимает.
-- cb(держится ли метка, прочитанное значение).
function I.TestHostMark(cb)
	local base = stripMark(currentHostname())
	setHostname(base .. HOST_MARK)
	timer.Simple(0.5, function()
		local readBack = currentHostname()
		setHostname(base)
		cb(string.find(readBack, HOST_MARK, 1, true) ~= nil, readBack)
	end)
end

function I.ClearHostMark(why)
	timer.Remove("MS_HostMarkFallback")
	local name = currentHostname()
	if string.find(name, HOST_MARK, 1, true) then
		setHostname(stripMark(name))
		MS.Log("метка прыжка снята с hostname (%s)", why)
	end
end

--------------------------------------------------------------------------------
-- sv_loadingurl
--------------------------------------------------------------------------------

-- Предупреждаем один раз на каждое новое значение, а не при каждом вызове.
local warnedValue
local function warnOnce(value, fmt, ...)
	if warnedValue == value then return end
	warnedValue = value
	MS.Warn(fmt, ...)
end

function MS.GetLoadingURL()
	local raw = MS.CVars.LoadingURL:GetString()
	local url = string.Trim(MS.ConsoleSafe(raw))
	if url == "" then return "" end

	-- Консоль Source считает «//» началом комментария: введённый без кавычек URL
	-- превращается в «asset:» или «https:». Такое значение заведомо не задумано —
	-- берём адрес по умолчанию.
	if string.match(url, "^%a+:/?$") then
		warnOnce(raw, "ms_loading_url обрезан консолью до \"%s\": URL нужно вводить в кавычках. Использую значение по умолчанию.", url)
		return MS_LOADING_URL
	end

	local lower = string.lower(url)
	if string.sub(lower, 1, 7) ~= "http://" and string.sub(lower, 1, 8) ~= "https://" and string.sub(lower, 1, 8) ~= "asset://" then
		warnOnce(raw, "ms_loading_url \"%s\" должен начинаться с http(s):// или asset:// — подмена отключена", url)
		return ""
	end
	return url
end

local function currentLoadingURL()
	local cv = GetConVar("sv_loadingurl")
	return cv and cv:GetString() or ""
end

local function setLoadingURL(url)
	game.ConsoleCommand("sv_loadingurl \"" .. MS.ConsoleSafe(url) .. "\"\n")
end

--[[
	Кто увидит sv_loadingurl. Меню GMod показывает его только клиентам,
	подключающимся по сети: тому, кто сам хостит игру (одиночная игра или хост
	listen-сервера), всегда открывается стандартная страница. Возвращает число
	сетевых клиентов и название режима.
]]
function MS.LoadingScreenAudience()
	if game.SinglePlayer() then return 0, "одиночная игра" end

	local remote = 0
	for _, ply in ipairs(player.GetHumans()) do
		if not ply:IsListenServerHost() then remote = remote + 1 end
	end

	return remote, game.IsDedicated() and "выделенный сервер" or "listen-сервер"
end

-- Безопасный режим: если показывать экран некому, sv_loadingurl не трогаем вовсе —
-- нечего подменять, нечего возвращать, нечему зависнуть. Возвращает URL и пояснение.
function I.ChooseLoadingURL()
	local remote, mode = MS.LoadingScreenAudience()
	local hostView = I.PatchedHost() and "у хоста тоннель (патч)" or "хост видит стандартный экран"
	if remote == 0 then
		return "", mode .. ": " .. hostView .. ", sv_loadingurl не трогаем"
	end

	local url = MS.GetLoadingURL()
	if url == "" then
		return "", string.format("%s: сетевых клиентов %d, но ms_loading_url пуст или недопустим", mode, remote)
	end
	return url, string.format("%s: экран из ms_loading_url для %d сетевых клиентов, %s", mode, remote, hostView)
end

local function writeLedger(original, hijack)
	MS.EnsureDataDir()
	MS.WriteJSON(LEDGER, { original = original, hijack = hijack, time = os.time() })
end

--------------------------------------------------------------------------------
-- Ключи и снимок состояния
--------------------------------------------------------------------------------

function I.KeyFor(ply)
	if not IsValid(ply) or ply:IsBot() then return nil end
	local sid = ply:SteamID64()
	if isstring(sid) and sid ~= "" and sid ~= "0" then return sid end
	if game.SinglePlayer() then return "singleplayer" end
	return nil
end

function I.Capture(ply, hadGod)
	local rec = {
		hp = ply:Health(),
		maxhp = ply:GetMaxHealth(),
		armor = ply:Armor(),
		suit = ply:IsSuitEquipped(),
		god = hadGod == true,
		weapons = {},
		ammo = {},
	}

	if ply.GetMaxArmor then rec.maxarmor = ply:GetMaxArmor() end

	local active = ply:GetActiveWeapon()
	if IsValid(active) then rec.active = active:GetClass() end

	for _, wep in ipairs(ply:GetWeapons()) do
		if IsValid(wep) then
			rec.weapons[#rec.weapons + 1] = { class = wep:GetClass(), clip1 = wep:Clip1(), clip2 = wep:Clip2() }
		end
	end

	-- Массив, а не словарь: util.JSONToTable превращает ключи вида "357" в числа,
	-- а SetAmmo(число) трактует его как ID типа патронов.
	for id, count in pairs(ply:GetAmmo()) do
		local name = game.GetAmmoName(id)
		if name and count > 0 then rec.ammo[#rec.ammo + 1] = { name = name, count = count } end
	end

	return rec
end

function I.Apply(ply, rec)
	ply:StripWeapons()
	ply:StripAmmo()

	if rec.suit == true then
		ply:EquipSuit()
	elseif rec.suit == false then
		ply:RemoveSuit()
	end

	if istable(rec.ammo) then
		for _, a in ipairs(rec.ammo) do
			local count = tonumber(a.count)
			if isstring(a.name) and count and count > 0 then ply:SetAmmo(math.floor(count), a.name) end
		end
	end

	local given = 0
	if istable(rec.weapons) then
		for _, w in ipairs(rec.weapons) do
			if istable(w) and isstring(w.class) then
				local wep = ply:Give(w.class, true)
				if IsValid(wep) then
					given = given + 1
					local c1, c2 = tonumber(w.clip1), tonumber(w.clip2)
					if c1 and c1 >= 0 then wep:SetClip1(c1) end
					if c2 and c2 >= 0 then wep:SetClip2(c2) end
				end
			end
		end
	end

	local maxhp = tonumber(rec.maxhp)
	if maxhp and maxhp > 0 then ply:SetMaxHealth(maxhp) end
	local hp = tonumber(rec.hp)
	if hp then ply:SetHealth(math.max(1, math.floor(hp))) end

	local maxarmor = tonumber(rec.maxarmor)
	if maxarmor and maxarmor > 0 and ply.SetMaxArmor then ply:SetMaxArmor(maxarmor) end
	local armor = tonumber(rec.armor)
	if armor then ply:SetArmor(math.max(0, math.floor(armor))) end

	if rec.god then ply:GodEnable() end

	if isstring(rec.active) and ply:HasWeapon(rec.active) then ply:SelectWeapon(rec.active) end

	return given
end

--------------------------------------------------------------------------------
-- Отправление
--------------------------------------------------------------------------------

local function sendTransit(kind, map, text, duration)
	net.Start(MS.Net.Transit)
	net.WriteUInt(kind, 2)
	net.WriteString(map or "")
	net.WriteString(text or "")
	net.WriteFloat(duration or 0)
	net.Broadcast()
end

function I.BeginTransit(target, initiator)
	if I.Transit then return false, "переход уже идёт" end
	if not istable(target) or not MS.IsSafeMapName(target.map) then return false, "нет цели" end
	if not file.Exists("maps/" .. target.map .. ".bsp", "GAME") then return false, "файл карты недоступен" end

	local tr = { target = target, god = weak(), committed = false }
	I.Transit = tr

	for _, ply in ipairs(player.GetAll()) do
		tr.god[ply] = ply:HasGodMode()
		ply:GodEnable()
		ply:SetDSP(MS.PORTAL_DSP, false)
	end

	sendTransit(MS.TRANSIT_BEGIN, target.map, target.title, MS.FADE_OUT_TIME)
	timer.Create("MS_TransitCommit", MS.FADE_OUT_TIME + MS.TRANSIT_MARGIN, 1, I.Commit)

	MS.Log("прыжок начат (%s) -> %s [%s]", IsValid(initiator) and initiator:Nick() or "сервер", target.map, target.id)
	return true
end

function I.Commit()
	local tr = I.Transit
	if not tr or tr.committed then return end

	local target = tr.target
	if not file.Exists("maps/" .. target.map .. ".bsp", "GAME") then
		return I.Rollback("файл карты больше не виден в GAME")
	end

	local players, travelers = {}, {}
	for _, ply in ipairs(player.GetHumans()) do
		local key = I.KeyFor(ply)
		if key then
			travelers[#travelers + 1] = key
			if ply:Alive() then
				local rec = I.Capture(ply, tr.god[ply])
				rec.sid = key
				players[#players + 1] = rec
			end
		end
	end

	local hijack, why = I.ChooseLoadingURL()
	local current = currentLoadingURL()
	local original = current

	-- Подмена ещё висит с прошлого прибытия — настоящий оригинал хранит Arrival
	-- или журнал.
	if I.Arrival and not I.Arrival.restored then
		original = I.Arrival.original
		I.Arrival.restored = true
		timer.Remove("MS_UrlRestore")
	else
		local ledger = MS.ReadJSON(LEDGER)
		if istable(ledger) and isstring(ledger.hijack) and ledger.hijack ~= "" and current == ledger.hijack then
			original = isstring(ledger.original) and ledger.original or ""
		end
	end

	MS.Log("экран загрузки: %s", why)
	if I.MarkHostname() then
		MS.Log("метка для патча хоста дописана в hostname (\"%s\" + U+2063)", stripMark(currentHostname()))
	end

	local state = {
		format = 1,
		created = os.time(),
		from = game.GetMap(),
		map = target.map,
		wsid = target.id,
		title = target.title,
		loadingurl_original = original,
		loadingurl_hijack = hijack,
		travelers = travelers,
		players = players,
	}

	if not MS.WriteJSON(MS.STATE_FILE, state) then
		return I.Rollback("не удалось записать " .. MS.STATE_FILE)
	end

	tr.committed = true
	tr.original = original
	tr.hijack = hijack

	if hijack ~= "" then
		writeLedger(original, hijack)
		setLoadingURL(hijack)
	else
		-- Безопасный режим: конвар не трогаем, а недоснятую прошлую подмену снимаем.
		if current ~= original then setLoadingURL(original) end
		file.Delete(LEDGER)
	end

	MS.Log("состояние %d игроков сохранено, changelevel %s", #players, target.map)
	game.ConsoleCommand("changelevel " .. target.map .. "\n")

	timer.Create("MS_TransitWatchdog", WATCHDOG, 1, function()
		I.Rollback("changelevel не произошёл за " .. WATCHDOG .. " с")
	end)
end

function I.Rollback(reason)
	local tr = I.Transit
	if not tr then return end

	timer.Remove("MS_TransitCommit")
	timer.Remove("MS_TransitWatchdog")

	if tr.committed then
		if tr.hijack ~= "" and currentLoadingURL() == tr.hijack then setLoadingURL(tr.original) end
		file.Delete(MS.STATE_FILE)
		file.Delete(LEDGER)
	end

	for ply, had in pairs(tr.god) do
		if IsValid(ply) then
			if not had then ply:GodDisable() end
			ply:SetDSP(0, false)
		end
	end

	I.ClearHostMark("откат прыжка")
	I.Transit = nil
	sendTransit(MS.TRANSIT_ABORT, "", reason, 0.6)
	MS.Warn("прыжок отменён: %s", reason)

	if MS.Director and MS.Director.OnTransitAborted then MS.Director.OnTransitAborted(reason) end
end

--------------------------------------------------------------------------------
-- Прибытие
--------------------------------------------------------------------------------

function I.RestoreLoadingURL(why)
	local arr = I.Arrival
	if not arr or arr.restored then return end

	arr.restored = true
	timer.Remove("MS_UrlRestore")

	if arr.hijack ~= "" and currentLoadingURL() == arr.hijack then
		setLoadingURL(arr.original)
		MS.Log("sv_loadingurl возвращён к \"%s\" (%s)", arr.original, why)
	end
	file.Delete(LEDGER)
end

local function checkAllArrived()
	local arr = I.Arrival
	if not arr or arr.restored then return end
	for key in pairs(arr.expected) do
		if not arr.arrived[key] then return end
	end
	I.RestoreLoadingURL("все путешественники в игре")
end

local function loadArrival()
	if not file.Exists(MS.STATE_FILE, "DATA") then
		-- Не прибытие: метка в hostname могла остаться от прерванного прыжка.
		I.ClearHostMark("загрузка карты без прибытия")

		-- Подмена осталась от прерванной сессии без прибытия — откатываем сразу.
		local ledger = MS.ReadJSON(LEDGER)
		if istable(ledger) and isstring(ledger.hijack) and ledger.hijack ~= "" then
			if currentLoadingURL() == ledger.hijack then setLoadingURL(ledger.original or "") end
			MS.Log("найдена незавершённая подмена sv_loadingurl — восстановлено")
		end
		file.Delete(LEDGER)
		return
	end

	local state = MS.ReadJSON(MS.STATE_FILE)
	file.Delete(MS.STATE_FILE)

	if not istable(state) then
		MS.Warn("%s повреждён — состояние не восстановлено", MS.STATE_FILE)
		return
	end

	local arr = {
		original = tostring(state.loadingurl_original or ""),
		hijack = tostring(state.loadingurl_hijack or ""),
		title = tostring(state.title or ""),
		from = tostring(state.from or ""),
		wsid = MS.NormalizeID(state.wsid),
		expected = {},
		arrived = {},
		restored = false,
	}
	I.Arrival = arr

	-- Прыжок был в безопасном режиме: возвращать нечего, таймеры не нужны.
	if arr.hijack == "" then arr.restored = true end

	if arr.wsid then resource.AddWorkshop(arr.wsid) end

	local created = tonumber(state.created) or 0
	local fresh = os.time() - created <= MS.STATE_TTL
	local sameMap = isstring(state.map) and string.lower(state.map) == string.lower(game.GetMap())

	if not (fresh and sameMap) then
		MS.Warn("состояние %s — инвентарь не восстанавливается", fresh and "для другой карты" or "устарело")
		return
	end

	if istable(state.travelers) then
		for _, key in ipairs(state.travelers) do
			if isstring(key) then arr.expected[key] = true end
		end
	end

	local count = 0
	if istable(state.players) then
		for _, rec in ipairs(state.players) do
			if istable(rec) and isstring(rec.sid) then
				I.Pending[rec.sid] = rec
				count = count + 1
			end
		end
	end

	MS.Log("прибытие из %s: путешественников %d, сохранённых инвентарей %d", arr.from, table.Count(arr.expected), count)
end

if not I.Booted then
	I.Booted = true
	loadArrival()
end

hook.Add("InitPostEntity", "MS_HostMarkFallback", function()
	if string.find(currentHostname(), HOST_MARK, 1, true) then
		timer.Create("MS_HostMarkFallback", MS.CVars.UrlRestore:GetFloat(), 1, function()
			I.ClearHostMark("таймаут ожидания хоста")
		end)
	end
end)

hook.Add("InitPostEntity", "MS_InventoryArrival", function()
	local arr = I.Arrival
	if not arr or arr.restored then return end

	-- server.cfg мог перезаписать sv_loadingurl при загрузке карты: подмена должна
	-- дожить до переподключения клиентов.
	if arr.hijack ~= "" and currentLoadingURL() ~= arr.hijack then setLoadingURL(arr.hijack) end

	if table.IsEmpty(arr.expected) then
		I.RestoreLoadingURL("нет ожидаемых игроков")
		return
	end

	timer.Create("MS_UrlRestore", MS.CVars.UrlRestore:GetFloat(), 1, function()
		I.RestoreLoadingURL("таймаут ожидания игроков")
	end)
end)

local function trySendArrival(ply)
	if not I.Arrival or I.Notified[ply] or not I.Spawned[ply] or not I.Ready[ply] then return end
	I.Notified[ply] = true

	ply:SetDSP(0, false)

	net.Start(MS.Net.Arrival)
	net.WriteFloat(MS.FADE_IN_TIME)
	net.WriteString(I.Arrival.title)
	net.Send(ply)
end

function I.OnClientReady(ply, hostPatch)
	I.Ready[ply] = true

	if MS.IsHost(ply) then
		I.HostTunnel[ply] = hostPatch == true
		-- Хост прогрузился — его экран загрузки закрыт, метка больше не нужна.
		I.ClearHostMark("хост в игре")
	end

	local arr = I.Arrival
	if arr then
		local key = I.KeyFor(ply)
		if key then arr.arrived[key] = true end
		checkAllArrived()
	end

	trySendArrival(ply)
end

local function findRecord(ply)
	local key = I.KeyFor(ply)
	if key and I.Pending[key] then return I.Pending[key] end

	-- В одиночной игре SteamID64 мог быть недоступен при сохранении или при загрузке.
	if game.SinglePlayer() then
		for _, rec in pairs(I.Pending) do return rec end
	end
	return nil
end

hook.Add("PlayerSpawn", "MS_RestoreState", function(ply)
	if not I.Arrival or I.Spawned[ply] or I.Restoring[ply] then return end

	local rec = findRecord(ply)
	if rec then
		I.Pending[rec.sid] = nil
		I.Restoring[ply] = rec
	end

	-- Применяем на следующем тике: к этому моменту гамемод полностью отработал
	-- PlayerSpawn (класс игрока, модель, хендсы) и ничего не перезапишет.
	timer.Simple(0, function()
		if not IsValid(ply) then return end
		local pending = I.Restoring[ply]
		I.Restoring[ply] = nil

		if pending then
			local given = I.Apply(ply, pending)
			MS.Log("%s: восстановлено HP %s, броня %s, оружие %d", ply:Nick(), tostring(pending.hp), tostring(pending.armor), given)
		end

		I.Spawned[ply] = true
		trySendArrival(ply)
	end)
end)

-- Пока сохранённый инвентарь не выдан, стандартный лоадаут гамемода не нужен.
hook.Add("PlayerLoadout", "MS_SuppressLoadout", function(ply)
	if I.Restoring[ply] then return true end
end)

hook.Add("PlayerDisconnected", "MS_InventoryCleanup", function(ply)
	local arr = I.Arrival
	if not arr then return end
	local key = I.KeyFor(ply)
	if key then arr.expected[key] = nil end
	checkAllArrived()
end)
