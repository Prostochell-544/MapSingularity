--[[
	MapSingularity — клиентская часть подготовки.

	* Хост listen-сервера / одиночной игры качает GMA по запросу сервера
	  (steamworks.DownloadUGC существует только на клиенте).
	* Каждый клиент заранее скачивает и монтирует карту портала и прогревает её
	  материалы/модели, чтобы changelevel не упирался в загрузку контента.
	* После InitPostEntity клиент сообщает серверу, что готов принимать сообщения.
]]

local MS = MapSingularity
MS.Prefetch = MS.Prefetch or {}
local C = MS.Prefetch

local TIMER_NAME = "MS_ClientPrecache"

C.Token = C.Token or 0

local function sliceMs()
	return MS.CVars.SliceMs:GetFloat()
end

--------------------------------------------------------------------------------
-- Скачивание по просьбе сервера (только хост)
--------------------------------------------------------------------------------

net.Receive(MS.Net.DownloadReq, function()
	local id = MS.NormalizeID(net.ReadString())
	if not id then return end

	MS.Log("сервер просит скачать предмет %s", id)

	steamworks.DownloadUGC(id, function(path)
		net.Start(MS.Net.DownloadResult)
		net.WriteString(id)
		net.WriteBool(isstring(path) and path ~= "")
		net.WriteString(isstring(path) and path or "")
		net.SendToServer()

		if path then
			MS.Log("предмет %s скачан: %s", id, path)
		else
			MS.Warn("steamworks.DownloadUGC не смог скачать %s", id)
		end
	end)
end)

--------------------------------------------------------------------------------
-- Префетч карты портала
--------------------------------------------------------------------------------

local function report(id, ok)
	-- После неудачи разрешаем повторную попытку для того же предмета.
	if not ok and C.Job and C.Job.id == id then C.Job = nil end

	net.Start(MS.Net.PrefetchDone)
	net.WriteString(id)
	net.WriteBool(ok)
	net.SendToServer()
end

local function warm(token, job)
	local queue = {}
	for _, m in ipairs(job.assets.t or {}) do
		if isstring(m) then queue[#queue + 1] = { false, m } end
	end
	for _, m in ipairs(job.assets.m or {}) do
		if isstring(m) then queue[#queue + 1] = { true, m } end
	end

	local warmed = 0
	C.Progress = 0

	MS.Amortize(TIMER_NAME, queue, sliceMs, function(item)
		if token ~= C.Token then return end
		if item[1] then
			if file.Exists(item[2], "GAME") then
				util.PrecacheModel(item[2])
				warmed = warmed + 1
			end
		elseif file.Exists("materials/" .. item[2] .. ".vmt", "GAME") then
			-- Без проверки существования нельзя: Material() на отсутствующий vmt
			-- закэширует error-материал, и он переживёт смену карты.
			local mat = Material(item[2])
			if mat and not mat:IsError() then warmed = warmed + 1 end
		end
	end, function(done, total)
		C.Progress = done / total
	end, function(_, total)
		if token ~= C.Token then return end
		C.Progress = 1
		C.Ready = job.id
		MS.Log("префетч %s: прогрето %d из %d", job.map, warmed, total)
		report(job.id, true)
	end)
end

local function mountAndWarm(token, job)
	if file.Exists("maps/" .. job.map .. ".bsp", "GAME") then
		-- Хост listen-сервера: сервер уже смонтировал GMA в общую файловую систему.
		return warm(token, job)
	end

	steamworks.DownloadUGC(job.id, function(path)
		if token ~= C.Token then return end
		if not path then
			MS.Warn("не удалось скачать %s — карта будет загружена при переподключении", job.id)
			return report(job.id, false)
		end

		local ok = game.MountGMA(path)
		if not ok or not file.Exists("maps/" .. job.map .. ".bsp", "GAME") then
			MS.Warn("не удалось смонтировать %s", path)
			return report(job.id, false)
		end

		warm(token, job)
	end)
end

net.Receive(MS.Net.Prefetch, function()
	local id = MS.NormalizeID(net.ReadString())
	local map = net.ReadString()
	local title = net.ReadString()
	local len = net.ReadUInt(32)
	local blob = len > 0 and len <= MS.MAX_NET_BLOB and net.ReadData(len) or nil

	if not id or not MS.IsSafeMapName(map) then return end
	if C.Job and C.Job.id == id then
		-- Уже прогрето — просто подтверждаем; ещё в работе — ждём завершения.
		if C.Ready == id then report(id, true) end
		return
	end

	C.Token = C.Token + 1
	timer.Remove(TIMER_NAME)

	local assets = {}
	if blob then
		local json = util.Decompress(blob, MS.MAX_NET_BLOB * 64)
		assets = json and util.JSONToTable(json) or {}
	end

	local job = { id = id, map = map, title = title, assets = istable(assets) and assets or {} }
	C.Job = job
	C.Ready = nil
	C.Progress = 0

	if not MS.CVars.Prefetch:GetBool() then
		return report(id, false)
	end

	MS.Log("префетч карты %s (%s)", map, title)
	mountAndWarm(C.Token, job)
end)

--------------------------------------------------------------------------------
-- Готовность клиента
--------------------------------------------------------------------------------

-- Установлен ли у этого клиента патч экрана загрузки хоста
-- (tools/host-tunnel-patch.ps1 в папке проекта): скрипт тоннеля лежит в
-- garrysmod/html/ и подключён в loading.html.
local function hasHostTunnelPatch()
	if not file.Exists("html/ms_tunnel.js", "GAME") then return false end
	local page = file.Read("html/loading.html", "GAME")
	return isstring(page) and string.find(page, "ms_tunnel.js", 1, true) ~= nil
end

C.HasHostPatch = hasHostTunnelPatch

hook.Add("InitPostEntity", "MS_ClientReady", function()
	net.Start(MS.Net.ClientReady)
	net.WriteBool(hasHostTunnelPatch())
	net.SendToServer()
end)
