--[[
	MapSingularity — режиссёр: машина состояний подготовки портала.

	IDLE -> DISCOVER -> DOWNLOAD -> MOUNT -> PRECACHE -> SYNC -> READY -> TRANSIT
	Любая ошибка кандидата — переход к следующему; три пустых раунда поиска —
	возврат в IDLE (при ms_auto_fetch повтор через 3 минуты).
	Каждый асинхронный шаг несёт token: после отмены/перезапуска старые
	колбэки молча игнорируются.
]]

local MS = MapSingularity
MS.Director = MS.Director or {}
local D = MS.Director
local PH = MS.Phase

local MAX_ROUNDS = 3
local MAX_DOWNLOADS_PER_ROUND = 4
local RETRY_DELAY = 180
local PROGRESS_INTERVAL = 0.25

D.Phase = D.Phase or PH.IDLE
D.PhaseText = D.PhaseText or ""
D.Progress = D.Progress or -1
D.Token = D.Token or 0
D.ReadyClients = D.ReadyClients or setmetatable({}, { __mode = "k" })
D.ClientsDone = D.ClientsDone or setmetatable({}, { __mode = "k" })

function MS.IsClientReady(ply)
	return D.ReadyClients[ply] == true
end

--------------------------------------------------------------------------------
-- Фаза и оповещения
--------------------------------------------------------------------------------

local function writePhase()
	net.WriteUInt(D.Phase, 4)
	net.WriteString(D.PhaseText)
	net.WriteFloat(D.Progress)
end

function D.BroadcastPhase(target)
	net.Start(MS.Net.Phase)
	writePhase()
	if target then net.Send(target) else net.Broadcast() end
end

function D.SetPhase(phase, text, progress)
	D.Phase = phase
	D.PhaseText = text or ""
	D.Progress = progress or -1
	D.BroadcastPhase()
end

local lastProgress = 0
local function setProgress(frac)
	D.Progress = frac
	if SysTime() - lastProgress >= PROGRESS_INTERVAL or frac >= 1 then
		lastProgress = SysTime()
		D.BroadcastPhase()
	end
end

-- У хоста одиночной игры / listen-сервера консоль сервера и клиента одна и та же:
-- сообщение для него не дублируем в серверный лог.
function MS.IsHost(ply)
	return IsValid(ply) and (game.SinglePlayer() or ply:IsListenServerHost())
end

-- Техническое сообщение: в лог сервера и в чат игрока, только если у него включена отладка.
-- Игрокам важное шлём через MS.Notice с ключом фразы (sh_lang) — переводит клиент.
function D.Notify(ply, fmt, ...)
	local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
	if IsValid(ply) then MS.Notice(ply, MS.NOTICE_DEBUG, msg) end
	if not MS.IsHost(ply) then MS.Log(msg) end
end

local function alive(token) return token == D.Token end

-- Управлять рулеткой могут консоль сервера, суперадмины и хост.
function D.Allowed(ply)
	return not IsValid(ply) or ply:IsSuperAdmin() or ply:IsListenServerHost()
end

function D.Busy()
	return D.Phase ~= PH.IDLE and D.Phase ~= PH.READY
end

--------------------------------------------------------------------------------
-- Запуск и отмена
--------------------------------------------------------------------------------

local function scheduleAuto(delay)
	timer.Create("MS_AutoFetch", delay, 1, function()
		if not MS.CVars.AutoFetch:GetBool() then return end
		if D.Phase ~= PH.IDLE or MS.Inventory.Transit then return end
		if #player.GetHumans() == 0 then return scheduleAuto(30) end
		D.Start(nil)
	end)
end

function D.Fail(token, reason)
	if not alive(token) then return end
	D.Notify(D.Requester, "подготовка не удалась: %s", reason)
	if IsValid(D.Requester) then MS.Notice(D.Requester, MS.NOTICE_POPUP, "prepare_failed") end
	D.Target = nil
	if IsValid(D.Portal) and not D.Portal:GetStable() then D.Portal:Remove() end
	D.SetPhase(PH.IDLE, reason)
	if MS.CVars.AutoFetch:GetBool() then scheduleAuto(RETRY_DELAY) end
end

function D.Cancel(reason)
	D.Token = D.Token + 1
	MS.Precache.Cancel()
	MS.Workshop.CancelPending()
	timer.Remove("MS_SyncTimeout")
	if IsValid(D.Portal) then D.Portal:Remove() end
	D.Portal = nil
	D.Target = nil
	D.SetPhase(PH.IDLE, reason or "")
end

-- requester: игрок или nil (консоль/авто); forcedId: конкретный Workshop ID.
function D.Start(requester, forcedId)
	-- Причины отказа — ключи фраз (sh_lang): их переводит клиент, в консоль — MS.T.
	if MS.Inventory.Transit then return false, "busy_transit" end
	if D.Busy() then return false, "busy_prepare" end

	if D.Phase == PH.READY then
		-- Повторный бросок рулетки: старый стабильный портал схлопывается.
		if IsValid(D.Portal) and D.Portal:GetStable() then D.Portal:Remove() end
		D.Target = nil
	end

	timer.Remove("MS_AutoFetch")
	D.Token = D.Token + 1
	D.Requester = requester
	D.Round = 0

	D.SetPhase(PH.DISCOVER, forcedId or "")
	D.NextRound(D.Token, forcedId)
	return true
end

function D.NextRound(token, forcedId)
	if not alive(token) then return end
	D.Round = D.Round + 1
	if D.Round > MAX_ROUNDS then
		return D.Fail(token, "за " .. MAX_ROUNDS .. " раунда поиска подходящая карта не найдена")
	end

	MS.Workshop.FindCandidates(forcedId, function(list, err)
		if not alive(token) then return end
		if not list then
			if forcedId then return D.Fail(token, err or "предмет не подходит") end
			MS.Warn("раунд %d: %s", D.Round, tostring(err))
			return D.NextRound(token)
		end
		D.TryCandidate(token, list, 1, forcedId)
	end)
end

-- Отказ по рейтингу дешёвый (один запрос FileInfo) и лимит раунда не тратит;
-- лимит считает только реальные попытки скачать и смонтировать.
function D.TryCandidate(token, list, index, forcedId, downloads)
	if not alive(token) then return end
	downloads = downloads or 0

	local cand = list[index]
	if not cand or downloads >= MAX_DOWNLOADS_PER_ROUND then
		if forcedId then return D.Fail(token, "предмет " .. forcedId .. " не прошёл проверку") end
		return D.NextRound(token)
	end

	local function skip(reason, broken)
		if not alive(token) then return end
		MS.Warn("пропуск %s «%s»: %s", cand.id, cand.title, tostring(reason))
		if broken then MS.Workshop.MarkBroken(cand.id, reason) end
		D.TryCandidate(token, list, index + 1, forcedId, downloads + 1)
	end

	MS.Workshop.CheckRating(cand, forcedId ~= nil, function(ok, why)
		if not alive(token) then return end
		if not ok then
			MS.Log("отсев %s «%s»: %s", cand.id, cand.title, tostring(why))
			return D.TryCandidate(token, list, index + 1, forcedId, downloads)
		end

		D.SetPhase(PH.DOWNLOAD, cand.title)

		MS.Workshop.Download(cand, function(path, err, broken)
			if not alive(token) then return end
			if not path then return skip(err, broken) end

			D.SetPhase(PH.MOUNT, cand.title)

			local mapName, merr, mbroken = MS.Workshop.Mount(path)
			if not mapName then return skip(merr, mbroken) end

			local info, ierr = MS.Precache.Inspect(mapName)
			if not info then return skip(ierr, true) end

			cand.map = mapName
			cand.path = path
			cand.assets = info.assets
			D.Target = cand
			MS.Workshop.Remember(cand.id)

			D.Notify(D.Requester, "карта найдена: %s (%s, BSP v%d, моделей %d, материалов %d, в pakfile %d)",
				cand.title, mapName, info.version, #info.assets.models, #info.assets.materials, info.assets.packed)

			D.RunPrecache(token)
		end)
	end)
end

--------------------------------------------------------------------------------
-- Прекэш и синхронизация клиентов
--------------------------------------------------------------------------------

function D.RunPrecache(token)
	local target = D.Target
	D.SetPhase(PH.PRECACHE, target.map, 0)

	MS.Precache.Run(target.assets, function(done, total)
		if alive(token) then setProgress(done / total) end
	end, function(stats)
		if not alive(token) then return end
		MS.Log("прекэш сервера: %d/%d (ошибок материалов %d)", stats.warmed, stats.total, stats.failed)
		D.BeginSync(token)
	end)
end

local function prefetchBlob(target)
	if target.blob then return target.blob end
	local payload = { m = table.Copy(target.assets.models), t = table.Copy(target.assets.materials) }
	local blob = util.Compress(util.TableToJSON(payload)) or ""

	-- Слишком длинный список — режем материалы, затем модели, пока не влезет.
	while #blob > MS.MAX_NET_BLOB and (#payload.t > 0 or #payload.m > 0) do
		local list = #payload.t > 0 and payload.t or payload.m
		for _ = 1, math.max(1, math.floor(#list / 4)) do table.remove(list) end
		blob = util.Compress(util.TableToJSON(payload)) or ""
	end

	target.blob = blob
	return blob
end

function D.SendPrefetch(ply)
	local target = D.Target
	if not target or not IsValid(ply) then return end
	local blob = prefetchBlob(target)

	net.Start(MS.Net.Prefetch)
	net.WriteString(target.id)
	net.WriteString(target.map)
	net.WriteString(target.title)
	net.WriteUInt(#blob, 32)
	if #blob > 0 then net.WriteData(blob, #blob) end
	net.Send(ply)
end

local function syncPending()
	local waiting = 0
	for _, ply in ipairs(player.GetHumans()) do
		if D.ReadyClients[ply] and D.ClientsDone[ply] == nil then waiting = waiting + 1 end
	end
	return waiting
end

function D.BeginSync(token)
	D.ClientsDone = setmetatable({}, { __mode = "k" })
	D.SyncToken = token
	D.SetPhase(PH.SYNC, D.Target and D.Target.map or "", 0)

	for _, ply in ipairs(player.GetHumans()) do
		if D.ReadyClients[ply] then D.SendPrefetch(ply) end
	end

	if syncPending() == 0 then return D.FinishSync(token, false) end

	timer.Create("MS_SyncTimeout", MS.CVars.ClientWait:GetFloat(), 1, function()
		D.FinishSync(token, true)
	end)
end

function D.CheckSync()
	if D.Phase ~= PH.SYNC then return end
	local humans = 0
	for _, ply in ipairs(player.GetHumans()) do
		if D.ReadyClients[ply] then humans = humans + 1 end
	end
	local waiting = syncPending()
	setProgress(humans > 0 and (humans - waiting) / humans or 1)
	if waiting == 0 then D.FinishSync(D.SyncToken, false) end
end

function D.FinishSync(token, timedOut)
	if not alive(token) or D.Phase ~= PH.SYNC then return end
	timer.Remove("MS_SyncTimeout")

	if timedOut then MS.Warn("не все клиенты успели прогреть карту — они докачают её при переподключении") end

	D.SetPhase(PH.READY, D.Target.title)
	if game.IsDedicated() then MS.Log("карта готова: %s", D.Target.title) end

	if IsValid(D.Portal) then
		-- Портал уже поставлен пушкой (нестабильным) — стабилизируем там же.
		D.Portal:Stabilize(D.Target.title, D.Target.map)
		MS.Notice(nil, MS.NOTICE_CHAT, "portal_stable", D.Target.title)
	elseif MS.CVars.Autoplace:GetBool() and D.SpawnPortal(D.Requester) then
		MS.Notice(nil, MS.NOTICE_CHAT, "portal_stable", D.Target.title)
	else
		-- Пушку сами не выдаём: её берут из меню спавна (или ms_give_gun).
		MS.Notice(nil, MS.NOTICE_CHAT, "map_ready", D.Target.title)
	end
end

--------------------------------------------------------------------------------
-- Портал
--------------------------------------------------------------------------------

-- Визуальный размер портала (диск с ореолом), а не только триггер: иначе он
-- встаёт впритык и диск торчит из стены.
local VIS_RADIUS = 72
local VIS_HEIGHT = 156
local GUN_RANGE = 4000
local GUN_CLASS = "weapon_singularity"

local function spaceClear(pos, radius, height, filter)
	radius = radius or MS.PORTAL_RADIUS
	height = height or MS.PORTAL_HEIGHT
	local tr = util.TraceHull({
		start = pos + Vector(0, 0, 2),
		endpos = pos + Vector(0, 0, 3),
		mins = Vector(-radius, -radius, 0),
		maxs = Vector(radius, radius, height),
		mask = MASK_SOLID,
		filter = filter,
	})
	return not tr.StartSolid and not tr.Hit
end

-- Портал смотрит на игрока.
function D.FacingAngle(pos, ply)
	if not IsValid(ply) then return Angle(0, 0, 0) end
	local dir = ply:GetPos() - pos
	return Angle(0, dir:Angle().y, 0)
end

local YAW_OFFSETS = { 0, 35, -35, 70, -70, 110, -110, 180 }
local DISTANCES = { 260, 190, 130 }
local SPAWN_CLASSES = { "info_player_start", "info_player_deathmatch", "info_player_combine", "info_player_rebel", "gmod_player_start" }

-- Автоматическое место рядом с игроком (только при ms_portal_autoplace 1).
local function searchSpot(preferred, radius, height)
	local anchors = {}
	if IsValid(preferred) and preferred:IsPlayer() and preferred:Alive() then anchors[1] = preferred end
	for _, ply in ipairs(player.GetHumans()) do
		if ply ~= preferred and ply:Alive() then anchors[#anchors + 1] = ply end
	end

	for _, ply in ipairs(anchors) do
		local eye = ply:EyePos()
		local yaw = ply:EyeAngles().y

		for _, dist in ipairs(DISTANCES) do
			for _, off in ipairs(YAW_OFFSETS) do
				local dir = Angle(0, yaw + off, 0):Forward()
				local fwd = util.TraceLine({ start = eye, endpos = eye + dir * dist, filter = ply, mask = MASK_SOLID })
				local point = fwd.Hit and (fwd.HitPos - dir * (radius + 8)) or fwd.HitPos
				local down = util.TraceLine({ start = point, endpos = point - Vector(0, 0, 512), filter = ply, mask = MASK_SOLID })

				if down.Hit and not down.StartSolid and down.HitNormal.z > 0.7 then
					local ground = down.HitPos + Vector(0, 0, 2)
					if ground:Distance(ply:GetPos()) > 110 and spaceClear(ground, radius, height, ply) then
						return ground, D.FacingAngle(ground, ply)
					end
				end
			end
		end
	end

	for _, class in ipairs(SPAWN_CLASSES) do
		for _, spawn in ipairs(ents.FindByClass(class)) do
			local pos = spawn:GetPos() + spawn:GetForward() * 180
			local down = util.TraceLine({ start = pos + Vector(0, 0, 32), endpos = pos - Vector(0, 0, 256), mask = MASK_SOLID })
			if down.Hit and spaceClear(down.HitPos + Vector(0, 0, 2), radius, height) then
				return down.HitPos + Vector(0, 0, 2), spawn:GetAngles()
			end
		end
	end

	return nil
end

function D.FindPortalSpot(preferred)
	local pos, ang = searchSpot(preferred, VIS_RADIUS, VIS_HEIGHT)
	if pos then return pos, ang end
	-- Тесное место: хотя бы чтобы влез сам триггер.
	return searchSpot(preferred, nil, nil)
end

--[[
	Место по выстрелу пушки. Попали в пол — ставим там; в стену или потолок —
	отступаем от поверхности на визуальный радиус. Если не хватает места, шаг за
	шагом отходим к стрелку. Сначала ищем место под весь диск, потом — хотя бы под
	триггер (узкие коридоры).
]]
function D.SpotFromAim(ply, tr)
	if not tr or not tr.Hit then return nil, "aim_miss" end
	if tr.HitSky then return nil, "aim_sky" end

	local shoot = ply:GetShootPos()
	if tr.HitPos:Distance(shoot) > GUN_RANGE then return nil, "aim_far" end

	local back = -tr.Normal
	local start
	if tr.HitNormal.z > 0.7 then
		start = tr.HitPos
	else
		start = tr.HitPos + tr.HitNormal * (VIS_RADIUS + 8)
	end

	for pass = 1, 2 do
		local radius = pass == 1 and VIS_RADIUS or nil
		local height = pass == 1 and VIS_HEIGHT or nil

		for step = 0, 12 do
			local probe = start + back * (step * 24)
			if step > 0 and probe:Distance(shoot) < 90 then break end

			local down = util.TraceLine({ start = probe + Vector(0, 0, 24), endpos = probe - Vector(0, 0, 700), filter = ply, mask = MASK_SOLID })
			if down.Hit and not down.StartSolid and down.HitNormal.z > 0.7 then
				local ground = down.HitPos + Vector(0, 0, 2)
				if spaceClear(ground, radius, height, ply) then return ground end
			end
		end
	end

	return nil, "aim_space"
end

-- Поставить или переставить портал. Стабилен, если карта уже готова.
function D.PlacePortal(pos, ang)
	local ent = D.Portal
	if IsValid(ent) then
		ent:SetPos(pos)
		ent:SetAngles(ang)
		ent:SetBirthTime(CurTime())
		return ent
	end

	ent = ents.Create("roulette_portal")
	if not IsValid(ent) then return nil end
	ent:SetPos(pos)
	ent:SetAngles(ang)
	ent:Spawn()
	ent:Activate()
	D.Portal = ent

	if D.Phase == PH.READY and D.Target then ent:Stabilize(D.Target.title, D.Target.map) end
	return ent
end

function D.SpawnPortal(preferred)
	if IsValid(D.Portal) then
		D.Portal:Stabilize(D.Target.title, D.Target.map)
		return true
	end

	local pos, ang = D.FindPortalSpot(preferred)
	if not pos then return false end
	return D.PlacePortal(pos, ang) ~= nil
end

function D.GiveGun(preferred)
	local targets = {}
	if IsValid(preferred) and preferred:IsPlayer() then
		targets[1] = preferred
	else
		for _, ply in ipairs(player.GetHumans()) do
			if MS.IsHost(ply) or ply:IsSuperAdmin() then targets[#targets + 1] = ply end
		end
	end

	for _, ply in ipairs(targets) do
		if ply:Alive() and not ply:HasWeapon(GUN_CLASS) then
			ply:Give(GUN_CLASS)
			MS.Notice(ply, MS.NOTICE_CHAT, "gun_given")
		end
	end
end

-- key — ключ фразы (sh_lang): отказ всплывашкой на языке игрока.
local function gunDeny(ply, key)
	ply:EmitSound("buttons/button10.wav", 60)
	MS.Notice(ply, MS.NOTICE_POPUP, key)
end

function D.GunPlace(ply, tr)
	if not D.Allowed(ply) then return gunDeny(ply, "gun_admin_only") end
	if MS.Inventory.Transit then return end

	local pos, err = D.SpotFromAim(ply, tr)
	if not pos then return gunDeny(ply, err) end

	D.PlacePortal(pos, D.FacingAngle(pos, ply))
	D.Requester = ply

	if D.Phase == PH.IDLE then
		local ok, why = D.Start(ply)
		if not ok then MS.Notice(ply, MS.NOTICE_POPUP, why) end
	end
end

function D.GunReroll(ply)
	if not D.Allowed(ply) then return gunDeny(ply, "gun_admin_only") end
	if MS.Inventory.Transit then return end
	if D.Busy() then return gunDeny(ply, "busy_prepare") end

	local pos, ang
	if IsValid(D.Portal) then
		pos, ang = D.Portal:GetPos(), D.Portal:GetAngles()
		D.Portal:Remove()
		D.Portal = nil
	end

	local ok, why = D.Start(ply)
	if not ok then return gunDeny(ply, why) end

	-- Новая карта ищется, а портал остаётся на месте — нестабильным.
	if pos then D.PlacePortal(pos, ang) end
	MS.Notice(ply, MS.NOTICE_DEBUG, "рулетка крутится...")
end

function D.GunCollapse(ply)
	if not D.Allowed(ply) or MS.Inventory.Transit or not IsValid(D.Portal) then return false end
	D.Portal:Remove()
	D.Portal = nil
	return true
end

-- Портал, заспавненный вручную из меню (только админы).
function D.AdoptPortal(ent, ply)
	if IsValid(D.Portal) and D.Portal ~= ent then D.Portal:Remove() end
	D.Portal = ent

	if D.Phase == PH.READY and D.Target then
		ent:Stabilize(D.Target.title, D.Target.map)
	elseif D.Phase == PH.IDLE then
		local ok, err = D.Start(ply)
		if not ok then MS.Notice(ply, MS.NOTICE_POPUP, err) end
	end
end

function D.OnPortalRemoved(ent)
	if D.Portal == ent then D.Portal = nil end
end

function D.EnterPortal(portal, ply)
	if D.Phase ~= PH.READY or not D.Target or portal ~= D.Portal then return end
	local ok, err = MS.Inventory.BeginTransit(D.Target, ply)
	if ok then
		D.SetPhase(PH.TRANSIT, D.Target.title)
	else
		D.Notify(ply, "прыжок невозможен: %s", tostring(err))
		MS.Notice(ply, MS.NOTICE_POPUP, "jump_failed")
	end
end

function D.OnTransitAborted(reason)
	if D.Target then
		D.SetPhase(PH.READY, D.Target.title)
	else
		D.SetPhase(PH.IDLE, reason)
	end
end

hook.Add("PostCleanupMap", "MS_RespawnPortal", function()
	if D.Phase == PH.READY and D.Target and not IsValid(D.Portal) and MS.CVars.Autoplace:GetBool() then
		D.SpawnPortal(D.Requester)
	end
end)

--------------------------------------------------------------------------------
-- Сеть
--------------------------------------------------------------------------------

net.Receive(MS.Net.ClientReady, function(_, ply)
	local hostPatch = net.ReadBool()
	if D.ReadyClients[ply] then return end
	D.ReadyClients[ply] = true

	D.BroadcastPhase(ply)
	if D.Target and D.Phase >= PH.SYNC and D.Phase <= PH.READY then D.SendPrefetch(ply) end

	MS.Inventory.OnClientReady(ply, hostPatch)
end)

net.Receive(MS.Net.PrefetchDone, function(_, ply)
	local id = net.ReadString()
	local ok = net.ReadBool()
	if not D.Target or id ~= D.Target.id or D.ClientsDone[ply] ~= nil then return end

	D.ClientsDone[ply] = ok
	MS.Log("клиент %s: префетч %s", ply:Nick(), ok and "готов" or "не удался")
	D.CheckSync()
end)

-- Панель «Утилиты» → настройка. Только для тех, кому можно управлять рулеткой,
-- и только из списка MS.Settings с проверкой значения.
net.Receive(MS.Net.Setting, function(_, ply)
	local name = net.ReadString()
	local value = net.ReadString()
	if not D.Allowed(ply) then return end

	local check = MS.Settings[name]
	local normalized = check and check(value)
	if normalized == nil then return end

	local cv = GetConVar(name)
	if not cv or cv:GetString() == normalized then return end
	cv:SetString(normalized)
	MS.Log("%s: %s = %s", ply:Nick(), name, normalized)
end)

hook.Add("PlayerDisconnected", "MS_DirectorCleanup", function(ply)
	D.ReadyClients[ply] = nil
	D.ClientsDone[ply] = nil
	timer.Simple(0, D.CheckSync)
end)

hook.Add("InitPostEntity", "MS_DirectorAuto", function()
	if MS.CVars.AutoFetch:GetBool() then scheduleAuto(MS.CVars.AutoDelay:GetFloat()) end
end)

--------------------------------------------------------------------------------
-- Консольные команды
--------------------------------------------------------------------------------

local allowed = D.Allowed

local function reply(ply, fmt, ...)
	local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
	if IsValid(ply) then ply:PrintMessage(HUD_PRINTCONSOLE, "[MapSingularity] " .. msg) end
	if not MS.IsHost(ply) then MS.Log(msg) end
end

concommand.Add("ms_force_fetch", function(ply, _, args)
	if not allowed(ply) then return reply(ply, "нужны права superadmin") end

	local forced
	if args[1] and args[1] ~= "" then
		forced = MS.NormalizeID(string.match(args[1], "id=(%d+)") or args[1])
		if not forced then return reply(ply, "некорректный Workshop ID: %s", args[1]) end
	end

	if MS.Inventory.Transit then return reply(ply, "прыжок уже идёт — дождитесь смены карты или ms_abort") end
	if D.Busy() then D.Cancel("перезапуск через ms_force_fetch") end

	local ok, err = D.Start(ply, forced)
	if ok then
		reply(ply, forced and ("загрузка предмета " .. forced .. "...") or "рулетка запущена...")
	else
		reply(ply, "не запущено: %s", MS.T(err))
	end
end, nil, "Немедленно найти/скачать/прекэшировать карту. Аргумент: Workshop ID или ссылка (необязательно).")

concommand.Add("ms_abort", function(ply)
	if not allowed(ply) then return reply(ply, "нужны права superadmin") end
	if MS.Inventory.Transit then MS.Inventory.Rollback("отменено командой ms_abort") end
	D.Cancel("отменено командой ms_abort")
	reply(ply, "подготовка остановлена, портал удалён")
end, nil, "Остановить подготовку/прыжок и убрать портал.")

concommand.Add("ms_portal_here", function(ply)
	if not allowed(ply) then return reply(ply, "нужны права superadmin") end
	if D.Phase ~= PH.READY or not D.Target then return reply(ply, "портал ещё не готов (%s)", MS.PhaseName[D.Phase]) end
	if IsValid(D.Portal) then D.Portal:Remove() end
	D.Portal = nil
	if not D.SpawnPortal(ply) then return reply(ply, "не найдено свободное место") end
	reply(ply, "портал перемещён")
end, nil, "Переставить готовый портал рядом с собой.")

concommand.Add("ms_give_gun", function(ply)
	if not allowed(ply) then return reply(ply, "нужны права superadmin") end
	if not IsValid(ply) then return reply(ply, "команду нужно вводить из игры") end
	if not ply:HasWeapon("weapon_singularity") then D.GiveGun(ply) end
	ply:SelectWeapon("weapon_singularity")
end, nil, "Выдать себе КПП «Лунь».")

concommand.Add("ms_test_hostmark", function(ply)
	if not allowed(ply) then return reply(ply, "нужны права superadmin") end
	if MS.Inventory.Transit then return reply(ply, "идёт прыжок — проверка недоступна") end

	MS.Inventory.TestHostMark(function(ok, readBack)
		local bytes = {}
		for i = math.max(1, #readBack - 5), #readBack do bytes[#bytes + 1] = string.format("%02X", string.byte(readBack, i)) end
		reply(ply, "метка в hostname %s; прочитано \"%s\" (%d байт, хвост %s)",
			ok and "держится" or "НЕ держится — движок её срезал", readBack, #readBack, table.concat(bytes, " "))
	end)
end, nil, "Диагностика: проверить, сохраняет ли движок невидимую метку в hostname.")

concommand.Add("ms_status", function(ply)
	local t = D.Target
	reply(ply, "фаза: %s%s%s", MS.PhaseName[D.Phase],
		D.PhaseText ~= "" and (" (" .. D.PhaseText .. ")") or "",
		D.Progress >= 0 and string.format(", %d%%", math.floor(D.Progress * 100)) or "")
	if t then
		reply(ply, "цель: %s [%s] карта %s, рейтинг %s, голосов %s", t.title, t.id, tostring(t.map),
			t.score and string.format("%.2f", t.score) or "?", tostring(t.votes or "?"))
	end
	local cur = GetConVar("sv_loadingurl")
	reply(ply, "sv_loadingurl: \"%s\", ms_loading_url: \"%s\"", cur and cur:GetString() or "", MS.CVars.LoadingURL:GetString())
	local _, why = MS.Inventory.ChooseLoadingURL()
	reply(ply, "экран загрузки при прыжке — %s", why)
	for _, p in ipairs(player.GetHumans()) do
		if MS.IsHost(p) then
			reply(ply, "патч тоннеля у хоста %s: %s", p:Nick(), MS.Inventory.HostTunnel[p] and "установлен" or "нет")
		end
	end
	reply(ply, "чёрный список: %d, история: %d", table.Count(MS.Workshop.Blacklist), #MS.Workshop.History)
end, nil, "Состояние MapSingularity.")
