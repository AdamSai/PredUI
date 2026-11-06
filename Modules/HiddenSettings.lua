--------------------------------------------------------------------------------
-- Hidden Settings: game settings that exist as console variables (CVars) but
-- aren't in the game's Options menu, such as denser and longer-range grass,
-- weather and full-screen effects, with checkboxes and sliders.
--
--   * Each entry is read and written straight through C_CVar, so the game keeps
--     the value itself (in Config.wtf or on the server) and PredUI saves nothing.
--   * The list is curated from settings that aren't in Forever's own Options
--     (checked against Blizzard's settings code). An entry whose CVar this client
--     doesn't have is left out, so the page only shows what really works.
--   * The game clamps some values to its own limits. After a change the value is
--     read back, and you're told if the game kept a different one.
--   * Secure CVars (nameplates...) can't be changed in combat; that's refused
--     with a message instead of failing silently.
--------------------------------------------------------------------------------

local _, ns = ...

local M = ns.NewModule("cvars", {
	title = "Hidden Settings",
	notes = "Game settings that aren't in the Options menu: denser grass, longer foliage distance, weather, screen effects and more.",
})

local function Info(cvar)
	local value, default, _, _, locked, secure, readOnly = C_CVar.GetCVarInfo(cvar)
	if value == nil or locked or readOnly then return nil end
	return value, default, secure
end

local function Number(v)
	return tonumber(v) or 0
end

local function Trim(n)
	-- 1.50 -> "1.5", 2.00 -> "2"
	return (("%.2f"):format(n):gsub("%.?0+$", ""))
end

--------------------------------------------------------------------------------
-- The list
--------------------------------------------------------------------------------

-- kind: "toggle" | "slider" | "choice". Sliders: min, max, step, unit (shown after
-- the number). Choices: values = { { cvarValue, label }, ... }.
local SECTIONS = {
	{
		title = "Graphics and foliage",
		tip = "Higher values cost frame rate, especially in grassy zones.",
		entries = {
			{ cvar = "groundEffectDensity", kind = "slider", label = "Grass and foliage density", min = 16, max = 256, step = 8,
				tip = "How thick ground clutter (grass, flowers, small plants) is. The Options menu's Ground Clutter setting stops well below the top of this range." },
			{ cvar = "groundEffectDist", kind = "slider", label = "Grass and foliage distance", min = 40, max = 320, step = 10, unit = " yd",
				tip = "How far away ground clutter is still drawn." },
			{ cvar = "horizonStart", kind = "slider", label = "Detailed terrain distance", min = 400, max = 6000, step = 100, unit = " yd",
				tip = "Where full-detail terrain gives way to the low-detail horizon." },
			{ cvar = "terrainLodDist", kind = "slider", label = "Terrain detail distance", min = 100, max = 650, step = 25, unit = " yd",
				tip = "How far terrain keeps its highest level of detail." },
			{ cvar = "entityLodDist", kind = "slider", label = "Character and creature detail", min = 0, max = 100, step = 5,
				tip = "How far players and creatures keep their most detailed models." },
			{ cvar = "weatherDensity", kind = "slider", label = "Weather density", min = 0, max = 3, step = 1,
				tip = "Rain, snow and dust storms: 0 is off, 3 is the heaviest." },
			{ cvar = "particleDensity", kind = "slider", label = "Particle density", min = 10, max = 100, step = 10, unit = "%",
				tip = "How many particles spell and world effects use." },
			{ cvar = "projectedTextures", kind = "toggle", label = "Projected textures",
				tip = "Spell circles and other effects drawn onto the ground." },
		},
	},
	{
		title = "Screen effects",
		entries = {
			{ cvar = "ffxGlow", kind = "toggle", label = "Full-screen glow", tip = "The soft bloom glow over the whole screen." },
			{ cvar = "ffxDeath", kind = "toggle", label = "Death effect", tip = "The grey screen while you're dead." },
			{ cvar = "ffxNether", kind = "toggle", label = "Nether effect", tip = "The screen tint while invisible, phased or in the nether." },
		},
	},
	{
		title = "Camera",
		entries = {
			{ cvar = "cameraZoomSpeed", kind = "slider", label = "Zoom speed", min = 1, max = 50, step = 1,
				tip = "How fast the mouse wheel zooms the camera." },
			{ cvar = "cameraIndirectVisibility", kind = "toggle", label = "Camera passes through objects",
				tip = "Let the camera move through small objects instead of zooming in on them." },
		},
	},
	{
		title = "Interface",
		entries = {
			{ cvar = "xpBarText", kind = "toggle", label = "Always show XP bar text", tip = "Show the numbers on the XP and reputation bars all the time, not only on hover." },
			{ cvar = "alwaysCompareItems", kind = "toggle", label = "Always compare items", tip = "Show the comparison with your equipped item without holding Shift." },
			{ cvar = "showQuestTrackingTooltips", kind = "toggle", label = "Quest progress in tooltips", tip = "Show quest objective progress in unit and object tooltips." },
			{ cvar = "UberTooltips", kind = "toggle", label = "Detailed tooltips", tip = "Longer tooltips with extra information." },
			{ cvar = "missingTransmogSourceInItemTooltips", kind = "toggle", label = "Show uncollected appearance sources", tip = "Tell when you know an appearance, but not from this item." },
			{ cvar = "scriptErrors", kind = "toggle", label = "Show Lua errors", tip = "Show the game's error window for addon errors (BugSack catches them anyway)." },
			{ cvar = "WorldTextScale", kind = "slider", label = "Floating combat text size", min = 0.5, max = 2.5, step = 0.1,
				tip = "Size of damage, healing and XP numbers in the world." },
			{ cvar = "floatingCombatTextCombatHealing", kind = "toggle", label = "Show healing numbers", tip = "Floating numbers for healing you do." },
			{ cvar = "floatingCombatTextFloatMode", kind = "choice", label = "Combat text direction",
				values = { { "1", "Scroll up" }, { "2", "Scroll down" }, { "3", "Arc" } },
				tip = "How your own combat text moves." },
		},
	},
	{
		title = "Combat",
		entries = {
			{ cvar = "SpellQueueWindow", kind = "slider", label = "Spell queue window", min = 0, max = 400, step = 10, unit = " ms",
				tip = "How early before a cast or global cooldown ends you can queue the next spell. Lower is more precise, higher is more forgiving with lag." },
			{ cvar = "ActionButtonUseKeyDown", kind = "toggle", label = "Cast on key press", tip = "Cast when the key goes down instead of when it's released." },
			{ cvar = "autoLootRate", kind = "slider", label = "Auto loot delay", min = 0, max = 300, step = 10, unit = " ms",
				tip = "Time between items when auto looting. Lower is faster." },
			{ cvar = "nameplateMaxDistance", kind = "slider", label = "Nameplate distance", min = 10, max = 60, step = 1, unit = " yd",
				tip = "How far away nameplates are shown. The game may cap this lower." },
			{ cvar = "nameplateOverlapV", kind = "slider", label = "Nameplate vertical spacing", min = 0.3, max = 2, step = 0.1,
				tip = "Space between stacked nameplates. Higher spreads them out." },
		},
	},
	{
		title = "Screenshots and gore",
		entries = {
			{ cvar = "screenshotFormat", kind = "choice", label = "Screenshot format",
				values = { { "jpeg", "JPEG (small files)" }, { "png", "PNG (lossless)" }, { "tga", "TGA (lossless, large)" } },
				tip = "File type of screenshots in the Screenshots folder." },
			{ cvar = "screenshotQuality", kind = "slider", label = "Screenshot quality", min = 1, max = 10, step = 1,
				tip = "JPEG quality, 10 is best." },
			{ cvar = "violenceLevel", kind = "slider", label = "Blood and gore", min = 0, max = 5, step = 1,
				tip = "0 is none, 5 is the most." },
		},
	},
}

--------------------------------------------------------------------------------
-- Reading and writing
--------------------------------------------------------------------------------

local function Get(entry)
	local value = C_CVar.GetCVar(entry.cvar)
	if entry.kind == "toggle" then return value == "1" end
	if entry.kind == "slider" then return Number(value) end
	return value
end

local function Shown(entry, value)
	if entry.kind == "toggle" then return value == "1" and "on" or "off" end
	if entry.kind == "choice" then
		for _, v in ipairs(entry.values) do
			if v[1] == value then return v[2] end
		end
		return tostring(value)
	end
	return Trim(Number(value)) .. (entry.unit or "")
end

local function Set(entry, value)
	if not M.enabled then
		M.Say("this module is off. Turn it on on the PredUI page.")
		return
	end
	local _, _, secure = Info(entry.cvar)
	if secure and InCombatLockdown() then
		M.Say(entry.label .. " can't be changed in combat.")
		return
	end
	local wanted
	if entry.kind == "toggle" then
		wanted = value and "1" or "0"
	elseif entry.kind == "slider" then
		wanted = Trim(value)
	else
		wanted = tostring(value)
	end
	C_CVar.SetCVar(entry.cvar, wanted)

	-- The game may clamp or refuse a value.
	local got = C_CVar.GetCVar(entry.cvar)
	if got ~= nil and got ~= wanted and Number(got) ~= Number(wanted) then
		M.Say(("%s: the game kept %s."):format(entry.label, Shown(entry, got)))
	end
end

local available = {}           -- entries this client has, in menu order

local function ResetAll()
	if InCombatLockdown() then
		M.Say("leave combat first: some of these can't be changed in combat.")
		return
	end
	local n = 0
	for _, entry in ipairs(available) do
		local default = C_CVar.GetCVarDefault(entry.cvar)
		if default and C_CVar.GetCVar(entry.cvar) ~= default then
			C_CVar.SetCVar(entry.cvar, default)
			n = n + 1
		end
	end
	M.Say(n == 0 and "everything is already at the game's default."
		or ("%d setting(s) put back to the game's default."):format(n))
end

--------------------------------------------------------------------------------
-- Settings page (built once at load, from the CVars this client really has)
--------------------------------------------------------------------------------

local function Tooltip(entry, default)
	return ("%s\n\nGame default: %s\n|cff808080Console: %s|r"):format(entry.tip or "", Shown(entry, default), entry.cvar)
end

local function BuildOptions()
	local options = {}
	for _, section in ipairs(SECTIONS) do
		local rows = {}
		for _, entry in ipairs(section.entries) do
			local value, default = Info(entry.cvar)
			if value ~= nil then
				available[#available + 1] = entry
				local opt = {
					key = entry.cvar,
					label = entry.label,
					tooltip = Tooltip(entry, default),
					get = function() return Get(entry) end,
					set = function(v) Set(entry, v) end,
				}
				if entry.kind == "toggle" then
					opt.type, opt.default = "checkbox", default == "1"
				elseif entry.kind == "slider" then
					opt.type, opt.default = "slider", Number(default)
					opt.min, opt.max, opt.step = entry.min, entry.max, entry.step
					opt.format = function(v) return Trim(v) .. (entry.unit or "") end
				else
					opt.type, opt.default = "dropdown", default
					opt.values = function() return entry.values end
				end
				rows[#rows + 1] = opt
			end
		end
		if #rows > 0 then
			options[#options + 1] = { type = "header", label = section.title, tooltip = section.tip }
			for _, opt in ipairs(rows) do options[#options + 1] = opt end
		end
	end
	options[#options + 1] = { type = "header", label = "Defaults" }
	options[#options + 1] = { type = "button", label = "Everything on this page", button = "Game defaults",
		tooltip = "Put every setting on this page back to the game's own default.",
		func = function() ns.Confirm("Put every hidden setting back to the game's default?", ResetAll) end }
	return options
end

M.options = BuildOptions()

function M:Enable()
	-- Nothing to start: every value lives in the game's own settings.
end

--------------------------------------------------------------------------------
-- /hiddensettings
--------------------------------------------------------------------------------

local function OnSlash(msg)
	msg = msg:lower():match("^%s*(.-)%s*$")
	if msg == "reset" then
		ns.Confirm("Put every hidden setting back to the game's default?", ResetAll)
	elseif msg == "list" then
		M.Say(("%d hidden setting(s) on this client:"):format(#available))
		for _, entry in ipairs(available) do
			print(("  %s: %s"):format(entry.label, Shown(entry, C_CVar.GetCVar(entry.cvar))))
		end
	elseif msg == "" or msg == "options" then
		ns.OpenSettings(M)
	else
		M.Say("/hiddensettings - open the page, /hiddensettings list - current values, /hiddensettings reset - game defaults")
	end
end

SLASH_PREDUICVARS1 = "/hiddensettings"
SlashCmdList.PREDUICVARS = ns.SlashHandler(M, OnSlash)
