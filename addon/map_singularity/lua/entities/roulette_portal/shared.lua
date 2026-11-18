ENT.Type = "anim"
ENT.Base = "base_anim"

ENT.PrintName = MapSingularity.T("portal_name")
ENT.Author = "MapSingularity"
ENT.Purpose = MapSingularity.T("portal_purpose")
ENT.Instructions = MapSingularity.T("portal_instructions")
ENT.Category = "MapSingularity"

ENT.Spawnable = true
ENT.AdminOnly = true
ENT.RenderGroup = RENDERGROUP_TRANSLUCENT

-- Размеры триггера дублируют sh_config (MS.PORTAL_*), чтобы энтити работала,
-- даже если её таблица загружена раньше глобальной конфигурации.
ENT.Radius = 46
ENT.Height = 110

-- Притяжение стабильного портала (общий код: сервер и предсказание клиента
-- считают одно и то же, поэтому игрока тянет плавно, без рывков).
ENT.PullRadius = 420  -- юниты от ядра
ENT.PullAccel = 1100  -- ускорение у самого ядра, юнит/с²; к краю спадает квадратично

function ENT:SetupDataTables()
	self:NetworkVar("Bool", 0, "Stable")
	self:NetworkVar("Float", 0, "BirthTime")
	self:NetworkVar("Float", 1, "StableTime")
	self:NetworkVar("String", 0, "TargetTitle")
	self:NetworkVar("String", 1, "TargetMap")
end

-- Ядро выше середины триггера: диск радиусом ~73 юнита не должен уходить в пол.
ENT.CoreHeight = 80

function ENT:GetCore()
	return self:GetPos() + self:GetUp() * self.CoreHeight
end

--------------------------------------------------------------------------------
-- Реестр порталов: чтобы не перебирать все энтити каждый тик ради притяжения.
--------------------------------------------------------------------------------

MapSingularity = MapSingularity or {}
MapSingularity.Portals = MapSingularity.Portals or {}

function ENT:RegisterPortal()
	MapSingularity.Portals[self] = true
end

function ENT:UnregisterPortal()
	MapSingularity.Portals[self] = nil
end

-- Ближайший стабильный портал и расстояние до его ядра (для эффектов на клиенте).
function MapSingularity.NearestStablePortal(pos)
	local best, bestDist
	for portal in pairs(MapSingularity.Portals) do
		if IsValid(portal) and portal:GetStable() then
			local dist = pos:Distance(portal:GetCore())
			if not bestDist or dist < bestDist then best, bestDist = portal, dist end
		elseif not IsValid(portal) then
			MapSingularity.Portals[portal] = nil
		end
	end
	return best, bestDist
end

-- Конвар ms_portal_pull создаётся в sh_config (реплицируемый, есть в панели настроек).
hook.Add("Move", "MS_PortalPull", function(ply, mv)
	local cvar = MapSingularity.CVars and MapSingularity.CVars.Pull
	if not (cvar and cvar:GetBool()) or not ply:Alive() or ply:GetMoveType() == MOVETYPE_NOCLIP then return end

	local center = mv:GetOrigin() + ply:OBBCenter()
	for portal in pairs(MapSingularity.Portals) do
		if IsValid(portal) and portal:GetStable() then
			local delta = portal:GetCore() - center
			local dist = delta:Length()
			local radius = portal.PullRadius or 420
			if dist > 1 and dist < radius then
				local k = 1 - dist / radius
				local accel = (portal.PullAccel or 1100) * k * k
				mv:SetVelocity(mv:GetVelocity() + delta * (accel * FrameTime() / dist))
			end
		end
	end
end)
