AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
include("shared.lua")

local SND_LOOP     = "ambient/levels/citadel/portal_beam_loop1.wav"
local SND_STABLE   = "ambient/levels/labs/teleport_mechanism_windup1.wav"
local SND_CHIME    = "garrysmod/content_downloaded.wav"
local SND_COLLAPSE = "ambient/levels/labs/teleport_winddown1.wav"
local SND_DENY     = "buttons/button10.wav"

-- Высокий тон гула звучит игриво, а не зловеще.
local PITCH_UNSTABLE = 85
local PITCH_STABLE   = 125

function ENT:SpawnFunction(ply, tr, class)
	if not tr.Hit then return end

	local ent = ents.Create(class)
	if not IsValid(ent) then return end
	ent:SetPos(tr.HitPos + tr.HitNormal * 4)
	ent:SetAngles(Angle(0, ply:EyeAngles().y + 180, 0))
	ent:Spawn()
	ent:Activate()

	if MapSingularity and MapSingularity.Director then
		MapSingularity.Director.AdoptPortal(ent, ply)
	end

	return ent
end

function ENT:Initialize()
	-- Модель нужна только чтобы энтити участвовала в рендере; её не рисуем.
	self:SetModel("models/props_junk/popcan01a.mdl")
	self:SetMoveType(MOVETYPE_NONE)
	self:SetSolid(SOLID_BBOX)
	self:SetCollisionBounds(Vector(-self.Radius, -self.Radius, 0), Vector(self.Radius, self.Radius, self.Height))
	self:SetTrigger(true)
	self:SetNotSolid(true)
	self:DrawShadow(false)

	self:SetBirthTime(CurTime())
	self:SetStable(false)

	self.Loop = CreateSound(self, SND_LOOP)
	self.Loop:PlayEx(0.55, PITCH_UNSTABLE)

	self.NextDeny = 0
	self:RegisterPortal()
end

function ENT:Stabilize(title, map)
	self:SetTargetTitle(title or "")
	self:SetTargetMap(map or "")
	if self:GetStable() then return end

	self:SetStable(true)
	self:SetStableTime(CurTime())
	self:EmitSound(SND_STABLE, 80, 130, 0.6)
	self:EmitSound(SND_CHIME, 75, 100, 0.9)
	if self.Loop then self.Loop:ChangePitch(PITCH_STABLE, 1.5) end
end

function ENT:TryEnter(ent)
	if not (IsValid(ent) and ent:IsPlayer() and ent:Alive()) then return end

	if not self:GetStable() then
		if self.NextDeny < CurTime() then
			self.NextDeny = CurTime() + 2
			ent:EmitSound(SND_DENY, 60)
			MapSingularity.Notice(ent, MapSingularity.NOTICE_POPUP, "portal_unstable")
		end
		return
	end

	local MS = MapSingularity
	if not MS or MS.Inventory.Transit then return end
	MS.Director.EnterPortal(self, ent)
end

function ENT:StartTouch(ent)
	self:TryEnter(ent)
end

function ENT:Touch(ent)
	self:TryEnter(ent)
end

-- Подстраховка к триггеру: игрок, стоявший внутри в момент стабилизации,
-- не получает StartTouch, а Touch для неподвижных тел может не приходить.
function ENT:Think()
	local MS = MapSingularity
	if self:GetStable() and MS and not MS.Inventory.Transit then
		local slack = 16
		for _, ply in ipairs(player.GetAll()) do
			if ply:Alive() then
				local lp = self:WorldToLocal(ply:GetPos())
				if math.abs(lp.x) <= self.Radius + slack and math.abs(lp.y) <= self.Radius + slack
					and lp.z >= -slack and lp.z <= self.Height then
					self:TryEnter(ply)
					break
				end
			end
		end
	end

	self:NextThink(CurTime() + 0.1)
	return true
end

function ENT:OnRemove()
	self:UnregisterPortal()
	if self.Loop then self.Loop:Stop() end

	local MS = MapSingularity
	if MS and MS.Director then MS.Director.OnPortalRemoved(self) end

	if not (MS and MS.Inventory and MS.Inventory.Transit) then
		sound.Play(SND_COLLAPSE, self:GetCore(), 75, 110, 0.7)
	end
end
