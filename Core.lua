--------------------------------------------------------------------------------
-- PredUI: our own addons in one package, with one settings menu.
--
--   * Each former addon is a module in Modules\. A module is registered with
--     ns.NewModule, gets its own table in PredUIDB (PredUIDB.flight, .craft...)
--     and is started once, from ADDON_LOADED, if it's turned on.
--   * Turning a module off or on takes a /reload: modules hook Blizzard
--     functions, and hooks can't be removed again.
--   * Style.lua holds the shared look (panels, buttons, bars, glow), so every
--     window and bar looks like it belongs to the same addon.
--   * Settings.lua builds the menu: Esc > Options > AddOns > PredUI, or /predui.
--
-- The old addons kept their data in their own saved variables, which the game
-- only loads for them. Tools\migrate.js copies it into PredUIDB (run it with
-- the game closed).
--------------------------------------------------------------------------------

local ADDON, ns = ...

ns.ADDON = ADDON
ns.modules = {}                -- in the order the files load, which is the menu order
ns.byKey = {}

local CHAT_PREFIX = "|cff4fc3f7PredUI|r "

--------------------------------------------------------------------------------
-- Helpers shared by every module
--------------------------------------------------------------------------------

-- Some APIs can return secret values in restricted contexts; those can't be
-- compared, stored or used in arithmetic.
function ns.Public(v)
	return not (issecretvalue and issecretvalue(v))
end

function ns.PublicNumber(v)
	return ns.Public(v) and type(v) == "number" and v or nil
end

function ns.PublicString(v)
	return ns.Public(v) and type(v) == "string" and v ~= "" and v or nil
end

-- A call that's allowed to be missing or to fail; the caller copes with nil.
function ns.Try(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, a, b, c, d, e, f, g, h, i = pcall(fn, ...)
	if ok then return a, b, c, d, e, f, g, h, i end
end

-- Auctionator's price for one of an item, or nil (no Auctionator, no data).
-- Auctionator is an optional dependency, so it may be missing.
function ns.AuctionPrice(link)
	local api = Auctionator and Auctionator.API and Auctionator.API.v1
	if not (api and api.GetAuctionPriceByItemLink and ns.PublicString(link)) then return end
	return ns.PublicNumber(ns.Try(api.GetAuctionPriceByItemLink, "PredUI", link))
end

function ns.HasAuctionator()
	local api = Auctionator and Auctionator.API and Auctionator.API.v1
	return api ~= nil and api.GetAuctionPriceByItemLink ~= nil
end

-- "1:05", or "1:02:05" from an hour up.
function ns.Clock(secs)
	secs = math.max(0, math.floor(secs + 0.5))
	if secs >= 3600 then
		return ("%d:%02d:%02d"):format(math.floor(secs / 3600), math.floor(secs % 3600 / 60), secs % 60)
	end
	return ("%d:%02d"):format(math.floor(secs / 60), secs % 60)
end

function ns.Print(msg)
	print(CHAT_PREFIX .. msg)
end

--------------------------------------------------------------------------------
-- Modules
--------------------------------------------------------------------------------

-- info: title, notes (one line for the menu), defaults (plain values only:
-- they're read through a metatable, so only values the player changes get saved).
function ns.NewModule(key, info)
	local M = {
		key = key,
		title = info.title,
		notes = info.notes,
		defaults = info.defaults or {},
	}
	function M.Say(msg)
		print(CHAT_PREFIX .. "|cffffd100" .. M.title .. ":|r " .. msg)
	end
	ns.modules[#ns.modules + 1] = M
	ns.byKey[key] = M
	return M
end

function ns.IsEnabled(key)
	return not (PredUIDB and PredUIDB.modules and PredUIDB.modules[key] == false)
end

-- Wraps a module's slash handler so a turned-off module says so instead of
-- doing nothing.
function ns.SlashHandler(M, handler)
	return function(msg)
		if not M.enabled then
			M.Say("this module is off. Turn it on in /predui.")
			return
		end
		handler(msg or "")
	end
end

local function WithDefaults(tbl, defaults)
	tbl = type(tbl) == "table" and tbl or {}
	return setmetatable(tbl, { __index = defaults })
end

--------------------------------------------------------------------------------
-- Confirmations
--------------------------------------------------------------------------------

StaticPopupDialogs.PREDUI_CONFIRM = {
	text = "%s",
	button1 = YES or "Yes",
	button2 = NO or "No",
	OnAccept = function(self, data)
		data = data or self.data
		if data and data.onAccept then data.onAccept() end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	showAlert = true,
	preferredIndex = 3,
}

function ns.Confirm(text, onAccept)
	StaticPopup_Show("PREDUI_CONFIRM", text, nil, { onAccept = onAccept })
end

StaticPopupDialogs.PREDUI_RELOAD = {
	text = "PredUI: turning modules on or off takes a reload. Reload now?",
	button1 = RELOADUI or "Reload",
	button2 = "Later",
	OnAccept = function() ReloadUI() end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

function ns.AskReload()
	StaticPopup_Show("PREDUI_RELOAD")
end

--------------------------------------------------------------------------------
-- Start-up
--------------------------------------------------------------------------------

local GLOBAL_DEFAULTS = {
	scale = 1,                 -- scale of every PredUI window and bar
	glow = true,               -- soft glow around windows and bars
	minimap = true,            -- show the minimap button (Minimap.lua)
}

local function Init()
	PredUIDB = type(PredUIDB) == "table" and PredUIDB or {}
	PredUICharDB = type(PredUICharDB) == "table" and PredUICharDB or {}
	PredUIDB.modules = type(PredUIDB.modules) == "table" and PredUIDB.modules or {}
	PredUIDB.global = WithDefaults(PredUIDB.global, GLOBAL_DEFAULTS)
	ns.global = PredUIDB.global

	for _, M in ipairs(ns.modules) do
		PredUIDB[M.key] = WithDefaults(PredUIDB[M.key], M.defaults)
		PredUICharDB[M.key] = type(PredUICharDB[M.key]) == "table" and PredUICharDB[M.key] or {}
		M.db = PredUIDB[M.key]
		M.charDB = PredUICharDB[M.key]
	end
	for _, M in ipairs(ns.modules) do
		if ns.IsEnabled(M.key) and M.Enable then
			local ok, err = pcall(M.Enable, M)
			if ok then
				M.enabled = true
			else
				geterrorhandler()(err)
			end
		end
	end
	ns.Style.ApplyGlobal()
	if ns.RegisterSettings then ns.RegisterSettings() end
	if ns.BuildMinimapButton then ns.BuildMinimapButton() end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(_, _, name)
	if name == ADDON then
		Init()
		return
	end
	-- Load-on-demand Blizzard windows (Professions, macros...) arrive later.
	for _, M in ipairs(ns.modules) do
		if M.enabled and M.OnAddonLoaded then M:OnAddonLoaded(name) end
	end
end)
