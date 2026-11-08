--------------------------------------------------------------------------------
-- AddonCheck scenario for the Party Locations filters (Modules/PartyLocations.lua).
-- node "D:/Games/World of Warcraft/AddonCheck/check.js" PredUI --scenario PredUI/Tools/checks/party-filters.lua

local results = {
	[1] = { numMembers = 1, leaderName = "Solo", name = "LFG", comment = "", hasSelf = false },
	[2] = { numMembers = 3, leaderName = "Tankguy", name = "Deadmines run", comment = "need heals", hasSelf = false },
	[3] = { numMembers = 5, leaderName = "Fullgroup", name = "Full", comment = "", hasSelf = false },
	[4] = { numMembers = 2, leaderName = "Me", name = "Mine", comment = "", hasSelf = true },
	[5] = { numMembers = 4, leaderName = "Raider", name = "Wailing Caverns", comment = "", hasSelf = false },
}
local counts = {
	[2] = { TANK_REMAINING = 0, HEALER_REMAINING = 1, DAMAGER_REMAINING = 1 },
	[3] = { TANK_REMAINING = 0, HEALER_REMAINING = 0, DAMAGER_REMAINING = 0 },
	[4] = { TANK_REMAINING = 1, HEALER_REMAINING = 1, DAMAGER_REMAINING = 1 },
	[5] = { TANK_REMAINING = 1, HEALER_REMAINING = 0, DAMAGER_REMAINING = 0 },
}
local roles = { tank = false, healer = true, dps = false }

rawset(G.C_LFGList, "GetSearchResultInfo", function(id) return results[id] end)
rawset(G.C_LFGList, "GetSearchResultMemberCounts", function(id) return counts[id] end)
rawset(G.C_LFGList, "GetFilteredSearchResults", function() return 5, { 1, 2, 3, 4, 5 } end)
if not G.C_LFGListRoles then rawset(G, "C_LFGListRoles", {}) end
rawset(G.C_LFGListRoles, "GetRoles", function() return roles end)

local db = G.PredUIDB and G.PredUIDB.partyloc
expect(db ~= nil, "Party Locations should have its saved settings")
if not db then return end

local sort = G.LFGBrowseUtil_SortSearchResults
expect(type(sort) == "function", "LFGBrowseUtil_SortSearchResults should exist once the Group Finder loads")
if type(sort) ~= "function" then return end

local function Run()
	local t = { 1, 2, 3, 4, 5 }
	sort(t)
	local set = {}
	for _, id in ipairs(t) do set[#set + 1] = id end
	table.sort(set)
	return table.concat(set, ",")
end

local function Reset()
	db.minPlayers, db.maxPlayers, db.noSolo, db.myRole, db.search = 0, 0, false, false, ""
end

Reset()
expect(Run() == "1,2,3,4,5", "no filters should keep everything, got " .. Run())

db.minPlayers = 3
expect(Run() == "2,3,4,5", "min 3 should hide the solo, keep own listing, got " .. Run())

db.maxPlayers = 4
expect(Run() == "2,4,5", "3 to 4 should keep 2,4(own),5, got " .. Run())

db.minPlayers, db.maxPlayers = 4, 3
expect(Run() == "2,4,5", "reversed min/max should be swapped, got " .. Run())

Reset()
db.noSolo = true
expect(Run() == "2,3,4,5", "no solo should hide 1, got " .. Run())

Reset()
db.myRole = true
expect(Run() == "1,2,4", "healer slot should keep 2, own listing and the solo, got " .. Run())
roles = { tank = false, healer = false, dps = false }
expect(Run() == "1,2,3,4,5", "no ticked role should filter nothing, got " .. Run())
roles = { tank = false, healer = true, dps = false }

Reset()
db.search = "DEADMINES"
expect(Run() == "2,4", "search should match the title, any case, got " .. Run())
db.search = "tankguy heals"
expect(Run() == "2,4", "all words should have to match, got " .. Run())
db.search = "tankguy nothing"
expect(Run() == "4", "a missing word should hide it, got " .. Run())

-- Secret values keep the group.
Reset()
results[1].numMembers = Secret()
db.minPlayers = 3
expect(Run() == "1,2,3,4,5", "a secret size should keep the group, got " .. Run())
results[1].numMembers = 1
results[2].name = Secret()
db.minPlayers, db.search = 0, "deadmines"
expect(Run() == "4", "a secret title can't match, got " .. Run())
results[2].name = "Deadmines run"

-- A group that grows past the max after the list was built gets the list redrawn.
local browse = G.LFGBrowseFrame
if browse then
	local reruns = 0
	rawset(browse, "UpdateResultList", function() reruns = reruns + 1 end)
	rawset(browse, "IsShown", function() return true end)
	Reset()
	db.maxPlayers = 4
	Run()                      -- hides 3 (5 players)
	Fire("LFG_LIST_SEARCH_RESULT_UPDATED", 5)  -- 5 still fits: no redraw
	Tick(0.5)
	expect(reruns == 0, "an unchanged group shouldn't redraw the list, got " .. reruns)
	results[2].numMembers = 5
	Fire("LFG_LIST_SEARCH_RESULT_UPDATED", 2)
	Tick(0.5)
	expect(reruns == 1, "a group grown past the max should redraw the list, got " .. reruns)
	results[2].numMembers = 3
	Run()
	results[3].numMembers = 4
	Fire("LFG_LIST_SEARCH_RESULT_UPDATED", 3)
	Tick(0.5)
	expect(reruns == 2, "a hidden group that now fits should redraw the list, got " .. reruns)
	results[3].numMembers = 5
else
	note("LFGBrowseFrame stand-in can't be shown; per-group recheck not tested")
end

-- The bar and commands.
Reset()
G.SlashCmdList.PREDUIPARTYLOC("filters")
G.SlashCmdList.PREDUIPARTYLOC("clear")
G.SlashCmdList.PREDUIPARTYLOC("test")
Tick(0.5)
local bar = G.PredUIPartyFilters
expect(bar ~= nil, "the filter bar should be built with the Group Finder")
if bar then expect(bar:IsShown(), "the filter bar should show in test mode") end
G.SlashCmdList.PREDUIPARTYLOC("test")
Tick(0.5)
