--[[
	MapSingularity — бинарный разбор .bsp и амортизированный прекэш.

	Формат заголовка (Source BSP v19/v20):
		int   ident        "VBSP"
		int   version
		lump_t lumps[64]   { int fileofs; int filelen; int version; int fourCC }
		int   mapRevision
	Lump 0 — текстовый Entity Lump: блоки { "key" "value" ... }.
	Если fourCC != 0, ламп сжат LZMA с заголовком Valve:
		"LZMA", uint32 actualSize, uint32 lzmaSize, byte props[5], data...
]]

local MS = MapSingularity
MS.Precache = MS.Precache or {}
local P = MS.Precache

local HEADER_SIZE = 8 + 64 * 16 + 4
local LZMA_HEADER = 17
local TIMER_NAME  = "MS_Precache"

-- Ключи, значения которых — имена материалов (относительно materials/).
local MATERIAL_KEYS = {
	texture = true, material = true, ropematerial = true, spritename = true,
	detailmaterial = true, overlaymaterial = true, texturename = true,
	cloudmaterial = true,
}

local SKY_SIDES = { "bk", "dn", "ft", "lf", "rt", "up" }

--------------------------------------------------------------------------------
-- Чтение заголовка и Entity Lump
--------------------------------------------------------------------------------

local function uint32le(n)
	n = n % 4294967296
	return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end

local function readUInt32(s, pos)
	local a, b, c, d = string.byte(s, pos, pos + 3)
	if not d then return nil end
	return a + b * 256 + c * 65536 + d * 16777216
end

--[[
	Valve LZMA -> формат Bootil, который понимает util.Decompress.
	Заголовок Valve (17 байт, в 1-индексации Lua):
		1..4 "LZMA", 5..8 actualSize, 9..12 lzmaSize, 13..17 props[5], с 18 — поток.
	Bootil: props[5] + uint64 LE размер распакованных данных + поток.
]]
local function valveToBootil(data)
	if string.sub(data, 1, 4) ~= "LZMA" or #data <= LZMA_HEADER then return nil end
	local actual = readUInt32(data, 5)
	local packed = readUInt32(data, 9)
	if not actual or not packed or actual == 0 or packed == 0 then return nil end

	local props = string.sub(data, 13, 17)
	local stream = string.sub(data, LZMA_HEADER + 1, LZMA_HEADER + packed)
	if #stream ~= packed then return nil end

	return props .. uint32le(actual) .. "\0\0\0\0" .. stream, actual
end

local function decompressValveLZMA(data)
	local bootil, actual = valveToBootil(data)
	if not bootil then return nil end
	local out = util.Decompress(bootil, actual + 1)
	if not out or #out ~= actual then return nil end
	return out
end

P.ValveToBootil = valveToBootil -- для офлайн-проверки формата

--[[
	Читает блок по смещению и распаковывает, если он начинается с "LZMA".
	Размер сжатого потока берём из LZMA-заголовка: у сжатых game lump'ов поле
	длины в каталоге хранит распакованный размер, а не сжатый.
]]
local function readMaybeCompressed(f, ofs, len, size)
	f:Seek(ofs)
	local head = f:Read(math.min(LZMA_HEADER, size - ofs))

	if head and #head == LZMA_HEADER and string.sub(head, 1, 4) == "LZMA" then
		local packed = readUInt32(head, 9)
		if not packed or ofs + LZMA_HEADER + packed > size then
			return nil, "LZMA-поток выходит за пределы файла"
		end
		f:Seek(ofs)
		local blob = f:Read(LZMA_HEADER + packed)
		local out = blob and decompressValveLZMA(blob)
		if not out then return nil, "не удалось распаковать LZMA" end
		return out
	end

	f:Seek(ofs)
	local data = f:Read(len)
	if not data or #data ~= len then return nil, "не удалось прочитать" end
	return data
end

local function validLump(ofs, len, size)
	return ofs and len and ofs >= HEADER_SIZE and len > 0 and ofs + len <= size
end

local LUMP_GAME = 35
local GAMELUMP_SPRP = "prps" -- id 'sprp' как little-endian int
local MAX_STATIC_DICT = 4096

-- Словарь sprp: int32 count + count записей по 128 байт (имя модели с нулём).
local function parseStaticDict(s)
	local entries = readUInt32(s, 1)
	if not entries or entries > MAX_STATIC_DICT or 4 + entries * 128 > #s then return {} end

	local names = {}
	for i = 0, entries - 1 do
		local raw = string.sub(s, 5 + i * 128, 4 + (i + 1) * 128)
		local zero = string.find(raw, "\0", 1, true)
		local name = zero and string.sub(raw, 1, zero - 1) or raw
		if name ~= "" then names[#names + 1] = name end
	end
	return names
end

--[[
	Словарь моделей статических пропов (game lump "sprp"). prop_static не попадает
	в Entity Lump — без этого большая часть моделей карты осталась бы холодной.
	Флаг 1 — game lump сжат Valve-LZMA (так собирают свежие компиляторы, VRAD++).
]]
local function readStaticPropModels(f, size)
	f:Seek(8 + LUMP_GAME * 16)
	local ofs, len = f:ReadLong(), f:ReadLong()
	if not validLump(ofs, len, size) or len < 4 then return {} end

	f:Seek(ofs)
	local count = f:ReadLong()
	if not count or count <= 0 or count > 128 or 4 + count * 16 > len then return {} end

	for _ = 1, count do
		local id = f:Read(4)
		local flags = f:ReadUShort()
		f:ReadUShort() -- version
		local lofs, llen = f:ReadLong(), f:ReadLong()

		if id == GAMELUMP_SPRP then
			local compressed = bit.band(flags, 1) ~= 0
			local need = compressed and LZMA_HEADER or llen
			local function inFile(o) return o and llen and llen > 0 and o >= HEADER_SIZE and o + need <= size end

			-- На ПК смещение абсолютное; в некоторых сборках — от начала game lump.
			if not inFile(lofs) then lofs = ofs + lofs end
			if not inFile(lofs) then return {} end

			if compressed then
				local data = readMaybeCompressed(f, lofs, llen, size)
				return data and parseStaticDict(data) or {}
			end

			f:Seek(lofs)
			local entries = f:ReadLong()
			if not entries or entries < 0 or entries > MAX_STATIC_DICT or 4 + entries * 128 > llen then return {} end
			f:Seek(lofs)
			return parseStaticDict(f:Read(4 + entries * 128) or "")
		end
	end

	return {}
end

-- Открывает maps/<map>.bsp из GAME (включая смонтированные GMA) и возвращает
-- { version, size, entities } либо nil, причина.
function P.ReadBSP(mapName)
	local path = "maps/" .. mapName .. ".bsp"
	local f = file.Open(path, "rb", "GAME")
	if not f then return nil, "не удалось открыть " .. path end

	local size = f:Size()
	if size < HEADER_SIZE then
		f:Close()
		return nil, "файл слишком мал для BSP"
	end

	local ident = f:Read(4)
	if ident ~= "VBSP" then
		f:Close()
		return nil, "неверная сигнатура BSP: " .. tostring(ident)
	end

	local version = f:ReadLong()
	local a, b, c, fourCC = f:ReadLong(), f:ReadLong(), f:ReadLong(), f:ReadLong()

	-- Стандартный порядок полей: fileofs, filelen, version, fourCC.
	-- В L4D2-варианте v21 порядок version, fileofs, filelen — проверяем оба.
	local ofs, len = a, b
	if not validLump(ofs, len, size) then ofs, len = b, c end
	if not validLump(ofs, len, size) then
		f:Close()
		return nil, "повреждён каталог лампов"
	end

	-- Несжатый Entity Lump всегда начинается с "{", сжатый — с "LZMA" (fourCC при
	-- этом хранит распакованный размер), поэтому определяем по сигнатуре.
	local entities, eerr = readMaybeCompressed(f, ofs, len, size)
	local staticModels = readStaticPropModels(f, size)
	f:Close()

	if not entities then
		-- Сама карта при этом рабочая — движок её загрузит; просто прогреем меньше.
		MS.Warn("%s: Entity Lump не прочитан (%s), прекэш только по статическим пропам", mapName, tostring(eerr))
		entities = ""
	end

	return { version = version, size = size, entities = entities, staticModels = staticModels, lzma = fourCC ~= 0 }
end

--------------------------------------------------------------------------------
-- Извлечение ассетов
--------------------------------------------------------------------------------

local function normalizePath(v)
	v = string.lower(string.Trim(v))
	v = string.gsub(v, "\\", "/")
	v = string.gsub(v, "//+", "/")
	v = string.gsub(v, "^/+", "")
	return v
end

local function materialName(v)
	v = normalizePath(v)
	v = string.gsub(v, "^materials/", "")
	v = string.gsub(v, "%.vmt$", "")
	v = string.gsub(v, "%.spr$", "") -- HL1-спрайты в Source указывают на materials/*.vmt
	return v
end

--[[
	Разбирает текст Entity Lump. Возвращает таблицу
	{ models = {...}, materials = {...}, packed = n, refs = n }
	где packed — ссылки на файлы, которых нет в GAME (скорее всего лежат в
	pakfile самого BSP и станут доступны только после загрузки карты).
	Их не трогаем: Material() на отсутствующий файл закэширует error-материал.
]]
function P.ExtractAssets(entities, staticModels)
	local models, materials = {}, {}
	local seenModel, seenMat = {}, {}
	local refs, packed = 0, 0

	local function addModel(v)
		v = normalizePath(v)
		if seenModel[v] or not string.match(v, "^models/.+%.mdl$") then return end
		seenModel[v] = true
		refs = refs + 1
		if file.Exists(v, "GAME") then
			models[#models + 1] = v
		else
			packed = packed + 1
		end
	end

	local function addMaterial(v)
		v = materialName(v)
		if v == "" or seenMat[v] or string.find(v, "..", 1, true) then return end
		seenMat[v] = true
		refs = refs + 1
		if file.Exists("materials/" .. v .. ".vmt", "GAME") then
			materials[#materials + 1] = v
		else
			packed = packed + 1
		end
	end

	for block in string.gmatch(entities, "%b{}") do
		for key, value in string.gmatch(block, "\"([^\"]*)\"%s*\"([^\"]*)\"") do
			key = string.lower(key)
			local lower = string.lower(value)

			if key == "skyname" and value ~= "" then
				local sky = materialName(value)
				for _, side in ipairs(SKY_SIDES) do
					addMaterial("skybox/" .. sky .. side)
				end
			elseif key == "model" and string.sub(value, 1, 1) ~= "*" then
				if string.match(lower, "%.mdl$") then
					addModel(value)
				elseif string.match(lower, "%.vmt$") or string.match(lower, "%.spr$") then
					addMaterial(value)
				end
			elseif MATERIAL_KEYS[key] and value ~= "" then
				addMaterial(value)
			elseif string.match(lower, "^models/.+%.mdl$") then
				addModel(value)
			elseif string.match(lower, "^materials/.+%.vmt$") then
				addMaterial(value)
			end
		end
	end

	local entityModels = #models
	for _, name in ipairs(staticModels or {}) do
		addModel(name)
	end

	return {
		models = models,
		materials = materials,
		refs = refs,
		packed = packed,
		staticModels = #models - entityModels,
	}
end

-- Полная проверка карты: заголовок, версия, ассеты с учётом лимитов.
function P.Inspect(mapName)
	local bsp, err = P.ReadBSP(mapName)
	if not bsp then return nil, err end

	if not MS.SUPPORTED_BSP[bsp.version] then
		return nil, string.format("BSP v%d не поддерживается движком GMod", bsp.version)
	end

	local assets = P.ExtractAssets(bsp.entities, bsp.staticModels)

	local modelBudget = MS.CVars.ModelBudget:GetInt()
	local matBudget = MS.CVars.MaterialBudget:GetInt()
	local trimmed = 0

	while #assets.models > modelBudget do
		table.remove(assets.models)
		trimmed = trimmed + 1
	end
	while #assets.materials > matBudget do
		table.remove(assets.materials)
		trimmed = trimmed + 1
	end
	assets.trimmed = trimmed

	return {
		version = bsp.version,
		size = bsp.size,
		entityBytes = #bsp.entities,
		assets = assets,
	}
end

--------------------------------------------------------------------------------
-- Амортизированный прекэш
--------------------------------------------------------------------------------

local function sliceMs()
	return MS.CVars.SliceMs:GetFloat()
end

-- Порядок: сначала материалы (дешевле и чаще всего нужны первыми), потом модели.
function P.Run(assets, onProgress, onDone)
	local queue = {}
	for _, m in ipairs(assets.materials) do queue[#queue + 1] = { false, m } end
	for _, m in ipairs(assets.models) do queue[#queue + 1] = { true, m } end

	local warmed, failed = 0, 0

	MS.Amortize(TIMER_NAME, queue, sliceMs, function(item)
		if item[1] then
			util.PrecacheModel(item[2])
			warmed = warmed + 1
		else
			local mat = Material(item[2])
			if mat and not mat:IsError() then
				warmed = warmed + 1
			else
				failed = failed + 1
			end
		end
	end, onProgress, function(done, total)
		if onDone then onDone({ done = done, total = total, warmed = warmed, failed = failed }) end
	end)
end

function P.Cancel()
	timer.Remove(TIMER_NAME)
end
