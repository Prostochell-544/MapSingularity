--[[
	MapSingularity — клиентские эффекты перехода.

	Режимы оверлея:
	  "out"  — вход в портал: растяжение FOV, радиальный блюр, обесцвечивание,
	           затемнение до чёрного за MS.FADE_OUT_TIME (1.5 с);
	  "hold" — сплошной чёрный: до changelevel, а на новой карте — с первого
	           кадра до сигнала сервера (маркер data/map_singularity/client_transit.json);
	  "in"   — пробуждение: чёрный растворяется за MS.FADE_IN_TIME (2.0 с),
	           FOV и блюр мягко возвращаются к норме.
]]

local MS = MapSingularity
MS.Visuals = MS.Visuals or {}
local V = MS.Visuals

local MARKER_TTL   = 300 -- сек: маркер старше — не наш переход
local HOLD_TIMEOUT = 15  -- сек после InitPostEntity без сигнала сервера
local FOV_OUT      = 55  -- градусов к FOV на пике растяжения
local FOV_IN       = 18
local BLUR_OUT     = 0.30
local BLUR_IN      = 0.12
local BLUR_LAYERS  = 10

-- Спагеттификация при входе: картинка закручивается в спираль и вытягивается,
-- камера заваливается набок.
-- Умеренно: эффект должен быть весёлым аттракционом, а не кошмаром.
local TWIST_OUT    = 0.6  -- закрутка к концу входа (последний слой ~17°)
local STRETCH_OUT  = 0.5  -- дополнительное вертикальное вытягивание слоёв
local ROLL_OUT     = 12   -- градусов крена камеры

-- Гравитационное искажение рядом со стабильным порталом.
local PROX_RADIUS  = 450
local FOV_PROX     = 10
local BLUR_PROX    = 0.07
local TWIST_PROX   = 0.25

local SND_SUCK  = "ambient/levels/labs/teleport_preblast_suckin1.wav"
local SND_WAKE  = "ambient/levels/labs/teleport_winddown1.wav"

--------------------------------------------------------------------------------
-- Машина состояний оверлея
--------------------------------------------------------------------------------

local function setMode(mode, duration)
	V.Mode = mode
	V.Start = RealTime()
	V.Duration = duration or 0
end

local function progress()
	if not V.Mode or V.Duration <= 0 then return 1 end
	return math.Clamp((RealTime() - V.Start) / V.Duration, 0, 1)
end

-- Возвращает альфу чёрного, добавку FOV, силу блюра и закрутку (0..1) перехода.
local function sample()
	local mode = V.Mode
	if not mode then return 0, 0, 0, 0 end

	local t = progress()
	if mode == "out" then
		local e = MS.SmoothStep(t)
		local accel = t * t
		if t >= 1 then setMode("hold", 0); V.FromOut = true end
		return 255 * e, FOV_OUT * accel, BLUR_OUT * accel, TWIST_OUT * accel
	elseif mode == "hold" then
		if V.FromOut then return 255, FOV_OUT, BLUR_OUT, TWIST_OUT end
		return 255, 0, 0, 0
	elseif mode == "in" then
		local inv = 1 - MS.SmoothStep(t)
		if t >= 1 then V.Mode = nil end
		return 255 * inv, FOV_IN * inv * inv, BLUR_IN * inv, 0
	end
	return 0, 0, 0, 0
end

-- Близость к ядру ближайшего стабильного портала: 0 далеко, 1 в самом ядре.
local function proximity()
	if not MS.NearestStablePortal then return 0 end
	local _, dist = MS.NearestStablePortal(EyePos())
	if not dist or dist >= PROX_RADIUS then return 0 end
	local k = 1 - dist / PROX_RADIUS
	return k * k
end

V.Alpha, V.FovAdd, V.Blur, V.Twist, V.Stretch, V.Roll = 0, 0, 0, 0, 0, 0

hook.Add("Think", "MS_VisualsSample", function()
	local alpha, fov, blur, twist = sample()
	local prox = proximity()

	V.Alpha = alpha
	V.FovAdd = fov + FOV_PROX * prox
	V.Blur = math.max(blur, BLUR_PROX * prox)
	V.Twist = math.max(twist, TWIST_PROX * prox)
	V.Stretch = STRETCH_OUT * twist
	V.Roll = ROLL_OUT * twist

	if V.Mode == "hold" and not V.FromOut and V.HoldDeadline and RealTime() > V.HoldDeadline then
		MS.Warn("сервер не подтвердил прибытие — снимаю чёрный экран")
		V.Release(MS.FADE_IN_TIME)
	end
end)

--------------------------------------------------------------------------------
-- Маркер перехода между картами
--------------------------------------------------------------------------------

local function writeMarker(map)
	if not file.IsDir(MS.DATA_DIR, "DATA") then file.CreateDir(MS.DATA_DIR) end
	file.Write(MS.CLIENT_MARKER, util.TableToJSON({ map = map, time = os.time() }))
end

local function clearMarker()
	if file.Exists(MS.CLIENT_MARKER, "DATA") then file.Delete(MS.CLIENT_MARKER) end
end

function V.Release(duration)
	clearMarker()
	V.FromOut = false
	V.HoldDeadline = nil
	setMode("in", duration)
end

-- Первый кадр новой карты: если мы прилетели через портал — сразу держим чёрный.
do
	local marker = MS.ReadJSON(MS.CLIENT_MARKER)
	if istable(marker) then
		local fresh = os.time() - (tonumber(marker.time) or 0) <= MARKER_TTL
		local here = isstring(marker.map) and string.lower(marker.map) == string.lower(game.GetMap())
		if fresh and here then
			V.FromOut = false
			setMode("hold", 0)
			V.Alpha = 255
		else
			clearMarker()
		end
	end
end

hook.Add("InitPostEntity", "MS_VisualsHoldTimeout", function()
	if V.Mode == "hold" and not V.FromOut then V.HoldDeadline = RealTime() + HOLD_TIMEOUT end
end)

--------------------------------------------------------------------------------
-- Ранний сигнал для патча экрана загрузки хоста
--------------------------------------------------------------------------------

--[[
	При смене карты меню отдаёт странице загрузки имя сервера (с меткой прыжка)
	поздно — после загрузки серверной части. Чтобы тоннель включился сразу, за
	~1.8 с до changelevel открываем невидимую страницу html/ms_prime.html: она того же
	origin, что и loading.html, и пишет отметку времени в localStorage. Только если
	патч установлен (tools/host-tunnel-patch.ps1).
]]
local function primeLoadingScreen(clear)
	local C = MS.Prefetch
	if not (C and C.HasHostPatch and C.HasHostPatch()) then return end
	if not file.Exists("html/ms_prime.html", "GAME") then return end

	if IsValid(V.Primer) then V.Primer:Remove() end

	local panel = vgui.Create("DHTML")
	panel:SetSize(8, 8)
	panel:SetPos(-64, -64)
	panel:SetMouseInputEnabled(false)
	panel:SetKeyboardInputEnabled(false)
	panel:OpenURL("asset://garrysmod/html/ms_prime.html" .. (clear and "#clear" or ""))
	V.Primer = panel

	timer.Simple(5, function()
		if IsValid(panel) then panel:Remove() end
	end)
end

--------------------------------------------------------------------------------
-- Сеть
--------------------------------------------------------------------------------

net.Receive(MS.Net.Transit, function()
	local kind = net.ReadUInt(2)
	local map = net.ReadString()
	local text = net.ReadString()
	local duration = net.ReadFloat()

	if kind == MS.TRANSIT_BEGIN then
		writeMarker(map)
		V.FromOut = false
		V.HoldDeadline = nil
		setMode("out", duration > 0 and duration or MS.FADE_OUT_TIME)
		surface.PlaySound(SND_SUCK)
		primeLoadingScreen(false)
		MS.Log("прыжок в %s (%s)", text, map)
	elseif kind == MS.TRANSIT_ABORT then
		local ply = LocalPlayer()
		if IsValid(ply) then ply:SetDSP(0, true) end
		primeLoadingScreen(true)
		V.Release(duration > 0 and duration or 0.6)
		if MS.CVars.Notices:GetBool() then chat.AddText(Color(255, 170, 60), "[MapSingularity] ", color_white, MS.T("jump_aborted")) end
		if text ~= "" and MS.CVars.Debug:GetBool() then chat.AddText(Color(150, 150, 150), "[MapSingularity] " .. text) end
	end
end)

net.Receive(MS.Net.Arrival, function()
	local duration = net.ReadFloat()
	net.ReadString()

	local ply = LocalPlayer()
	if IsValid(ply) then ply:SetDSP(0, true) end

	if V.Mode == "hold" then
		V.Release(duration > 0 and duration or MS.FADE_IN_TIME)
		surface.PlaySound(SND_WAKE)
	else
		clearMarker()
	end
end)

--------------------------------------------------------------------------------
-- FOV
--------------------------------------------------------------------------------

hook.Add("CalcView", "MS_PortalFOV", function(ply, origin, angles, fov, znear, zfar)
	if V.FovAdd < 0.01 then return end

	-- Прогоняем через гамемод, чтобы сохранить машины, SWEP:CalcView и drive,
	-- и лишь расширяем итоговый угол обзора.
	local view = GAMEMODE:CalcView(ply, origin, angles, fov, znear, zfar)
	if not istable(view) then return end
	view.fov = math.min((view.fov or fov) + V.FovAdd, 165)
	if V.Roll > 0.01 then
		view.angles = Angle((view.angles or angles).p, (view.angles or angles).y, (view.angles or angles).r + V.Roll)
	end
	return view
end)

--------------------------------------------------------------------------------
-- Радиальный блюр и цветокоррекция
--------------------------------------------------------------------------------

local matFrame = CreateMaterial("ms_radial_blur_frame", "UnlitGeneric", {
	["$basetexture"] = "_rt_FullFrameFB",
	["$translucent"] = "1",
	["$vertexalpha"] = "1",
	["$vertexcolor"] = "1",
	["$ignorez"] = "1",
	["$nocull"] = "1",
})

local colorMod = {
	["$pp_colour_addr"] = 0,
	["$pp_colour_addg"] = 0,
	["$pp_colour_addb"] = 0,
	["$pp_colour_brightness"] = 0,
	["$pp_colour_contrast"] = 1,
	["$pp_colour_colour"] = 1,
	["$pp_colour_mulr"] = 0,
	["$pp_colour_mulg"] = 0,
	["$pp_colour_mulb"] = 0,
}

-- Четыре вершины переиспользуются каждый кадр — без мусора для сборщика.
local quad = { { x = 0, y = 0, u = 0, v = 0 }, { x = 0, y = 0, u = 0, v = 0 }, { x = 0, y = 0, u = 0, v = 0 }, { x = 0, y = 0, u = 0, v = 0 } }

local function setVertex(vtx, cx, cy, c, s, x, y, u, v)
	vtx.x = cx + x * c - y * s
	vtx.y = cy + x * s + y * c
	vtx.u = u
	vtx.v = v
end

-- Прямоугольник кадра с полуразмерами hw/hh, повёрнутый на rot радиан вокруг центра.
local function drawFrameQuad(cx, cy, hw, hh, rot, u1, v1)
	local c, s = math.cos(rot), math.sin(rot)
	setVertex(quad[1], cx, cy, c, s, -hw, -hh, 0, 0)
	setVertex(quad[2], cx, cy, c, s, hw, -hh, u1, 0)
	setVertex(quad[3], cx, cy, c, s, hw, hh, u1, v1)
	setVertex(quad[4], cx, cy, c, s, -hw, hh, 0, v1)
	surface.DrawPoly(quad)
end

--[[
	Вихревой блюр: слои кадра с растущим масштабом, поворотом и вытягиванием.
	Без закрутки это обычный радиальный зум-блюр; с закруткой картинка
	размазывается в спираль и тянется в нити — спагеттификация. Альфа 1/(i+1)
	даёт равновесное среднее слоёв и задаётся цветом вершин, поэтому корректна и
	при многопоточном рендере (mat_queue_mode).
]]
local function drawSwirl(strength, twist, stretch)
	render.UpdateScreenEffectTexture()
	local tex = render.GetScreenEffectTexture()
	matFrame:SetTexture("$basetexture", tex)

	local w, h = ScrW(), ScrH()
	local u1 = math.min(w / tex:Width(), 1)
	local v1 = math.min(h / tex:Height(), 1)
	local cx, cy = w * 0.5, h * 0.5

	cam.Start2D()
	surface.SetMaterial(matFrame)
	for i = 1, BLUR_LAYERS do
		local k = i / BLUR_LAYERS
		local sx = 1 + strength * k
		local sy = 1 + strength * k * (1 + stretch)
		surface.SetDrawColor(255, 255, 255, 255 / (i + 1))
		drawFrameQuad(cx, cy, w * 0.5 * sx, h * 0.5 * sy, twist * k * 0.5, u1, v1)
	end
	cam.End2D()
end

hook.Add("RenderScreenspaceEffects", "MS_PortalBlur", function()
	if V.Blur < 0.002 then return end

	-- Ярче и сочнее, с лёгким фиолетовым — без мрачного обесцвечивания.
	local k = math.min(V.Blur / BLUR_OUT, 1)
	colorMod["$pp_colour_colour"] = 1 + 0.35 * k
	colorMod["$pp_colour_contrast"] = 1 + 0.08 * k
	colorMod["$pp_colour_brightness"] = 0.02 * k
	colorMod["$pp_colour_addb"] = 0.05 * k
	colorMod["$pp_colour_addr"] = 0.03 * k
	DrawColorModify(colorMod)

	drawSwirl(V.Blur, V.Twist, V.Stretch)
end)

--------------------------------------------------------------------------------
-- Чёрный оверлей (поверх всего, включая VGUI)
--------------------------------------------------------------------------------

hook.Add("DrawOverlay", "MS_PortalBlack", function()
	if V.Alpha < 1 then return end
	surface.SetDrawColor(0, 0, 0, V.Alpha)
	surface.DrawRect(0, 0, ScrW(), ScrH())
end)

--------------------------------------------------------------------------------
-- Статус подготовки
--------------------------------------------------------------------------------

surface.CreateFont("MS_Status", { font = "Roboto", size = 20, weight = 600, antialias = true, extended = true })

-- Строка статуса подготовки — отладочная: только при ms_cl_debug (ключи фраз — sh_lang).
local PHASE_LABEL = {
	[MS.Phase.DISCOVER] = "hud_discover",
	[MS.Phase.DOWNLOAD] = "hud_download",
	[MS.Phase.MOUNT]    = "hud_mount",
	[MS.Phase.PRECACHE] = "hud_precache",
	[MS.Phase.SYNC]     = "hud_sync",
	[MS.Phase.READY]    = "hud_ready",
}

V.Phase = V.Phase or MS.Phase.IDLE

net.Receive(MS.Net.Phase, function()
	local phase = net.ReadUInt(4)
	local text = net.ReadString()
	local prog = net.ReadFloat()
	if phase ~= V.Phase then V.PhaseTime = RealTime() end
	V.Phase, V.PhaseText, V.PhaseProgress = phase, text, prog
end)

local COL_TEXT = Color(225, 215, 255, 235)
local COL_SHADOW = Color(0, 0, 0, 200)

hook.Add("HUDPaint", "MS_PhaseStatus", function()
	if not MS.CVars.Debug:GetBool() or V.Alpha > 0 then return end

	local label = PHASE_LABEL[V.Phase]
	if not label then return end
	label = MS.T(label)
	if V.Phase == MS.Phase.READY and RealTime() - (V.PhaseTime or 0) > 8 then return end

	local line = label
	if V.PhaseText and V.PhaseText ~= "" and V.Phase ~= MS.Phase.DISCOVER then
		line = line .. " — " .. V.PhaseText
	end

	local prog = V.PhaseProgress or -1
	if V.Phase == MS.Phase.SYNC and MS.Prefetch and MS.Prefetch.Progress then prog = MS.Prefetch.Progress end
	if prog >= 0 and V.Phase ~= MS.Phase.READY then
		line = string.format("%s (%d%%)", line, math.floor(prog * 100))
	end

	local x, y = ScrW() * 0.5, ScrH() - 140
	draw.SimpleText(line, "MS_Status", x + 1, y + 1, COL_SHADOW, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	draw.SimpleText(line, "MS_Status", x, y, COL_TEXT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end)
