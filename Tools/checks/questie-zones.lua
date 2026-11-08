--------------------------------------------------------------------------------
-- AddonCheck scenario for Questie Zones (Modules/QuestieZones.lua).
-- node "D:/Games/World of Warcraft/AddonCheck/check.js" PredUI --scenario PredUI/Tools/checks/questie-zones.lua
--
-- A fake Questie: TrackerUtils:GetSortedQuestIds returns quests sorted A-Z by
-- zone, DistanceUtils gives each quest a distance. Questie "loads" after
-- PredUI here, so this also covers the late-load path.

local DIST = { [1] = 900, [2] = 50, [3] = 300, [5] = 500020, [7] = 120 }
local ZONE = { [1] = "Ashenvale", [2] = "Ashenvale", [3] = "Darkshore", [4] = "Elwynn", [5] = "Stonetalon", [6] = "Barrens", [7] = "Barrens" }
local ALPHA = { 1, 2, 6, 7, 3, 4, 5 } -- Questie's A-Z zone order

local modules = {
	TrackerUtils = {},
	QuestieTracker = { updates = 0 },
	DistanceUtils = {},
	QuestieCombatQueue = {},
}
function modules.TrackerUtils:GetSortedQuestIds()
	local ids, details = {}, {}
	for i, id in ipairs(ALPHA) do
		ids[i] = id
		details[id] = { quest = { Id = id, broken = id == 6 }, zoneName = ZONE[id] }
	end
	return ids, details
end
function modules.DistanceUtils.GetNearestSpawnForQuest(quest)
	if quest.broken then error("no spawn data") end
	return nil, nil, nil, DIST[quest.Id] or 999999999
end
function modules.QuestieTracker:Update() self.updates = self.updates + 1 end
function modules.QuestieCombatQueue:Queue(fn) fn(); return true end

rawset(G, "QuestieLoader", { ImportModule = function(_, name) return modules[name] end })
rawset(G, "Questie", { db = { profile = { trackerSortObjectives = "byZone" } } })
Fire("ADDON_LOADED", "Questie")

local utils = modules.TrackerUtils
local function Order()
	local ids = utils:GetSortedQuestIds()
	return table.concat(ids, ",")
end

-- Ashenvale 50, Barrens 120, Darkshore 300, Stonetalon (other continent), Elwynn (no location)
expect(Order() == "1,2,6,7,3,5,4", "By Zone: zones should be nearest first, got " .. Order())

G.Questie.db.profile.trackerSortObjectives = "byZonePlayerProximity"
expect(Order() == "1,2,6,7,3,5,4", "By Zone Prox: zones should be nearest first, got " .. Order())

G.Questie.db.profile.trackerSortObjectives = "byLevel"
expect(Order() == "1,2,6,7,3,4,5", "By Level: order should be Questie's own, got " .. Order())

G.Questie.db.profile.trackerSortObjectives = "byZone"
G.SlashCmdList.PREDUIQZONES("off")
expect(Order() == "1,2,6,7,3,4,5", "/qzones off: order should be Questie's own, got " .. Order())
expect(modules.QuestieTracker.updates > 0, "/qzones off should redraw the tracker")
G.SlashCmdList.PREDUIQZONES("on")
expect(Order() == "1,2,6,7,3,5,4", "/qzones on: zones should be sorted again, got " .. Order())
G.SlashCmdList.PREDUIQZONES("show")
G.SlashCmdList.PREDUIQZONES("")
Tick(6)

note("questie-zones: " .. (failures() == 0 and "all checks passed" or failures() .. " failed"))
