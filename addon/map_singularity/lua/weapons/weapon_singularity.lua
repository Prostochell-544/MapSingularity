--[[
	MapSingularity — КПП «Лунь» (Комплекс Просторового Переходу).

	ЛКМ — открыть портал туда, куда смотришь (если карта ещё не готова — портал
	      появится нестабильным и сам стабилизируется, когда карта догрузится);
	ПКМ — перебросить рулетку: новая случайная карта, портал остаётся на месте;
	R   — схлопнуть портал (готовая карта не теряется, следующий выстрел вернёт его).

	Модель: models/map_singularity/kpp_lun.mdl (собирается tools/model/*). Руки и анимации
	берутся у гравипушки c_physcannon: её меш скрывается, а «Лунь» рисуется в правой руке
	(подгонка — ползунки в Q → «Утилиты» → MapSingularity → «Подгонка Луня»). Без модели —
	затычка-пистолет HL2. Экран прибора рисуется на точке крепления "screen" модели.
]]

AddCSLuaFile()

local LUN_MODEL = "models/map_singularity/kpp_lun.mdl"
local HAS_LUN = file.Exists(LUN_MODEL, "GAME")

-- Тексты — на языке клиента (sh_lang); на сервере не показываются.
SWEP.PrintName = MapSingularity.T("gun_name")
SWEP.Author = "НДІ Проектування / MapSingularity"
SWEP.Category = "MapSingularity"
SWEP.Purpose = MapSingularity.T("gun_purpose")
SWEP.Instructions = MapSingularity.T("gun_instructions")

SWEP.Spawnable = true
SWEP.AdminOnly = true

SWEP.ViewModel = HAS_LUN and "models/weapons/c_physcannon.mdl" or "models/weapons/c_pistol.mdl"
SWEP.WorldModel = HAS_LUN and LUN_MODEL or "models/weapons/w_pistol.mdl"
-- Руки гравипушки к «Луню» не подходят (и их подменяют аддоны) — пока модель без рук.
SWEP.UseHands = not HAS_LUN
SWEP.ViewModelFOV = HAS_LUN and 54 or 62
SWEP.HoldTypeName = HAS_LUN and "physgun" or "pistol"

-- Физическая ширина стекла экрана в единицах модели (из ТЗ) — для масштаба 3D2D.
SWEP.ScreenWidth = 4.5

SWEP.Slot = 1
SWEP.SlotPos = 6
SWEP.DrawAmmo = false
SWEP.DrawCrosshair = true

SWEP.Primary.ClipSize = -1
SWEP.Primary.DefaultClip = -1
SWEP.Primary.Automatic = false
SWEP.Primary.Ammo = "none"

SWEP.Secondary.ClipSize = -1
SWEP.Secondary.DefaultClip = -1
SWEP.Secondary.Automatic = false
SWEP.Secondary.Ammo = "none"

local SND_FIRE     = "weapons/physcannon/superphys_launch1.wav"
local SND_REROLL   = "weapons/physcannon/physcannon_charge.wav"
local SND_COLLAPSE = "ambient/levels/labs/teleport_winddown1.wav"

function SWEP:Initialize()
	self:SetHoldType(self.HoldTypeName)
end

function SWEP:PrimaryAttack()
	self:SetNextPrimaryFire(CurTime() + 0.8)

	local owner = self:GetOwner()
	if not IsValid(owner) then return end

	local tr = owner:GetEyeTrace()
	self:SendWeaponAnim(ACT_VM_PRIMARYATTACK)
	owner:SetAnimation(PLAYER_ATTACK1)
	self:EmitSound(SND_FIRE, 75, 135, 0.6)

	if IsFirstTimePredicted() then
		local fx = EffectData()
		fx:SetStart(owner:GetShootPos())
		fx:SetOrigin(tr.HitPos)
		fx:SetEntity(self)
		util.Effect("ms_singularity_shot", fx)
	end
	self:KickViewModel(1)

	if SERVER then MapSingularity.Director.GunPlace(owner, tr) end
end

-- Отдача модели «Луня» у стрелка: в мультиплеере — из предсказания на клиенте,
-- в одиночной игре атака идёт только на сервере, поэтому он зовёт клиента сам.
function SWEP:KickViewModel(power)
	if CLIENT then
		if IsFirstTimePredicted() and self.LunKick then self:LunKick(power) end
	elseif game.SinglePlayer() then
		self:CallOnClient("LunKick", tostring(power))
	end
end

function SWEP:SecondaryAttack()
	self:SetNextSecondaryFire(CurTime() + 1.5)

	local owner = self:GetOwner()
	if not IsValid(owner) then return end

	self:SendWeaponAnim(ACT_VM_SECONDARYATTACK)
	self:EmitSound(SND_REROLL, 70, 120, 0.6)
	self:KickViewModel(0.4)

	if SERVER then MapSingularity.Director.GunReroll(owner) end
end

function SWEP:Reload()
	if (self.NextCollapse or 0) > CurTime() then return end
	self.NextCollapse = CurTime() + 1

	local owner = self:GetOwner()
	if not IsValid(owner) then return end

	if SERVER then
		if MapSingularity.Director.GunCollapse(owner) then
			self:SendWeaponAnim(ACT_VM_RELOAD)
			owner:EmitSound(SND_COLLAPSE, 60, 120, 0.5)
			self:CallOnClient("LunClench", "") -- когти сжимаются у стрелка
		end
	end
end

if SERVER then return end

--------------------------------------------------------------------------------
-- Экран прибора
--------------------------------------------------------------------------------

local MS = MapSingularity
local PH = MS.Phase

surface.CreateFont("MS_LunSmall", { font = "Consolas", size = 15, weight = 700, antialias = true, extended = true })
-- Терминал: моноширинный шрифт и его «люминофорное» свечение (размытая копия поверх).
surface.CreateFont("MS_LunTerm",     { font = "Consolas", size = 15, weight = 700, antialias = true, extended = true })
surface.CreateFont("MS_LunTermGlow", { font = "Consolas", size = 15, weight = 700, antialias = true, extended = true, blursize = 4, additive = true })

-- Логический размер экрана в HUD; на модели ширина та же, высота — по пропорциям стекла.
local SCREEN_W, SCREEN_H = 300, 150

-- Зелёный люминофор старого терминала.
local COL_BEZEL    = Color(14, 15, 13, 250)
local COL_GLASS    = Color(3, 12, 5, 250)
local COL_PHOSPHOR = Color(95, 255, 135)
local COL_DIM      = Color(45, 150, 75)
local COL_FAINT    = Color(20, 70, 35)
local COL_SCAN     = Color(0, 0, 0, 70)
local MAT_GRAD_L, MAT_GRAD_R = Material("vgui/gradient-l"), Material("vgui/gradient-r")
local MAT_GRAD_U, MAT_GRAD_D = Material("vgui/gradient-u"), Material("vgui/gradient-d")

-- Фаза: ключ названия (sh_lang), цвет энергии, амплитуда и частота осциллограммы.
local STATE = {
	[PH.IDLE]     = { "st_idle",     Color(255, 190, 70),  0.15, 1.0 },
	[PH.DISCOVER] = { "st_discover", Color(90, 220, 255),  0.45, 3.0 },
	[PH.DOWNLOAD] = { "st_download", Color(90, 220, 255),  0.55, 4.0 },
	[PH.MOUNT]    = { "st_mount",    Color(90, 220, 255),  0.55, 4.0 },
	[PH.PRECACHE] = { "st_precache", Color(90, 220, 255),  0.60, 5.0 },
	[PH.SYNC]     = { "st_sync",     Color(90, 220, 255),  0.50, 3.5 },
	[PH.READY]    = { "st_ready",    Color(110, 255, 150), 0.80, 2.0 },
	[PH.TRANSIT]  = { "st_transit",  Color(255, 110, 230), 1.00, 9.0 },
}

local BOOT = { "boot1", "boot2", "boot3", "boot4", "boot5" }
local BOOT_TIME = 1.4

-- Обрезка по ширине с уважением к UTF-8 (кириллица — по два байта).
local function fitText(text, font, maxW)
	surface.SetFont(font)
	if surface.GetTextSize(text) <= maxW then return text end
	while #text > 0 do
		local cut = #text
		repeat cut = cut - 1 until cut <= 0 or (string.byte(text, cut + 1) or 0) < 0x80 or (string.byte(text, cut + 1) or 0) >= 0xC0
		text = string.sub(text, 1, math.max(0, cut))
		if surface.GetTextSize(text .. "…") <= maxW then return text .. "…" end
	end
	return ""
end

-- Строка люминофором: размытое свечение под чёткими буквами; inverse — светлая плашка, тёмный текст.
local function termText(text, x, y, col, inverse, flicker)
	surface.SetFont("MS_LunTerm")
	local tw, th = surface.GetTextSize(text)
	if inverse then
		surface.SetDrawColor(ColorAlpha(col, 230 * flicker))
		surface.DrawRect(x - 2, y - 1, tw + 4, th + 1)
		draw.SimpleText(text, "MS_LunTerm", x, y, COL_GLASS)
		return tw
	end
	draw.SimpleText(text, "MS_LunTermGlow", x, y, ColorAlpha(col, 140 * flicker))
	draw.SimpleText(text, "MS_LunTerm", x, y, ColorAlpha(col, 255 * flicker))
	return tw
end

-- Полоса прогресса символами: [████████░░░░░░] 52%
local function termBar(frac, cells)
	local full = math.floor(math.Clamp(frac, 0, 1) * cells + 0.5)
	return "[" .. string.rep("█", full) .. string.rep("░", cells - full) .. "]"
end

-- Осциллограмма точками люминофора; амплитуда и частота — от фазы, в работе — с шумом.
local function drawScope(x, y, w, h, amp, freq, noisy, flicker)
	local t = RealTime()
	local mid = y + h * 0.5
	surface.SetDrawColor(ColorAlpha(COL_FAINT, 255 * flicker))
	for gx = x, x + w, 6 do surface.DrawRect(gx, mid, 1, 1) end
	for i = 0, 74 do
		local k = i / 74
		local wave = math.sin(k * math.pi * 2 * freq + t * 6) * amp
		if noisy then wave = wave + (math.sin(k * 97 + t * 31) * 0.35 + math.sin(k * 53 - t * 17) * 0.25) * amp end
		local px, py = x + w * k, mid - wave * h * 0.45
		surface.SetDrawColor(ColorAlpha(COL_PHOSPHOR, 70 * flicker))
		surface.DrawRect(px - 1, py - 1, 4, 4)
		surface.SetDrawColor(ColorAlpha(COL_PHOSPHOR, 255 * flicker))
		surface.DrawRect(px, py, 2, 2)
	end
end

-- Кинескоп: строки развёртки, бегущая полоса обновления кадра, тёмные края.
local function drawCRT(x, y, w, h)
	surface.SetDrawColor(COL_SCAN)
	for sy = y, y + h, 2 do surface.DrawRect(x, sy, w, 1) end
	local band = (RealTime() * 0.35 % 1.2 - 0.1) * h
	surface.SetDrawColor(ColorAlpha(COL_PHOSPHOR, 10))
	surface.DrawRect(x, y + math.Clamp(band, 0, h - 14), w, 14)
	local e = math.floor(math.min(w, h) * 0.16)
	surface.SetDrawColor(0, 0, 0, 150)
	surface.SetMaterial(MAT_GRAD_L) surface.DrawTexturedRect(x, y, e, h)
	surface.SetMaterial(MAT_GRAD_R) surface.DrawTexturedRect(x + w - e, y, e, h)
	surface.SetMaterial(MAT_GRAD_U) surface.DrawTexturedRect(x, y, w, e)
	surface.SetMaterial(MAT_GRAD_D) surface.DrawTexturedRect(x, y + h - e, w, e)
end

--[[
	Рисует экран «Луня» в прямоугольнике x, y, w, h (работает и в 2D, и в 3D2D) — старый
	терминал НДІ: зелёный люминофор, моноширинный шрифт, инверсная шапка, строки с «>»,
	полоса прогресса символами, точечная осциллограмма, мигающий блочный курсор.
	boot — 0..1, прогресс загрузки при доставании (строки «самотестирования» по очереди).
]]
function MS.DrawLunScreen(x, y, w, h, boot)
	local V = MS.Visuals or {}
	local phase = V.Phase or PH.IDLE
	local st = STATE[phase] or STATE[PH.IDLE]
	local now = RealTime()
	-- Люминофор чуть мерцает, изредка «проседает» питание.
	local flicker = 0.93 + 0.05 * math.sin(now * 53) + (math.sin(now * 3.7) > 0.985 and -0.25 or 0)
	local blink = math.floor(now * 2.5) % 2 == 0

	draw.RoundedBox(10, x, y, w, h, COL_BEZEL)
	draw.RoundedBox(8, x + 4, y + 4, w - 8, h - 8, COL_GLASS)
	local ix, iy, iw = x + 12, y + 9, w - 24
	local lh = 17

	if boot < 1 then
		local shown = math.floor(boot * (#BOOT + 1))
		for i = 1, math.min(shown, #BOOT) do
			termText(MS.T(BOOT[i]), ix, iy + (i - 1) * lh, i == 1 and COL_PHOSPHOR or COL_DIM, false, flicker)
		end
		if blink then termText("█", ix, iy + math.min(shown, #BOOT) * lh, COL_PHOSPHOR, false, flicker) end
	else
		termText(MS.T("term_header"), ix, iy, COL_PHOSPHOR, true, flicker)

		local status = MS.T("term_state") .. MS.T(st[1])
		if phase == PH.TRANSIT then
			termText(status, ix, iy + lh + 3, COL_PHOSPHOR, blink, flicker)
		else
			termText(status, ix, iy + lh + 3, COL_PHOSPHOR, false, flicker)
		end

		local line
		if phase == PH.READY and V.PhaseText and V.PhaseText ~= "" then
			line = MS.T("term_target") .. V.PhaseText
		elseif V.PhaseText and V.PhaseText ~= "" and phase ~= PH.IDLE then
			line = "> " .. V.PhaseText
		else
			line = MS.T("term_idle")
		end
		termText(fitText(line, "MS_LunTerm", iw), ix, iy + lh * 2 + 3, COL_DIM, false, flicker)

		if V.PhaseProgress and V.PhaseProgress >= 0 and phase ~= PH.READY and phase ~= PH.IDLE then
			termText(termBar(V.PhaseProgress, 14) .. string.format(" %3d%%", math.floor(V.PhaseProgress * 100)),
				ix, iy + lh * 3 + 3, COL_PHOSPHOR, false, flicker)
		end

		local scopeY = iy + lh * 4 + 8
		local noisy = phase ~= PH.READY and phase ~= PH.IDLE
		drawScope(ix, scopeY, iw, math.max(10, y + h - 26 - scopeY), st[3], st[4], noisy, flicker)

		if blink then termText(">█", ix, y + h - 9 - lh, COL_PHOSPHOR, false, flicker) end
	end

	drawCRT(x + 4, y + 4, w - 8, h - 8)
end

-- Загрузочная последовательность при каждом доставании (Deploy в одиночной игре
-- на клиенте не вызывается, поэтому ловим смену оружия здесь).
local lastSeen, lastSeenTime, bootStart = nil, 0, 0
local function bootProgress(wep)
	local now = RealTime()
	if lastSeen ~= wep or now - lastSeenTime > 0.5 then bootStart = now end
	lastSeen, lastSeenTime = wep, now
	return math.Clamp((now - bootStart) / BOOT_TIME, 0, 1)
end

--[[
	Стекло экрана на модели: точка крепления "screen" — левый верхний угол (оси: вперёд —
	вправо по стеклу, Right — вниз по стеклу, Up — к стрелку), "screen_br" — правый нижний.
	Размер берётся из расстояния между ними, поэтому масштаб модели учитывается сам.
	У старой сборки модели второй точки нет — тогда ширина SWEP.ScreenWidth и пропорция 2:1.
]]
local function screenRect(ent, weapon)
	local id = ent:LookupAttachment("screen")
	if not id or id <= 0 then return nil end
	local tl = ent:GetAttachment(id)
	if not tl then return nil end

	local w, h
	local brId = ent:LookupAttachment("screen_br")
	local br = brId and brId > 0 and ent:GetAttachment(brId)
	if br then
		local d = br.Pos - tl.Pos
		w, h = d:Dot(tl.Ang:Forward()), d:Dot(tl.Ang:Right())
	else
		w = weapon.ScreenWidth * ent:GetModelScale()
		h = w * 0.5
	end
	if w < 0.5 or h < 0.25 then return nil end
	return tl.Pos, tl.Ang, w, h
end

local function screenOnAttachment(ent, weapon)
	local pos, ang, w, h = screenRect(ent, weapon)
	if not pos then return false end

	local scale = w / SCREEN_W
	cam.Start3D2D(pos, ang, scale)
	MS.DrawLunScreen(0, 0, SCREEN_W, math.floor(h / scale), bootProgress(weapon))
	cam.End3D2D()
	return true
end

--------------------------------------------------------------------------------
-- Модель «Луня» в кадре и в руках; подгонка — клиентские конвары
--------------------------------------------------------------------------------

local ANCHOR_BONE = "ValveBiped.Bip01_R_Hand"

--[[
	От первого лица «Лунь» ставится от камеры вьюмодели, как классическое оружие Source:
	vm:GetPos() / vm:GetAngles() — точка взгляда вместе с покачиванием при ходьбе и
	запаздыванием при поворотах. От костей вьюмодели не зависит ничего: c_physcannon
	подменяют аддоны мастерской, у подменённой модели нет костей Base/Handle, а кисть
	висит за кадром (проверено у пользователя 2026-11-18).
	Подгонка vm: x вперёд, y вправо, z вверх — начало модели (верх рукояти) от глаза;
	p — тангаж (плюс — ствол вверх), yw — рыскание (плюс — влево), r — крен, s — масштаб.
	Значения по умолчанию — подгонка пользователя в игре (2026-11-18): повороты и масштаб
	как есть, x/y/z подобраны под процедурную модель так, чтобы экран и шар легли в кадре
	туда же (tools/model/preview_viewmodel.py, экран 77–96 % по ширине, шар — 71 %).

	Мировая модель: от правой кисти игрока, поворот по прицелу; середина рукояти —
	в 4 юнитах позади и 3 ниже начала модели (в игре не проверялось).
]]
MS.LunTunePrefix = "ms_lunk_"
MS.LunTune = MS.LunTune or {}
local TUNE_DEFAULTS = {
	vm = { x = 22.26, y = 8.25, z = -4.91, p = 5.1, yw = 1.7, r = 1.7, s = 0.9 },
	wm = { x = 4, y = 0, z = 3, p = 0, yw = 0, r = 0, s = 1 },
}
-- Номер набора значений по умолчанию. Поднимается при смене модели: сохранённая в конфиге
-- подгонка старой модели к новой не подходит и один раз сбрасывается к новым значениям.
local TUNE_VERSION = 2
for kind, values in pairs(TUNE_DEFAULTS) do
	MS.LunTune[kind] = MS.LunTune[kind] or {}
	for key, def in pairs(values) do
		MS.LunTune[kind][key] = CreateClientConVar(MS.LunTunePrefix .. kind .. "_" .. key, tostring(def), true, false)
	end
end
MS.LunTuneDefaults = TUNE_DEFAULTS

local tuneVersion = CreateClientConVar(MS.LunTunePrefix .. "version", "0", true, false)
if tuneVersion:GetInt() < TUNE_VERSION then
	for kind, values in pairs(TUNE_DEFAULTS) do
		for key, def in pairs(values) do
			RunConsoleCommand(MS.LunTunePrefix .. kind .. "_" .. key, tostring(def))
		end
	end
	RunConsoleCommand(MS.LunTunePrefix .. "version", tostring(TUNE_VERSION))
	MS.Log("подгонка КПП «Лунь» сброшена к значениям для новой модели (набор %d)", TUNE_VERSION)
end

--[[
	Смещение и повороты подгонки t в осях baseAng (вперёд / вправо / вверх).
	ex, ez, ep — добавки процедурной анимации: вперёд, вверх, тангаж.
	Порядок поворотов — рыскание, тангаж, крен вокруг уже повёрнутых осей
	(так же считает tools/model/preview_viewmodel.py); fix — доворот самой модели (см. modelYaw).
]]
local function offsetFrame(origin, baseAng, t, ex, ez, ep, fix)
	local ang = Angle(baseAng.p, baseAng.y, baseAng.r)
	local pos = origin + ang:Forward() * (t.x:GetFloat() + ex) + ang:Right() * t.y:GetFloat() + ang:Up() * (t.z:GetFloat() + ez)
	ang:RotateAroundAxis(ang:Up(), t.yw:GetFloat())
	ang:RotateAroundAxis(ang:Right(), t.p:GetFloat() + ep)
	ang:RotateAroundAxis(ang:Forward(), t.r:GetFloat())
	if fix ~= 0 then ang:RotateAroundAxis(ang:Up(), fix) end
	return pos, ang
end

--[[
	Сборки модели до 2026-11-18 (QC без $origin) studiomdl повернул на +90° вокруг Z —
	ствол там идёт по +Y. Игра держит модель в памяти до перезапуска, поэтому сборку
	узнаём по габаритам и доворачиваем: подгонка одинакова для старой и новой.
]]
local modelYawCache = {}
local function modelYaw(ent)
	local mdl = ent:GetModel()
	if not mdl then return 0 end
	local fix = modelYawCache[mdl]
	if fix == nil then
		local mins, maxs = ent:GetModelBounds()
		fix = (mins and maxs and (maxs.y - mins.y) > 1.5 * (maxs.x - mins.x)) and -90 or 0
		modelYawCache[mdl] = fix
	end
	return fix
end

-- Мировая модель: от правой кисти, оси — прицел игрока без крена.
local function worldTransform(ply, wep)
	local bone = ply:LookupBone(ANCHOR_BONE)
	if not bone then return nil end
	local m = ply:GetBoneMatrix(bone)
	if not m then return nil end
	local aim = ply:EyeAngles()
	return offsetFrame(m:GetTranslation(), Angle(aim.p, aim.y, 0), MS.LunTune.wm, 0, 0, 0, modelYaw(wep))
end

--[[
	Точка из кадра вьюмодели (у него своя FOV) -> точка мира, которая на экране там же,
	как FormatViewModelAttachment в движке: поперечные смещения от глаза растягиваются
	в tan(FOV мира / 2) / tan(FOV вьюмодели / 2) раз. Нужна лучу выстрела.
]]
local function viewToWorld(pos)
	local vs = render.GetViewSetup and render.GetViewSetup()
	if not vs then return pos end
	local worldFov, vmFov = vs.fov_unscaled, vs.fovviewmodel_unscaled
	if not (worldFov and vmFov) then worldFov, vmFov = vs.fov, vs.fovviewmodel end
	if not (worldFov and vmFov) or vmFov <= 1 then return pos end

	local k = math.tan(math.rad(worldFov * 0.5)) / math.tan(math.rad(vmFov * 0.5))
	local eye, ang = vs.origin or EyePos(), vs.angles or EyeAngles()
	local d = pos - eye
	local f, r, u = ang:Forward(), ang:Right(), ang:Up()
	return eye + f * d:Dot(f) + r * (d:Dot(r) * k) + u * (d:Dot(u) * k)
end

local function muzzleOf(ent)
	local id = ent:LookupAttachment("muzzle")
	local att = id and id > 0 and ent:GetAttachment(id)
	return att and att.Pos
end

--[[
	Процедурная анимация вместо секвенций (своих анимаций у модели пока нет):
	  доставание — 0,45 с выезд снизу стволом вниз, со сглаживанием;
	  отдача     — рывок назад и стволом вверх, затухает за 0,3 с;
	  дыхание    — едва заметное покачивание по высоте.
]]
local DRAW_TIME = 0.45
local KICK_TIME = 0.3

-- Вызывается в предсказании выстрела, а в одиночной игре — с сервера (CallOnClient).
function SWEP:LunKick(power)
	self.LunKickTime = RealTime()
	self.LunKickPower = math.Clamp(tonumber(power) or 1, 0, 2)
end

-- Схлопывание портала (R): сервер зовёт клиента после успешного схлопывания.
function SWEP:LunClench()
	self.LunClenchTime = RealTime()
end

-- Затухающий импульс: 1 в момент t0, 0 через duration секунд.
local function pulse(t0, duration)
	if not t0 then return 0 end
	local k = 1 - (RealTime() - t0) / duration
	return k > 0 and k or 0
end

local function kickAmount(wep)
	local k = pulse(wep.LunKickTime, KICK_TIME)
	return k * k * (wep.LunKickPower or 1)
end

local function animOffsets(wep)
	local elapsed = bootProgress(wep) * BOOT_TIME -- заодно отмечает момент доставания
	local draw = math.Clamp(elapsed / DRAW_TIME, 0, 1)
	local lift = 1 - draw * draw * (3 - 2 * draw)
	local kick = kickAmount(wep)
	local breathe = math.sin(RealTime() * 1.7) * 0.12
	return -kick * 2.5, breathe - lift * 10, kick * 6 - lift * 25
end

--[[
	Подвижные части «Луня» — кости модели, крутятся каждый кадр через ManipulateBoneAngles
	(у костей нулевой поворот, так что их оси — оси модели):
	  когти   — вокруг оси шарнира: «дышат», раскрываются на выстреле, сжимаются на R,
	            приоткрыты в готовности и распахнуты при прыжке;
	  ротор   — кость lun_generator вокруг оси ствола, скорость по фазе режиссёра;
	  стрелка — прибор «напруженість поля»: прогресс фазы, у готовности дрожит у красной зоны.
	Шкала прибора — 270° от 225° (0) до -45° (10) в осях циферблата; стрелка в модели смотрит вверх.
]]
local CLAW_AXES = {}
for k = 1, 3 do
	local a = math.rad(90 + 120 * (k - 1))
	CLAW_AXES[k] = Vector(0, -math.sin(a), math.cos(a)) -- ось шарнира; плюс — коготь наружу
end
local SPIN = {
	[PH.IDLE] = 40, [PH.DISCOVER] = 200, [PH.DOWNLOAD] = 260, [PH.MOUNT] = 300,
	[PH.PRECACHE] = 340, [PH.SYNC] = 420, [PH.READY] = 620, [PH.TRANSIT] = 1500,
}
local POWER = {
	[PH.IDLE] = 0.35, [PH.DISCOVER] = 0.55, [PH.DOWNLOAD] = 0.6, [PH.MOUNT] = 0.65,
	[PH.PRECACHE] = 0.7, [PH.SYNC] = 0.75, [PH.READY] = 0.95, [PH.TRANSIT] = 1.3,
}

local function axisAngle(axis, deg)
	local a = Angle(0, 0, 0)
	a:RotateAroundAxis(axis, deg)
	return a
end

local function animateBones(ent, wep)
	local V = MS.Visuals or {}
	local phase = V.Phase or PH.IDLE
	local now = RealTime()

	-- Состояние считается раз за кадр (мировая и вьюмодель могут рисоваться в одном кадре).
	if wep.LunAnimFrame ~= FrameNumber() then
		wep.LunAnimFrame = FrameNumber()
		local dt = math.min(FrameTime(), 0.1)

		local open = 2 + math.sin(now * 1.3) * 1.5
		if phase == PH.READY then open = open + 8 elseif phase == PH.TRANSIT then open = open + 20 end
		open = open + 28 * kickAmount(wep) - 16 * math.sin(pulse(wep.LunClenchTime, 0.8) * math.pi)
		wep.LunOpen = Lerp(math.min(dt * 14, 1), wep.LunOpen or open, open)

		wep.LunSpinRate = Lerp(math.min(dt * 1.5, 1), wep.LunSpinRate or 40, SPIN[phase] or 40)
		wep.LunSpin = ((wep.LunSpin or 0) + wep.LunSpinRate * dt) % 360

		local needle = 0.08 + math.sin(now * 0.7) * 0.02
		if V.PhaseProgress and V.PhaseProgress >= 0 and phase ~= PH.IDLE then needle = 0.2 + 0.55 * V.PhaseProgress end
		if phase == PH.READY then
			needle = 0.82 + math.sin(now * 9) * 0.015
		elseif phase == PH.TRANSIT then
			needle = 0.97 + math.Rand(-0.03, 0.03)
		end
		wep.LunNeedle = Lerp(math.min(dt * 4, 1), wep.LunNeedle or 0, needle)
	end

	for k = 1, 3 do
		local id = ent:LookupBone("lun_claw_" .. k)
		if id then ent:ManipulateBoneAngles(id, axisAngle(CLAW_AXES[k], wep.LunOpen + math.sin(now * 7 + k * 2) * 0.4)) end
	end
	local gen = ent:LookupBone("lun_generator")
	if gen then ent:ManipulateBoneAngles(gen, Angle(0, 0, wep.LunSpin)) end
	local needleBone = ent:LookupBone("lun_needle")
	if needleBone then ent:ManipulateBoneAngles(needleBone, axisAngle(Vector(0, 1, 0), 135 - 270 * wep.LunNeedle)) end
end

--[[
	Энергия, как у гравипушки, — кодом: сияние шара между когтями (вместо «шарика» модели),
	молнии от кончиков когтей к шару (чаще при большей мощности фазы, залпом при выстреле),
	свечение ядра бака — спрайт в центре бака, виден только через окна (проверка глубины).
	Цвет — цвет текущей фазы на экране прибора.
]]
local MAT_GLOW = Material("sprites/light_glow02_add")
local MAT_BEAM = Material("sprites/physbeama")
local COL_CORE = Color(255, 150, 60)

local function jaggedBeam(a, b, col, scale)
	local segs = 6
	render.StartBeam(segs + 1)
	for i = 0, segs do
		local t = i / segs
		local p = LerpVector(t, a, b)
		if i > 0 and i < segs then p = p + VectorRand() * 0.4 * scale end
		render.AddBeam(p, (0.45 + math.random() * 0.4) * scale, t * 2, col)
	end
	render.EndBeam()
end

local function drawEnergy(ent, wep, scale)
	local V = MS.Visuals or {}
	local phase = V.Phase or PH.IDLE
	local col = (STATE[phase] or STATE[PH.IDLE])[2]
	local power = POWER[phase] or 0.5
	local kick = kickAmount(wep)
	local now = RealTime()

	local muzzle = muzzleOf(ent)
	if muzzle then
		local s = (5 + 1.5 * math.sin(now * 5) + 9 * kick) * (0.5 + power) * scale
		render.SetMaterial(MAT_GLOW)
		render.DrawSprite(muzzle, s * 2.4, s * 2.4, ColorAlpha(col, 110))
		render.DrawSprite(muzzle, s, s, Color(255, 255, 255, 220))

		render.SetMaterial(MAT_BEAM)
		for k = 1, 3 do
			if math.random() < 0.3 * power + kick then
				local id = ent:LookupAttachment("claw" .. k .. "_tip")
				local att = id and id > 0 and ent:GetAttachment(id)
				if att then jaggedBeam(att.Pos, muzzle, col, scale) end
			end
		end
	end

	local gid = ent:LookupAttachment("generator")
	local core = gid and gid > 0 and ent:GetAttachment(gid)
	if core then
		local s = (7 + 1.5 * math.sin(now * 3.1) + math.Rand(0, 1.5 * power)) * (0.6 + power) * scale
		render.SetMaterial(MAT_GLOW)
		render.DrawSprite(core.Pos, s * 2, s * 2, ColorAlpha(COL_CORE, 70 + 60 * power))
		render.DrawSprite(core.Pos, s, s, ColorAlpha(col, 120))
	end
end

local function viewTransform(wep, vm, cs)
	local ex, ez, ep = animOffsets(wep)
	local pos, ang = offsetFrame(vm:GetPos(), vm:GetAngles(), MS.LunTune.vm, ex, ez, ep, modelYaw(cs))
	return pos, ang, math.Clamp(MS.LunTune.vm.s:GetFloat(), 0.2, 3)
end

function SWEP:LunViewModel()
	if not IsValid(self.LunCS) then
		self.LunCS = ClientsideModel(LUN_MODEL, RENDERGROUP_VIEWMODEL)
		if IsValid(self.LunCS) then self.LunCS:SetNoDraw(true) end
	end
	return self.LunCS
end

-- Вьюмодель (гравипушка) нужна только как носитель кадра: прячем её прозрачностью.
-- Вернуть true нельзя — тогда не вызовется PostDrawViewModel.
function SWEP:PreDrawViewModel(vm)
	if HAS_LUN then render.SetBlend(0) end
end

function SWEP:PostDrawViewModel(vm)
	render.SetBlend(1)

	if HAS_LUN then
		local cs = self:LunViewModel()
		if IsValid(cs) then
			local pos, ang, scale = viewTransform(self, vm, cs)
			cs:SetModelScale(scale, 0)
			cs:SetPos(pos)
			cs:SetAngles(ang)
			animateBones(cs, self)
			cs:SetupBones()
			cs:DrawModel()
			drawEnergy(cs, self, scale)
			self.ScreenOnModel = screenOnAttachment(cs, self)

			local muzzle = muzzleOf(cs)
			if muzzle then self.LunMuzzleView = { pos = viewToWorld(muzzle), t = RealTime() } end
			-- Для диагностики — относительно камеры вьюмодели.
			self.LunLast = { pos = pos, scale = scale, cs = cs, muzzle = muzzle, eye = vm:GetPos(), view = vm:GetAngles() }
			return
		end
	end

	self.ScreenOnModel = screenOnAttachment(vm, self)
end

function SWEP:DrawWorldModel()
	local owner = self:GetOwner()
	if HAS_LUN and IsValid(owner) then
		local pos, ang = worldTransform(owner, self)
		if pos then
			self:SetModelScale(math.Clamp(MS.LunTune.wm.s:GetFloat(), 0.2, 3), 0)
			self:SetRenderOrigin(pos)
			self:SetRenderAngles(ang)
			animateBones(self, self)
			self:SetupBones()
			self:DrawModel()
			drawEnergy(self, self, self:GetModelScale())
			if owner ~= LocalPlayer() or owner:ShouldDrawLocalPlayer() then screenOnAttachment(self, self) end
			local muzzle = muzzleOf(self)
			if muzzle then self.LunMuzzleWorld = { pos = muzzle, t = RealTime() } end
			self:SetRenderOrigin()
			self:SetRenderAngles()
			return
		end
	end

	self:DrawModel()
	if owner ~= LocalPlayer() or LocalPlayer():ShouldDrawLocalPlayer() then
		screenOnAttachment(self, self)
	end
end

function SWEP:OnRemove()
	if IsValid(self.LunCS) then self.LunCS:Remove() end
end

-- Диагностика: где модель «Луня» относительно камеры.
concommand.Add("ms_lun_where", function()
	local ply = LocalPlayer()
	local wep = IsValid(ply) and ply:GetActiveWeapon()
	if not (IsValid(wep) and wep:GetClass() == "weapon_singularity") then
		return MS.Log("возьмите КПП «Лунь» в руки (ms_give_gun)")
	end

	local vm = ply:GetViewModel()
	MS.Log("модель в аддоне: %s; вьюмодель-носитель (скрыта): %s; руки: %s", tostring(HAS_LUN),
		IsValid(vm) and vm:GetModel() or "нет", tostring(wep.UseHands))

	local last = wep.LunLast
	if not last or not last.pos then
		return MS.Log("модель ещё ни разу не рисовалась: PostDrawViewModel не вызывался (вид от третьего лица?)")
	end
	local cs = last.cs
	MS.Log("клиентская модель: %s%s", IsValid(cs) and cs:GetModel() or "не создана",
		(IsValid(cs) and cs:GetModel() == "models/error.mdl") and " — ОШИБКА: модель не найдена" or "")

	local eye, view = last.eye, last.view
	local function fromEye(label, p)
		local rel = p - eye
		MS.Log("%s от глаза: вперёд %.1f, вправо %.1f, вверх %.1f", label, rel:Dot(view:Forward()), rel:Dot(view:Right()), rel:Dot(view:Up()))
	end
	local fix = IsValid(cs) and modelYaw(cs) or 0
	MS.Log("привязка: камера вьюмодели, подгонка %svm_*, масштаб %.2f; сборка модели: %s", MS.LunTunePrefix, last.scale or 1,
		fix ~= 0 and "старая (ствол по +Y, доворот -90 — перезапустите игру)" or "новая (ствол по +X)")
	fromEye("верх рукояти", last.pos)
	if last.muzzle then
		fromEye("шар у когтей", last.muzzle)
		local dir = (last.muzzle - last.pos):GetNormalized()
		MS.Log("ствол к взгляду: %.2f (1 — строго вперёд)", dir:Dot(view:Forward()))
	end

	if IsValid(cs) then
		local pos, _, w, h = screenRect(cs, wep)
		if pos then
			local hasBR = (cs:LookupAttachment("screen_br") or 0) > 0
			MS.Log("экран на модели: %.2f x %.2f юнита (%s); от глаза — см. ниже", w, h,
				hasBR and "по точкам screen/screen_br" or "старая сборка: ширина SWEP.ScreenWidth, 2:1")
			fromEye("левый верхний угол экрана", pos)
		else
			MS.Log("экран на модели: точки крепления screen нет — экран в углу HUD")
		end
	end
end, nil, "Диагностика положения модели КПП «Лунь».")

-- Иконка в меню выбора оружия — та же, что в меню спавна (materials/entities, render_icon.py).
local MAT_ICON = Material("entities/weapon_singularity.png", "smooth")

function SWEP:DrawWeaponSelection(x, y, w, h, alpha)
	local size = math.min(w, h) * 0.9
	surface.SetDrawColor(255, 255, 255, alpha)
	surface.SetMaterial(MAT_ICON)
	surface.DrawTexturedRect(x + (w - size) * 0.5, y + (h - size) * 0.5, size, size)
end

local COL_HINT = Color(190, 180, 220, 170)
local COL_SHADOW = Color(0, 0, 0, 200)

function SWEP:DrawHUD()
	local V = MS.Visuals
	if V and V.Alpha > 0 then return end

	-- Пока у модели нет экрана (затычка-пистолет) — экран прибора в углу HUD.
	local x, y = ScrW() - SCREEN_W - 32, ScrH() - SCREEN_H - 150
	if not self.ScreenOnModel then
		MS.DrawLunScreen(x, y, SCREEN_W, SCREEN_H, bootProgress(self))
	end

	local hint = MS.T("gun_hint")
	draw.SimpleText(hint, "MS_LunSmall", x + SCREEN_W * 0.5 + 1, y + SCREEN_H + 15, COL_SHADOW, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	draw.SimpleText(hint, "MS_LunSmall", x + SCREEN_W * 0.5, y + SCREEN_H + 14, COL_HINT, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end
