include("shared.lua")

--[[
	Три вида портала на выбор игрока (ms_cl_portal_style, панель «Настройки»):
	  standard — классический: фиолетовые объёмные обручи в разных плоскостях (гироскоп)
	             и многослойное сияние в центре;
	  fun      — весёлый (ниже подробно): радужный тоннель, диск, падающее вещество;
	  minimal  — минималистичный: чёрная дыра с линзой, фотонным кольцом и маленьким
	             оранжевым диском.

	Весёлая сингулярность — не жуткая:
	  * окно-сфера в центре — проход в другое пространство: через трафарет (stencil)
	    внутри рисуется летящий тоннель с радужными кольцами, звёздами и светом в
	    конце — тот же, что потом на экране загрузки. Тоннель всегда уходит от
	    наблюдателя, поэтому внутри объём с любой стороны;
	  * вокруг — радужный аккреционный диск из лучей в наклонённой плоскости, по
	    кольцам бегут яркие сгустки, внутренние крутятся быстрее;
	  * вещество по спирали падает в окно и вытягивается в нити;
	  * мягкая линза-«пузырь» по краю вместо жуткого «щипка».
]]

local matGlow    = Material("sprites/light_glow02_add")
local matLens    = Material("effects/strider_bulge_dudv")
local matDisk    = Material("trails/plasma")
local matStrand  = Material("trails/laser")
local matArc     = Material("sprites/physbeama")
local matRing    = Material("effects/select_ring")

local TAU = math.pi * 2
local SEGMENTS = 48
local INFALL = 42
local DISK_TILT = 18 -- градусов: диск не строго лицом к игроку, чтобы читался объём

local WINDOW = 0.33       -- радиус окна-сферы относительно размера
local TUNNEL_LEN = 900    -- глубина тоннеля внутри окна, юниты
local TUNNEL_RINGS = 16
local TUNNEL_SEG = 32
local TUNNEL_STARS = 40

-- Кольца диска: доля от размера, толщина луча, сдвиг оттенка, скорость вращения.
local DISK = {
	{ r = 0.64, width = 9, hue = 0,   spin = 1.00 },
	{ r = 0.56, width = 8, hue = 50,  spin = 1.30 },
	{ r = 0.49, width = 7, hue = 100, spin = 1.70 },
	{ r = 0.43, width = 6, hue = 150, spin = 2.30 },
	{ r = 0.38, width = 5, hue = 200, spin = 3.10 },
}

-- Радужная палитра заранее: HSVToColor каждый кадр плодил бы мусор.
local palette = {}
for h = 0, 359 do
	local c = HSVToColor(h, 0.55, 1)
	palette[h] = { c.r, c.g, c.b }
end
local function hue(h)
	return palette[math.floor(h) % 360]
end

-- Один изменяемый цвет на все вершины кадра: AddBeam/DrawSprite копируют значение.
local tint = Color(255, 255, 255, 255)
local function setTint(r, g, b, a)
	tint.r, tint.g, tint.b, tint.a = r, g, b, math.Clamp(a, 0, 255)
	return tint
end
local function hueTint(h, a, mix)
	local c = hue(h)
	mix = mix or 0 -- подмешать белого (0..1)
	return setTint(c[1] + (255 - c[1]) * mix, c[2] + (255 - c[2]) * mix, c[3] + (255 - c[3]) * mix, a)
end

function ENT:Initialize()
	local r = self.Radius * 2.8
	self:SetRenderBounds(Vector(-r, -r, -40), Vector(r, r, self.Height + 90))
	self:RegisterPortal()

	self.Seeds = {}
	for i = 1, INFALL do
		self.Seeds[i] = {
			phase = math.random(),
			turn = math.random() * TAU,
			lift = (math.random() - 0.5) * 0.14,
			rate = 0.30 + math.random() * 0.25,
			hue = math.random(0, 359),
		}
	end

	self.TunnelSeeds = {}
	for i = 1, TUNNEL_STARS do
		self.TunnelSeeds[i] = { depth = math.random(), angle = math.random() * TAU, r = 0.2 + math.random() * 0.75 }
	end
end

function ENT:OnRemove()
	self:UnregisterPortal()
end

function ENT:Draw()
	-- Модель-носитель не рисуем: портал целиком состоит из эффектов.
end

-- Базис плоскости диска. Нестабильный диск прецессирует — качается, как волчок.
function ENT:DiskBasis(t, stable)
	local ang = self:GetAngles()
	ang:RotateAroundAxis(ang:Right(), DISK_TILT)
	if not stable then
		ang:RotateAroundAxis(ang:Forward(), math.sin(t * 7) * 7)
		ang:RotateAroundAxis(ang:Right(), math.cos(t * 5) * 7)
	end
	return ang:Right(), ang:Up(), ang:Forward()
end

local function ringPoint(center, u, v, radius, theta)
	return center + u * (math.cos(theta) * radius) + v * (math.sin(theta) * radius)
end

--------------------------------------------------------------------------------
-- Окно в тоннель (stencil)
--------------------------------------------------------------------------------

function ENT:DrawWormhole(core, size, t, stable, grow)
	local winR = size * WINDOW
	if winR < 2 then return end

	local toCore = core - EyePos()
	local dist = toCore:Length()
	local dir = dist > 0.1 and toCore / dist or self:GetForward()
	local inside = dist < winR

	-- 1. Маска: силуэт сферы-окна. Глубина мира учитывается — то, что стоит перед
	--    порталом, окно честно перекрывает.
	render.ClearStencil()
	render.SetStencilEnable(true)
	render.SetStencilWriteMask(255)
	render.SetStencilTestMask(255)
	render.SetStencilReferenceValue(1)
	render.SetStencilCompareFunction(STENCIL_ALWAYS)
	render.SetStencilPassOperation(STENCIL_REPLACE)
	render.SetStencilFailOperation(STENCIL_KEEP)
	render.SetStencilZFailOperation(STENCIL_KEEP)

	render.SetColorMaterial()
	render.OverrideColorWriteEnable(true, false)
	if inside then render.CullMode(MATERIAL_CULLMODE_CW) end
	render.DrawSphere(core, winR, 24, 24, color_white)
	if inside then render.CullMode(MATERIAL_CULLMODE_CCW) end
	render.OverrideColorWriteEnable(false, false)

	-- 2. Внутри маски — своё пространство: тёмно-фиолетовый фон и пустая глубина,
	--    поэтому тоннель «проходит» сквозь стены за порталом.
	render.SetStencilCompareFunction(STENCIL_EQUAL)
	render.SetStencilPassOperation(STENCIL_KEEP)
	render.ClearBuffersObeyStencil(16, 8, 38, 255, true)

	-- 3. Тоннель уходит от наблюдателя: кольца и звёзды затягивает внутрь.
	local basis = dir:Angle()
	local u, v = basis:Right(), basis:Up()
	local flow = t * (stable and 280 or 520)
	local spin = t * 0.9

	render.SetMaterial(matDisk)
	for k = 0, TUNNEL_RINGS - 1 do
		local depth = (k * TUNNEL_LEN / TUNNEL_RINGS + flow) % TUNNEL_LEN
		local near = 1 - depth / TUNNEL_LEN
		local center = core + dir * depth
		local width = (5 + 12 * near) * grow
		local h = k * 23 + t * 80

		render.StartBeam(TUNNEL_SEG + 1)
		for j = 0, TUNNEL_SEG do
			local theta = j / TUNNEL_SEG * TAU + spin
			render.AddBeam(ringPoint(center, u, v, winR * 1.05, theta), width, j / TUNNEL_SEG * 3, hueTint(h + j * 4, 255 * near, 0.15))
		end
		render.EndBeam()
	end

	render.SetMaterial(matStrand)
	for _, seed in ipairs(self.TunnelSeeds) do
		local depth = (seed.depth * TUNNEL_LEN + flow * 1.7) % TUNNEL_LEN
		local near = 1 - depth / TUNNEL_LEN
		local offset = u * (math.cos(seed.angle + spin) * winR * seed.r) + v * (math.sin(seed.angle + spin) * winR * seed.r)
		local head = core + dir * depth + offset
		render.DrawBeam(head - dir * 70, head, 2.5 * grow, 0, 1, setTint(255, 255, 255, 230 * near))
	end

	-- Свет в конце тоннеля.
	render.SetMaterial(matGlow)
	local pulse = 0.85 + 0.15 * math.sin(t * 4)
	render.DrawSprite(core + dir * TUNNEL_LEN, winR * 6 * pulse, winR * 6 * pulse, setTint(255, 245, 255, 255))
	render.DrawSprite(core + dir * (TUNNEL_LEN * 0.6), winR * 3, winR * 3, hueTint(t * 60, 120))

	render.SetStencilEnable(false)
end

--------------------------------------------------------------------------------
-- Диск и падающее вещество
--------------------------------------------------------------------------------

function ENT:DrawDisk(core, u, v, size, t, stable, grow)
	render.SetMaterial(matDisk)
	local speed = stable and 1.6 or 3.4

	for _, ring in ipairs(DISK) do
		local radius = size * ring.r
		local spin = t * ring.spin * speed
		local flicker = stable and 1 or (0.55 + math.random() * 0.45)

		render.StartBeam(SEGMENTS + 1)
		for j = 0, SEGMENTS do
			local theta = j / SEGMENTS * TAU
			-- Три ярких сгустка бегут по кольцу — так видно вращение; оттенок
			-- переливается вдоль кольца и со временем.
			local hot = 0.5 + 0.5 * math.sin(theta * 3 - spin * 2)
			local alpha = (90 + 165 * hot * hot) * grow * flicker
			local h = ring.hue + theta * 57.3 + t * 70
			render.AddBeam(ringPoint(core, u, v, radius, theta), ring.width * grow, j / SEGMENTS * 4 - spin * 0.5,
				hueTint(h, alpha, 0.25 * hot))
		end
		render.EndBeam()
	end
end

-- Вещество по спирали падает в окно и вытягивается в нити («спагеттификация»).
function ENT:DrawInfall(core, u, v, n, size, t, stable, grow)
	local outer, inner = size * 0.70, size * WINDOW
	local pace = stable and 1 or 1.8

	render.SetMaterial(matStrand)
	for _, seed in ipairs(self.Seeds) do
		local p = (t * seed.rate * pace + seed.phase) % 1
		local p0 = math.max(0, p - 0.05)

		local r1 = inner + (outer - inner) * (1 - p) ^ 1.6
		local r0 = inner + (outer - inner) * (1 - p0) ^ 1.6
		local head = ringPoint(core, u, v, r1, seed.turn + p * TAU * 2.2) + n * (seed.lift * r1)
		local tail = ringPoint(core, u, v, r0, seed.turn + p0 * TAU * 2.2) + n * (seed.lift * r0)

		render.DrawBeam(tail, head, (1.5 + 2.5 * (1 - p)) * grow, 0, 1, hueTint(seed.hue + t * 40, (70 + 185 * p) * grow, 0.3))
	end

	render.SetMaterial(matGlow)
	for _, seed in ipairs(self.Seeds) do
		local p = (t * seed.rate * pace + seed.phase) % 1
		local r1 = inner + (outer - inner) * (1 - p) ^ 1.6
		local pos = ringPoint(core, u, v, r1, seed.turn + p * TAU * 2.2) + n * (seed.lift * r1)
		local s = (3 + 7 * p) * grow
		render.DrawSprite(pos, s, s, hueTint(seed.hue + t * 40, (100 + 155 * p) * grow, 0.6))
	end
end

--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Классический: обручи-гироскоп
--------------------------------------------------------------------------------

-- Радиус (доля размера), толщина, начальные углы плоскости и их скорость, бег ярких пятен.
local GYRO = {
	{ r = 0.50, w = 7, p = 0,   y = 0,   sp = 40,  sy = 25,  run = 3 },
	{ r = 0.57, w = 6, p = 60,  y = 90,  sp = -30, sy = 45,  run = 4 },
	{ r = 0.64, w = 5, p = 120, y = 45,  sp = 25,  sy = -35, run = 5 },
	{ r = 0.71, w = 4, p = 30,  y = 135, sp = -18, sy = -22, run = 6 },
}

function ENT:DrawStandard(core, size, t, stable, grow, flash)
	render.UpdateRefractTexture()
	render.SetMaterial(matLens)
	render.DrawSprite(core, size * 1.1, size * 1.1, color_white)

	local rate = stable and 1 or 2.2
	render.SetMaterial(matDisk)
	for _, ring in ipairs(GYRO) do
		local ang = Angle(ring.p + t * ring.sp * rate, ring.y + t * ring.sy * rate, 0)
		local u, v = ang:Right(), ang:Up()
		local radius = size * ring.r
		local flicker = stable and 1 or (0.6 + math.random() * 0.4)
		-- Два прохода: широкий мягкий ореол и яркая сердцевина — обруч выглядит объёмным.
		for pass = 1, 2 do
			local wide = pass == 1
			render.StartBeam(SEGMENTS + 1)
			for j = 0, SEGMENTS do
				local theta = j / SEGMENTS * TAU
				local hot = 0.5 + 0.5 * math.sin(theta * 2 - t * ring.run)
				local alpha = (90 + 165 * hot * hot) * grow * flicker * (wide and 0.35 or 1)
				local width = ring.w * grow * (wide and 2.6 or (0.7 + 0.5 * hot))
				render.AddBeam(ringPoint(core, u, v, radius, theta), width, j / SEGMENTS * 3 - t,
					setTint(140 + 90 * hot, 70 + 100 * hot, 255, alpha))
			end
			render.EndBeam()
		end
	end

	render.SetMaterial(matGlow)
	local p = 0.85 + 0.15 * math.sin(t * 3)
	render.DrawSprite(core, size * 1.6, size * 1.6, setTint(140, 60, 255, ((stable and 110 or 70) + flash * 120) * grow))
	render.DrawSprite(core, size * 0.75 * p, size * 0.75 * p, setTint(190, 130, 255, 220 * grow))
	render.DrawSprite(core, size * 0.32 * p, size * 0.32 * p, setTint(255, 240, 255, 255 * grow))
end

--------------------------------------------------------------------------------
-- Минималистичный: чёрная дыра
--------------------------------------------------------------------------------

local MINI_DISK = {
	{ r = 0.36, w = 5, spin = 2.4 },
	{ r = 0.44, w = 3, spin = 1.6 },
}

-- Половина диска: дальняя (behind = true) рисуется до чёрной сферы, ближняя — после.
function ENT:DrawMiniDiskHalf(core, u, v, size, t, stable, grow, behind)
	local view = core - EyePos()
	render.SetMaterial(matDisk)
	for _, ring in ipairs(MINI_DISK) do
		local radius = size * ring.r
		local spin = t * ring.spin * (stable and 1 or 2.2)
		render.StartBeam(SEGMENTS + 1)
		for j = 0, SEGMENTS do
			local theta = j / SEGMENTS * TAU
			local pos = ringPoint(core, u, v, radius, theta)
			local far = (pos - core):Dot(view) > 0
			local hot = 0.5 + 0.5 * math.sin(theta * 3 - spin * 2)
			local alpha = 0
			if far == behind then alpha = (120 + 135 * hot) * grow end
			render.AddBeam(pos, ring.w * grow, j / SEGMENTS * 4 - spin * 0.5,
				setTint(255, 120 + 100 * hot, 30 + 60 * hot, alpha))
		end
		render.EndBeam()
	end
end

function ENT:DrawMinimal(core, size, t, stable, grow, flash)
	local hole = size * 0.22
	local u, v = self:DiskBasis(t, stable)

	render.UpdateRefractTexture()
	render.SetMaterial(matLens)
	render.DrawSprite(core, size * 1.3, size * 1.3, color_white)

	self:DrawMiniDiskHalf(core, u, v, size, t, stable, grow, true)
	render.SetColorMaterial()
	render.DrawSphere(core, hole * grow, 24, 24, color_black)
	self:DrawMiniDiskHalf(core, u, v, size, t, stable, grow, false)

	-- Фотонное кольцо — тонкий светлый ободок вокруг горизонта, всегда лицом к игроку.
	render.SetMaterial(matRing)
	render.DrawSprite(core, hole * 2.5 * grow, hole * 2.5 * grow, setTint(255, 170, 80, 200 * grow + flash * 55))
	render.SetMaterial(matGlow)
	render.DrawSprite(core, size * 0.9, size * 0.9, setTint(255, 120, 40, (40 + flash * 120) * grow))
end

--------------------------------------------------------------------------------
-- Весёлый (исходный вид) и выбор стиля
--------------------------------------------------------------------------------

function ENT:DrawFun(core, size, now, stable, grow, flash)
	local u, v, n = self:DiskBasis(now, stable)

	-- Мягкая линза по краю окна.
	render.UpdateRefractTexture()
	render.SetMaterial(matLens)
	render.DrawSprite(core, size * 1.15, size * 1.15, color_white)

	-- Окно в тоннель, затем объёмный диск поверх.
	self:DrawWormhole(core, size, now, stable, grow)
	self:DrawDisk(core, u, v, size, now, stable, grow)
	self:DrawInfall(core, u, v, n, size, now, stable, grow)

	-- Мягкий ореол.
	render.SetMaterial(matGlow)
	render.DrawSprite(core, size * 1.6, size * 1.6, hueTint(now * 40, (stable and 110 or 70) + flash * 120, 0.2))
end

-- Цвет искр и динамического света по стилю.
local function styleColor(style, t)
	if style == "minimal" then return 255, 140, 50 end
	if style == "fun" then
		local c = hue(t)
		return c[1], c[2], c[3]
	end
	return 160, 90, 255
end

function ENT:DrawTranslucent()
	local now = CurTime()
	local stable = self:GetStable()
	local core = self:GetCore()

	local grow = MapSingularity.SmoothStep((now - self:GetBirthTime()) / 1.2)
	if grow <= 0 then return end

	-- Вспышка в момент стабилизации.
	local flash = 0
	if stable then flash = math.max(0, 1 - (now - self:GetStableTime()) / 0.8) end

	local pulse = 0.5 + 0.5 * math.sin(now * (stable and 3 or 11))
	local jitter = stable and 0 or (math.random() - 0.5) * 0.25
	local size = (stable and 118 or 90) * grow * (1 + 0.04 * pulse + jitter) + flash * 60

	local cv = MapSingularity.CVars.PortalStyle
	local style = cv and cv:GetString() or "standard"
	if style == "fun" then
		self:DrawFun(core, size, now, stable, grow, flash)
	elseif style == "minimal" then
		self:DrawMinimal(core, size, now, stable, grow, flash)
	else
		style = "standard"
		self:DrawStandard(core, size, now, stable, grow, flash)
	end
	local cr, cg, cb = styleColor(style, now * 40)

	-- Нестабильная сингулярность искрит — цветом своего стиля (весёлая — случайным).
	if not stable and math.random() < 0.35 then
		render.SetMaterial(matArc)
		local dir = VectorRand()
		dir:Normalize()
		local tip = core + dir * size * 0.75
		local mid = (core + tip) * 0.5 + VectorRand() * size * 0.12
		local r, g, b = cr, cg, cb
		if style == "fun" then
			local c = hue(math.random(0, 359))
			r, g, b = c[1], c[2], c[3]
		end
		render.StartBeam(3)
		render.AddBeam(core + dir * size * WINDOW, 6, 0, setTint(r, g, b, 255))
		render.AddBeam(mid, 4, 0.5, setTint(r, g, b, 255))
		render.AddBeam(tip, 1, 1, setTint(r, g, b, 255))
		render.EndBeam()
	end

	local dl = DynamicLight(self:EntIndex())
	if dl then
		dl.pos = core
		dl.r, dl.g, dl.b = cr, cg, cb
		dl.brightness = ((stable and 3 or 1.5) + flash * 4) * (style == "minimal" and 0.5 or 1)
		dl.decay = 1200
		dl.size = (stable and 320 or 200) * grow
		dl.dietime = now + 0.1
	end
end
