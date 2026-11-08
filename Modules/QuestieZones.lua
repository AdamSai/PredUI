--------------------------------------------------------------------------------
-- Questie Zones: orders the zone headers in Questie's quest tracker by
-- distance, nearest first, instead of alphabetically.
--
--   * Questie's "By Zone" sortings group quests under zone headers in A-Z
--     order ("By Zone Prox" only sorts the quests inside each zone by distance).
--   * Questie keeps its code in modules that QuestieLoader:ImportModule hands
--     out (the live tables). We wrap TrackerUtils:GetSortedQuestIds, which the
--     tracker calls on every redraw, and reorder its result: whole zone groups
--     move, the quests inside each zone keep Questie's order. Questie's own
--     files stay untouched, so Questie updates don't undo this.
--   * A zone's distance is its nearest quest's: the nearest unfinished
--     objective, or the turn-in once the quest is complete. That's Questie's
--     own DistanceUtils.GetNearestSpawnForQuest, the measure its proximity
--     sortings use. Questie puts other continents and instances at 500000+, so
--     they come after this continent. Zones with no location go last, A-Z.
--   * "By Zone Prox" already redraws the tracker every 5 sec while you move.
--     For plain "By Zone" we check every 5 sec ourselves and redraw only when
--     the zone order changed, through Questie's combat queue.
--   * Only Questie's tracker (not the quest log) is affected. If a Questie
--     update renames these functions, the module stops sorting and says so in
--     /qzones; Questie keeps working as normal.
--------------------------------------------------------------------------------

local _, ns = ...
local Public, PublicNumber, Try = ns.Public, ns.PublicNumber, ns.Try

local M = ns.NewModule("questiezones", {
	title = "Questie Zones",
	notes = "Orders the zones in Questie's quest tracker by distance, nearest first.",
	defaults = { sortZones = true },
})

local CHECK_EVERY = 5          -- seconds between zone order checks while moving (plain "By Zone")
local MOVED = 0.0005           -- map fraction the player must move before we recheck
local OTHER_CONTINENT = 500000 -- Questie adds this to distances in another continent or instance
local NO_SPAWN = 999999999     -- Questie's "no location" distance

local ZONE_MODES = {
	byZone = true,
	byZonePlayerProximity = true,
	byZonePlayerProximityReversed = true,
}

local db
local Q = {}                   -- Questie modules: TrackerUtils, QuestieTracker, DistanceUtils, QuestieCombatQueue
local hooked = false
local problem                  -- why we couldn't hook, for /qzones
local lastIds, lastDetails     -- the tracker's last list, to recheck the order while moving
local lastOrder = ""
local lastMap, lastX, lastY

--------------------------------------------------------------------------------
-- Sorting
--------------------------------------------------------------------------------

local function SortMode()
	local profile = Questie and Questie.db and Questie.db.profile
	return profile and profile.trackerSortObjectives
end

local function Active()
	return M.enabled and db.sortZones and ZONE_MODES[SortMode()] or false
end

-- Nearest distance of one quest, or nil when Questie knows no location for it.
local function QuestDistance(quest)
	local fn = Q.DistanceUtils and Q.DistanceUtils.GetNearestSpawnForQuest
	local distance = select(4, Try(fn, quest))
	distance = PublicNumber(distance)
	if distance and distance < NO_SPAWN then return distance end
end

-- Reorders the zone groups of ids (already sorted by Questie) in place.
-- Returns the zone names in the new order and each zone's distance.
local function SortZones(ids, details)
	local groups, order, dist = {}, {}, {}
	for _, questId in ipairs(ids) do
		local info = details[questId]
		local zone = info and info.zoneName or "?"
		if not groups[zone] then
			groups[zone] = {}
			order[#order + 1] = zone
		end
		table.insert(groups[zone], questId)
		local d = info and QuestDistance(info.quest)
		if d and (not dist[zone] or d < dist[zone]) then dist[zone] = d end
	end

	table.sort(order, function(a, b)
		local dA, dB = dist[a], dist[b]
		if dA and dB and dA ~= dB then return dA < dB end
		if dA and not dB then return true end
		if dB and not dA then return false end
		return tostring(a) < tostring(b)
	end)

	local i = 1
	for _, zone in ipairs(order) do
		for _, questId in ipairs(groups[zone]) do
			ids[i] = questId
			i = i + 1
		end
	end
	return order, dist
end

M.SortZones = SortZones        -- for Tools/checks

local function OrderKey(order)
	return table.concat(order, "\001")
end

--------------------------------------------------------------------------------
-- Questie hook
--------------------------------------------------------------------------------

local function Redraw()
	local tracker = Q.QuestieTracker
	if not (tracker and tracker.Update) then return end
	local queue = Q.QuestieCombatQueue
	if queue and queue.Queue then
		Try(queue.Queue, queue, function() tracker:Update() end)
	elseif not InCombatLockdown() then
		Try(tracker.Update, tracker)
	end
end

local function Hook()
	if hooked then return true end
	if not (QuestieLoader and QuestieLoader.ImportModule) then
		problem = "Questie isn't loaded."
		return false
	end
	for _, name in ipairs({ "TrackerUtils", "QuestieTracker", "DistanceUtils", "QuestieCombatQueue" }) do
		Q[name] = Try(QuestieLoader.ImportModule, QuestieLoader, name)
	end
	local utils = Q.TrackerUtils
	local original = utils and utils.GetSortedQuestIds
	if type(original) ~= "function" or not (Q.DistanceUtils and Q.DistanceUtils.GetNearestSpawnForQuest) then
		problem = "this Questie version has no TrackerUtils:GetSortedQuestIds / DistanceUtils, so zones can't be sorted."
		return false
	end

	utils.GetSortedQuestIds = function(...)
		local ids, details = original(...)
		if type(ids) == "table" and type(details) == "table" then
			lastIds, lastDetails = ids, details
			if Active() then
				local ok, order = pcall(SortZones, ids, details)
				if ok then lastOrder = OrderKey(order) else geterrorhandler()(order) end
			end
		end
		return ids, details
	end
	hooked, problem = true, nil
	return true
end

-- Every few seconds in plain "By Zone": redraw if moving changed the zone order.
local function PlayerSpot()
	local map = PublicNumber(Try(C_Map.GetBestMapForUnit, "player"))
	local pos = map and Try(C_Map.GetPlayerMapPosition, map, "player")
	if not (pos and Public(pos) and pos.GetXY) then return end
	local x, y = Try(pos.GetXY, pos)
	return map, PublicNumber(x), PublicNumber(y)
end

local function Check()
	if not (hooked and Active() and SortMode() == "byZone" and lastIds) then return end
	if IsInInstance() then return end
	local map, x, y = PlayerSpot()
	if not (map and x and y) then return end
	if map == lastMap and math.abs(x - lastX) < MOVED and math.abs(y - lastY) < MOVED then return end
	lastMap, lastX, lastY = map, x, y

	local copy = {}
	for i, questId in ipairs(lastIds) do copy[i] = questId end
	local ok, order = pcall(SortZones, copy, lastDetails)
	if ok and OrderKey(order) ~= lastOrder then Redraw() end
end

--------------------------------------------------------------------------------
-- Slash command and options
--------------------------------------------------------------------------------

local function FormatDistance(d)
	if not d then return "no location" end
	if d >= OTHER_CONTINENT then return "other continent" end
	return ("%d yd"):format(d)
end

local function ShowOrder()
	if not hooked then
		M.Say(problem or "not active.")
		return
	end
	local mode = SortMode()
	if not ZONE_MODES[mode] then
		M.Say("Questie's tracker sorting is \"" .. tostring(mode) .. "\". Zones are only sorted with the By Zone sortings.")
	elseif not db.sortZones then
		M.Say("zone sorting is turned off (/qzones on).")
	end
	if not lastIds then
		M.Say("the tracker hasn't listed any quests yet.")
		return
	end
	local copy = {}
	for i, questId in ipairs(lastIds) do copy[i] = questId end
	local order, dist = SortZones(copy, lastDetails)
	M.Say("zones by distance:")
	for i, zone in ipairs(order) do
		print(("  %d. %s - %s"):format(i, tostring(zone), FormatDistance(dist[zone])))
	end
end

local function SetSorting(on)
	db.sortZones = on
	Redraw()
end

local function OnSlash(msg)
	local cmd = msg:lower():match("^%s*(%S*)")
	if cmd == "show" or cmd == "test" then
		ShowOrder()
	elseif cmd == "on" or cmd == "off" then
		SetSorting(cmd == "on")
		M.Say("zone sorting " .. (cmd == "on" and "on." or "off."))
	elseif cmd == "reset" then
		SetSorting(M.defaults.sortZones)
		M.Say("settings reset.")
	elseif cmd == "options" then
		ns.OpenSettings(M)
	else
		M.Say("commands for /qzones:")
		print("  show - list the tracker's zones with their distance")
		print("  on / off - turn zone sorting on or off")
		print("  reset - back to the default settings")
		print("  options - open the settings")
	end
end

M.options = {
	{ type = "checkbox", key = "sortZones", label = "Sort zones by distance", tooltip = "Order the zones in Questie's tracker by their nearest quest objective or turn-in, nearest first. Works with Questie's By Zone sortings.", onChange = Redraw },
	{ type = "button", label = "Zone order", button = "List in chat", tooltip = "Print the tracker's zones with their distance.", func = ShowOrder },
}

--------------------------------------------------------------------------------
-- Start-up
--------------------------------------------------------------------------------

function M:Enable()
	db = self.db
	-- No redraw here: Questie builds its tracker after login and goes through the wrapper then.
	Hook()
	C_Timer.NewTicker(CHECK_EVERY, Check)
end

-- Questie is an optional dependency, so it normally loads first; this covers it loading later.
function M:OnAddonLoaded(name)
	if name == "Questie" and not hooked and Hook() then Redraw() end
end

SLASH_PREDUIQZONES1 = "/qzones"
SlashCmdList.PREDUIQZONES = ns.SlashHandler(M, OnSlash)
