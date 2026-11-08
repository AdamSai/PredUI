--------------------------------------------------------------------------------
-- PredUI settings menu, in the game's own options: Esc > Options > AddOns >
-- PredUI, or /predui.
--
--   * The PredUI page turns modules on or off (takes a /reload, because hooks
--     can't be undone) and holds the shared look: scale and glow.
--   * Each module gets a page under it, built from its M.options list:
--       checkbox / slider / dropdown
--                          key (in the module's db) or get/set, label, tooltip,
--                          onChange; sliders also min, max, step; dropdowns
--                          values (a function returning { value, label } pairs)
--       button             label, button (its text), tooltip, func
--       header             label, tooltip: a section heading on the page
--   * Buttons and onChange only run for modules that are on; a module that's
--     off just stores the value for when it's turned back on.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.Style

local mainCategory
local pages = {}               -- [module] = its subcategory

local function Variable(M, key)
	return "PREDUI_" .. (M and M.key:upper() .. "_" or "") .. key:upper()
end

local function AddHeader(layout, text, tooltip)
	layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text, tooltip))
end

local function AddButton(layout, label, buttonText, tooltip, func)
	layout:AddInitializer(CreateSettingsButtonInitializer(label, buttonText, func, tooltip, true))
end

-- One module option on its page.
local function AddOption(category, layout, M, opt)
	if opt.type == "header" then
		AddHeader(layout, opt.label, opt.tooltip)
		return
	end
	if opt.type == "button" then
		AddButton(layout, opt.label, opt.button, opt.tooltip, function()
			if not M.enabled then
				M.Say("this module is off. Turn it on on the PredUI page.")
				return
			end
			opt.func()
		end)
		return
	end

	local get = opt.get or function() return M.db[opt.key] end
	local set = opt.set or function(value) M.db[opt.key] = value end
	local default = opt.default
	if default == nil then default = M.defaults[opt.key] end

	local function Set(value)
		set(value)
		if M.enabled and opt.onChange then opt.onChange(value) end
	end

	if opt.type == "checkbox" then
		local setting = Settings.RegisterProxySetting(category, Variable(M, opt.key), Settings.VarType.Boolean,
			opt.label, default and true or false,
			function() return get() and true or false end,
			function(value) Set(value and true or false) end)
		Settings.CreateCheckbox(category, setting, opt.tooltip)
	elseif opt.type == "slider" then
		local setting = Settings.RegisterProxySetting(category, Variable(M, opt.key), Settings.VarType.Number,
			opt.label, default or opt.min,
			function() return tonumber(get()) or default or opt.min end,
			function(value) Set(value) end)
		local options = Settings.CreateSliderOptions(opt.min, opt.max, opt.step or 1)
		options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, opt.format)
		Settings.CreateSlider(category, setting, options, opt.tooltip)
	elseif opt.type == "dropdown" then
		local setting = Settings.RegisterProxySetting(category, Variable(M, opt.key), Settings.VarType.String,
			opt.label, default or "",
			function() return tostring(get() or "") end,
			function(value) Set(value) end)
		local function GetOptions()
			local container = Settings.CreateControlTextContainer()
			for _, choice in ipairs(opt.values()) do
				container:Add(choice[1], choice[2])
			end
			return container:GetData()
		end
		Settings.CreateDropdown(category, setting, GetOptions, opt.tooltip)
	end
end

local function BuildMainPage()
	local category, layout = Settings.RegisterVerticalLayoutCategory("PredUI")
	mainCategory = category

	AddHeader(layout, "Modules", "Turning a module on or off takes a reload.")
	for _, M in ipairs(ns.modules) do
		local setting = Settings.RegisterProxySetting(category, Variable(nil, "module_" .. M.key), Settings.VarType.Boolean,
			M.title, true,
			function() return ns.IsEnabled(M.key) end,
			function(value)
				if value == ns.IsEnabled(M.key) then return end
				PredUIDB.modules[M.key] = value and true or false
				ns.AskReload()
			end)
		Settings.CreateCheckbox(category, setting, M.notes .. "\n\nTakes a reload.")
	end

	AddHeader(layout, "Look", "Shared by every PredUI window and bar.")
	local scale = Settings.RegisterProxySetting(category, Variable(nil, "scale"), Settings.VarType.Number,
		"Scale", 1,
		function() return ns.global.scale or 1 end,
		function(value)
			ns.global.scale = math.floor(value * 20 + 0.5) / 20
			S.ApplyGlobal()
		end)
	local scaleOptions = Settings.CreateSliderOptions(0.6, 1.6, 0.05)
	scaleOptions:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(v)
		return ("%d%%"):format(math.floor(v * 100 + 0.5))
	end)
	Settings.CreateSlider(category, scale, scaleOptions, "Size of every PredUI window and bar.")

	local glow = Settings.RegisterProxySetting(category, Variable(nil, "glow"), Settings.VarType.Boolean,
		"Glow", true,
		function() return ns.global.glow and true or false end,
		function(value)
			ns.global.glow = value and true or false
			S.ApplyGlobal()
		end)
	Settings.CreateCheckbox(category, glow, "Soft coloured glow around PredUI windows and bars.")

	local minimap = Settings.RegisterProxySetting(category, Variable(nil, "minimap"), Settings.VarType.Boolean,
		"Minimap button", true,
		function() return ns.global.minimap and true or false end,
		function(value) ns.SetMinimapButtonShown(value) end)
	Settings.CreateCheckbox(category, minimap, "The PredUI button on the minimap. Left-click opens these settings, right-click the Mail Ledger panel.")

	local launcher = Settings.RegisterProxySetting(category, Variable(nil, "launcher"), Settings.VarType.Boolean,
		"Floating button", true,
		function() return ns.global.launcher and true or false end,
		function(value) ns.SetLauncherShown(value) end)
	Settings.CreateCheckbox(category, launcher, "A PredUI button you can drag anywhere. Click it for a row of icons that open the PredUI windows (Notes, Loot Room, Mail Ledger...). Right-click opens these settings.")

	AddHeader(layout, "Reload")
	AddButton(layout, "Apply module changes", "Reload UI", "Reloads the interface.", function() ReloadUI() end)

	Settings.RegisterAddOnCategory(category)
end

local function BuildModulePage(M)
	local category, layout = Settings.RegisterVerticalLayoutSubcategory(mainCategory, M.title)
	pages[M] = category
	AddHeader(layout, M.title, M.notes)
	for _, opt in ipairs(M.options or {}) do
		AddOption(category, layout, M, opt)
	end
end

function ns.RegisterSettings()
	if not (Settings and Settings.RegisterVerticalLayoutCategory) then return end
	BuildMainPage()
	for _, M in ipairs(ns.modules) do
		BuildModulePage(M)
	end
end

-- Opens the menu, at a module's page if one is given.
function ns.OpenSettings(M)
	local category = M and pages[M] or mainCategory
	if not category then
		ns.Print("the settings menu isn't available on this client.")
		return
	end
	Settings.OpenToCategory(category:GetID())
end

--------------------------------------------------------------------------------
-- /predui
--------------------------------------------------------------------------------

local function PrintHelp()
	ns.Print("our addons in one. /predui opens the settings. Modules and their commands:")
	local commands = {
		flight = "/flighttimer", craft = "/crafttimer", bag = "/bagvalue", icon = "/iconsearch",
		loot = "/lootroom", mail = "/mledger", cvars = "/hiddensettings", paladin = "/palbuffs", bankalt = "/bankalt", notes = "/notes", partyloc = "/partyloc", invwhisper = "/invwhisper", swing = "/swingtimer",
	}
	for _, M in ipairs(ns.modules) do
		local state = M.enabled and "|cff40ff40on|r" or (ns.IsEnabled(M.key) and "|cffff8040on after reload|r" or "|cff808080off|r")
		print(("  %s (%s) - %s"):format(M.title, state, commands[M.key] or ""))
	end
	print("  /predui minimap - show or hide the minimap button")
	print("  /predui button - show or hide the floating button")
	print("  /predui reset - put every bar and window back in its default place")
end

SLASH_PREDUI1, SLASH_PREDUI2 = "/predui", "/pui"
SlashCmdList.PREDUI = function(msg)
	msg = (msg or ""):lower():match("^%s*(.-)%s*$")
	if msg == "" or msg == "options" then
		ns.OpenSettings()
	elseif msg == "minimap" then
		ns.ToggleMinimapButton()
	elseif msg == "button" then
		ns.ToggleLauncher()
	elseif msg == "reset" then
		ns.ResetLauncherPosition()
		for _, M in ipairs(ns.modules) do
			if M.enabled and M.ResetPosition then M.ResetPosition() end
		end
	else
		PrintHelp()
	end
end
