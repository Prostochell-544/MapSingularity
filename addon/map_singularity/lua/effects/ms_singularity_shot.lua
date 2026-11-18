--[[
	Выстрел КПП «Лунь»: закрученный луч от дула до точки попадания и вспышка.
]]

local matBeam = Material("trails/laser")
local matGlow = Material("sprites/light_glow02_add")

local LIFE = 0.4
local COILS = 3          -- витков спирали вокруг луча
local SEGMENTS = 24

local tint = Color(255, 255, 255, 255)
local function setTint(r, g, b, a)
	tint.r, tint.g, tint.b, tint.a = r, g, b, math.Clamp(a, 0, 255)
	return tint
end

-- Дуло: у своего оружия от первого лица — точка вьюмодели, иначе — мировой модели.
local function muzzle(wep, fallback)
	if not IsValid(wep) then return fallback end
	local owner = wep:GetOwner()
	local firstPerson = owner == LocalPlayer() and not owner:ShouldDrawLocalPlayer()

	-- «Лунь» рисуется своей моделью, а не вьюмоделью: точку шара между когтями оружие
	-- запоминает при отрисовке (от первого лица — уже пересчитанной в FOV мира).
	local lun
	if firstPerson then lun = wep.LunMuzzleView else lun = wep.LunMuzzleWorld end
	if lun and RealTime() - lun.t < 0.25 then return lun.pos end

	local source = wep
	if firstPerson then
		local vm = owner:GetViewModel()
		if IsValid(vm) then source = vm end
	end
	local att = source:GetAttachment(1)
	return att and att.Pos or fallback
end

function EFFECT:Init(data)
	self.EndPos = data:GetOrigin()
	self.StartPos = muzzle(data:GetEntity(), data:GetStart())
	self.Born = CurTime()
	self:SetRenderBoundsWS(self.StartPos, self.EndPos, Vector(64, 64, 64))
end

function EFFECT:Think()
	return CurTime() - self.Born < LIFE
end

function EFFECT:Render()
	local frac = math.Clamp((CurTime() - self.Born) / LIFE, 0, 1)
	local alpha = 255 * (1 - frac)
	local a, b = self.StartPos, self.EndPos
	local dir = b - a
	local len = dir:Length()
	if len < 1 then return end
	dir:Normalize()

	local basis = dir:Angle()
	local right, up = basis:Right(), basis:Up()

	render.SetMaterial(matBeam)
	render.DrawBeam(a, b, 9 * (1 - frac) + 2, frac * 2, frac * 2 + 1, setTint(170, 110, 255, alpha))
	render.DrawBeam(a, b, 3, 0, 1, setTint(130, 235, 255, alpha))

	-- Спираль вокруг луча, раскручивается и тает.
	local radius = 3 + 10 * frac
	render.StartBeam(SEGMENTS + 1)
	for i = 0, SEGMENTS do
		local k = i / SEGMENTS
		local ang = k * math.pi * 2 * COILS + frac * 6
		local pos = a + dir * (len * k) + right * (math.cos(ang) * radius) + up * (math.sin(ang) * radius)
		render.AddBeam(pos, 2.5, k, setTint(255, 150 + 100 * k, 240, alpha))
	end
	render.EndBeam()

	render.SetMaterial(matGlow)
	local s = 30 + 70 * frac
	render.DrawSprite(b, s, s, setTint(225, 185, 255, alpha))
end
