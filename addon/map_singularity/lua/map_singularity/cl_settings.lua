--[[
	MapSingularity — панель настроек: меню Q → «Утилиты» → MapSingularity → «Настройки».
	Тексты — на языке клиента (sh_lang, ms_cl_language). Серверные значения читаются из
	реплицируемых конваров, изменения уходят на сервер net-сообщением ms_setting (сервер
	проверяет права и диапазон). Клиентские (язык, сообщения, отладка, вид портала, подгонка
	пушки) меняются сразу. Подгонка пушки — сворачиваемый раздел внизу.
]]

local MS = MapSingularity
local T = MS.T

local pending = {}

-- Слайдеры шлют значения непрерывно: отправляем последнее через 0.3 с тишины.
local function send(name, value)
	pending[name] = tostring(value)
	timer.Create("MS_Setting_" .. name, 0.3, 1, function()
		net.Start(MS.Net.Setting)
		net.WriteString(name)
		net.WriteString(pending[name])
		net.SendToServer()
	end)
end

local function slider(panel, label, cvar, name, min, max, decimals)
	local s = panel:NumSlider(label, nil, min, max, decimals)
	s:SetValue(cvar:GetFloat())
	s.OnValueChanged = function(_, value) send(name, value) end
	return s
end

local function checkbox(panel, label, cvar, name)
	local c = panel:CheckBox(label)
	c:SetChecked(cvar:GetBool())
	c.OnChange = function(_, value) send(name, value and 1 or 0) end
	return c
end

local function combo(panel, label, current, choices, onSelect)
	local box = panel:ComboBox(label)
	for _, choice in ipairs(choices) do
		box:AddChoice(choice[2], choice[1], current == choice[1])
	end
	box.OnSelect = function(_, _, _, data) onSelect(data) end
	return box
end

-- Подгонка «Луня»: клиентские конвары <MS.LunTunePrefix>vm_* (от камеры) и wm_* (от кисти).
local TUNE_AXES = {
	{ "x", -40, 40, 2 }, { "y", -40, 40, 2 }, { "z", -40, 40, 2 },
	{ "p", -180, 180, 1 }, { "yw", -180, 180, 1 }, { "r", -180, 180, 1 },
	{ "s", 0.3, 2, 2 },
}

local tuneExpanded = false -- панель пересобирается при открытии меню — раздел не сворачиваем

local function buildTune(panel)
	local form = vgui.Create("DForm")
	form:SetName(T("tune_title"))
	form:SetExpanded(tuneExpanded)
	form.OnToggle = function(_, expanded) tuneExpanded = expanded end
	panel:AddItem(form)

	local prefix = MS.LunTunePrefix or "ms_lunk_"
	form:Help(T("tune_help"))
	for _, section in ipairs({ { "vm", "tune_vm" }, { "wm", "tune_wm" } }) do
		form:Help(T(section[2]))
		for _, axis in ipairs(TUNE_AXES) do
			form:NumSlider(T("tune_" .. axis[1]), prefix .. section[1] .. "_" .. axis[1], axis[2], axis[3], axis[4])
		end
	end

	local reset = form:Button(T("tune_reset"))
	reset.DoClick = function()
		for kind, values in pairs(MS.LunTuneDefaults or {}) do
			for key, def in pairs(values) do
				RunConsoleCommand(prefix .. kind .. "_" .. key, tostring(def))
			end
		end
	end
	form:Button(T("tune_where"), "ms_lun_where")
	local dump = form:Button(T("tune_dump"))
	dump.DoClick = function()
		for _, kind in ipairs({ "vm", "wm" }) do
			local parts = {}
			for _, axis in ipairs(TUNE_AXES) do
				local cv = GetConVar(prefix .. kind .. "_" .. axis[1])
				parts[#parts + 1] = axis[1] .. " = " .. (cv and cv:GetString() or "?")
			end
			MS.Log("подгонка %s: %s", kind, table.concat(parts, ", "))
		end
	end
end

local build

local function build_(panel)
	panel:ClearControls()
	panel:Help(T("set_help"))

	local langs = { { "auto", T("set_lang_auto") } }
	for _, l in ipairs(MS.Languages) do langs[#langs + 1] = l end
	combo(panel, T("set_language"), MS.CVars.Language:GetString(), langs, function(code)
		RunConsoleCommand("ms_cl_language", code)
		timer.Simple(0.1, function() if IsValid(panel) then build(panel) end end)
	end)

	combo(panel, T("set_where"), MS.CVars.SearchMode:GetString(),
		{ { MS.SEARCH_TOP, T("mode_top") }, { MS.SEARCH_UNIVERSE, T("mode_universe") } },
		function(mode) send("ms_search_mode", mode) end)
	panel:ControlHelp(T("set_where_help"))

	panel:Help(T("set_rating"))
	slider(panel, T("set_min_score"), MS.CVars.MinScore, "ms_min_score", 0, 1, 2)
	slider(panel, T("set_min_votes"), MS.CVars.MinVotes, "ms_min_votes", 0, 500, 0)

	panel:Help(T("set_search"))
	slider(panel, T("set_max_size"), MS.CVars.MaxSizeMB, "ms_max_size_mb", 10, 1000, 0)
	checkbox(panel, T("set_auto"), MS.CVars.AutoFetch, "ms_auto_fetch")
	slider(panel, T("set_auto_delay"), MS.CVars.AutoDelay, "ms_auto_fetch_delay", 5, 600, 0)
	checkbox(panel, T("set_pull"), MS.CVars.Pull, "ms_portal_pull")
	checkbox(panel, T("set_autoplace"), MS.CVars.Autoplace, "ms_portal_autoplace")
	checkbox(panel, T("set_mature"), MS.CVars.AllowMature, "ms_allow_mature")

	combo(panel, T("set_portal_style"), MS.CVars.PortalStyle:GetString(),
		{ { "standard", T("style_standard") }, { "fun", T("style_fun") }, { "minimal", T("style_minimal") } },
		function(style) RunConsoleCommand("ms_cl_portal_style", style) end)

	panel:Help(T("set_client"))
	panel:CheckBox(T("set_notices"), "ms_cl_notices")
	panel:CheckBox(T("set_debug"), "ms_cl_debug")

	panel:Help(T("set_actions"))
	panel:Button(T("act_give"), "ms_give_gun")
	panel:Button(T("act_spin"), "ms_force_fetch")
	panel:Button(T("act_abort"), "ms_abort")
	panel:Button(T("act_status"), "ms_status")

	buildTune(panel)
end
build = build_

local settingsPanel

hook.Add("PopulateToolMenu", "MS_SettingsMenu", function()
	spawnmenu.AddToolMenuOption("Utilities", "MapSingularity", "ms_settings", T("set_title"), "", "", function(panel)
		settingsPanel = panel
		build(panel)
	end)
end)

-- Значения могли поменяться (консоль, другой админ) — освежаем при открытии меню.
hook.Add("SpawnMenuOpen", "MS_SettingsRefresh", function()
	if IsValid(settingsPanel) then build(settingsPanel) end
end)
