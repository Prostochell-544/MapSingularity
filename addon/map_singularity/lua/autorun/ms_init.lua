--[[
	MapSingularity: Seamless Workshop Roulette
	Точка входа. Порядок загрузки важен: sh_config создаёт глобальную таблицу,
	конвары и сетевые строки, остальные модули опираются на неё.
]]

MapSingularity = MapSingularity or {}

local SHARED = {
	"map_singularity/sh_config.lua",
	"map_singularity/sh_lang.lua",
}

local SERVER_ONLY = {
	"map_singularity/sv_precache.lua",
	"map_singularity/sv_workshop.lua",
	"map_singularity/sv_inventory.lua",
	"map_singularity/sv_director.lua",
}

local CLIENT_ONLY = {
	"map_singularity/cl_prefetch.lua",
	"map_singularity/cl_visuals.lua",
	"map_singularity/cl_settings.lua",
}

if SERVER then
	for _, path in ipairs(SHARED) do
		AddCSLuaFile(path)
		include(path)
	end

	for _, path in ipairs(CLIENT_ONLY) do
		AddCSLuaFile(path)
	end

	for _, path in ipairs(SERVER_ONLY) do
		include(path)
	end

	-- Чёрная «заглушка» экрана загрузки (asset://) должна лежать у клиентов локально.
	-- Для Workshop-установки она приходит вместе с аддоном, для legacy-папки на
	-- выделенном сервере — через FastDL.
	resource.AddSingleFile("materials/map_singularity/portal_void.png")
else
	for _, path in ipairs(SHARED) do
		include(path)
	end

	for _, path in ipairs(CLIENT_ONLY) do
		include(path)
	end
end

MapSingularity.Log("v%s загружен (%s)", MapSingularity.VERSION, SERVER and "server" or "client")
