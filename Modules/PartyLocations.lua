--------------------------------------------------------------------------------
-- Party Locations: on the Group Finder's Browse tab, lists a group's members
-- and shows where its leader is, marked "here" (in the dungeon's zone),
-- "inside" or "away", so you can tell whether a group is worth joining.
--
--   * The Group Finder (Blizzard_GroupFinder_VanillaStyle) is load-on-demand,
--     so the panel is built when it loads. It's a child of LFGParentFrame and
--     shows and hides with it. Blizzard's frames are only read, never changed.
--   * Which group: the one under the mouse (hook on Blizzard's group tooltip,
--     LFGBrowseSearchEntryTooltip_UpdateAndShow), else the selected one. While
--     hovering, the panel hangs under that tooltip; otherwise it sits beside
--     the Group Finder.
--   * The leader's zone: C_LFGList.GetSearchResultPlayerInfo(resultID, i)
--     .areaName. The server only fills it in for the leader (tested in-game);
--     other members would need a /who each, which takes a click per lookup
--     and is rate-limited, so they're listed by name only. It can be secret
--     during chat lockdown, so it's guarded like everything else.
--   * Which zone a dungeon is in: Forever doesn't have the Encounter Journal
--     and turns off the map's dungeon entrance pins, so this is learned: each
--     time you enter a dungeon, the zone you were in just before is counted
--     for it (saved account-wide; the zone seen most often wins, so one summon
--     from elsewhere doesn't spoil it). The game's own sources are still tried.
--     Until a dungeon is learned, the panel lists zones without marks.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.Style
local Public, PublicNumber, PublicString, Try = ns.Public, ns.PublicNumber, ns.PublicString, ns.Try

local M = ns.NewModule("partyloc", {
	title = "Party Locations",
	notes = "Shows where a listed group's leader is, on the Group Finder's Browse tab.",
	defaults = {
		show = true,          -- show the panel on the Browse tab
		hover = true,         -- follow the group under the mouse, not just the selected one
	},
})

local GROUP_FINDER = "Blizzard_GroupFinder_VanillaStyle"
local REFRESH_INTERVAL = 1     -- seconds between redraws while the panel is shown
local MAX_ROWS = 10
local ROW_H = 16
local WIDTH = 290              -- room for long zone names ("Hillsbrad Foothills")
local LEADER_ICON = "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:12:12|t"

local ZONE_TYPE = Enum.UIMapType and Enum.UIMapType.Zone or 3

local db
local panel
local testMode = false
local hoveredResult            -- search result under the mouse, while its tooltip shows
local lastZone                 -- uiMapID of the last outdoor zone you were in
local entranceZones            -- [journalInstanceID] = zone uiMapID, built once

--------------------------------------------------------------------------------
-- Maps and zones
--------------------------------------------------------------------------------

local function MapInfo(mapID)
	local info = mapID and Try(C_Map.GetMapInfo, mapID)
	if type(info) == "table" and PublicNumber(info.mapType) then return info end
end

-- The zone a map belongs to (a cave, a city district or a dungeon floor walks
-- up to its zone). Returns zone uiMapID and name, or nil above zone level.
local function ZoneOf(mapID)
	local info = MapInfo(mapID)
	local guard = 0
	while info and info.mapType > ZONE_TYPE and guard < 10 do
		local parent = PublicNumber(info.parentMapID)
		if not parent or parent == 0 then break end
		info = MapInfo(parent)
		guard = guard + 1
	end
	if info and info.mapType == ZONE_TYPE then
		return PublicNumber(info.mapID), PublicString(info.name)
	end
end

local function ZoneName(zoneID)
	local info = MapInfo(zoneID)
	return info and PublicString(info.name)
end

-- Every dungeon entrance the game will tell us about, by journal instance ID.
-- On Forever this is probably empty; it's built once and kept.
local function EntranceZones()
	if entranceZones then return entranceZones end
	entranceZones = {}
	if not (C_EncounterJournal and C_EncounterJournal.GetDungeonEntrancesForMap and C_Map.GetMapChildrenInfo) then
		return entranceZones
	end
	-- Climb from where you are to the top map, then go through all its zones.
	local top = PublicNumber(Try(C_Map.GetBestMapForUnit, "player"))
	local info = MapInfo(top)
	while info and PublicNumber(info.parentMapID) and info.parentMapID ~= 0 do
		top = info.parentMapID
		info = MapInfo(top)
	end
	if not top then return entranceZones end
	local zones = Try(C_Map.GetMapChildrenInfo, top, ZONE_TYPE, true)
	if type(zones) ~= "table" then return entranceZones end
	for _, zone in ipairs(zones) do
		local zoneID = PublicNumber(zone.mapID)
		local entrances = zoneID and Try(C_EncounterJournal.GetDungeonEntrancesForMap, zoneID)
		if type(entrances) == "table" then
			for _, e in ipairs(entrances) do
				local journalID = PublicNumber(e.journalInstanceID)
				if journalID and not entranceZones[journalID] then
					entranceZones[journalID] = zoneID
				end
			end
		end
	end
	return entranceZones
end

-- The learned zone seen most often for an instance.
local function LearnedZone(instanceID)
	local counts = db.zones[instanceID]
	if type(counts) ~= "table" then return end
	local best, bestCount
	for zoneID, count in pairs(counts) do
		if not bestCount or count > bestCount then best, bestCount = zoneID, count end
	end
	return best
end

-- Zone uiMapID of a dungeon (by instance map ID) and where that came from.
local function InstanceZone(instanceID)
	local learned = LearnedZone(instanceID)
	if learned then return learned, "learned" end

	local journalID = C_EncounterJournal and PublicNumber(Try(C_EncounterJournal.GetInstanceForGameMap, instanceID))
	if journalID then
		local zoneID = EntranceZones()[journalID]
		if zoneID then return zoneID, "entrance" end
		local areaMapID = PublicNumber(select(7, Try(EJ_GetInstanceInfo, journalID)))
		zoneID = areaMapID and ZoneOf(areaMapID)
		if zoneID then return zoneID, "journal" end
	end
	return nil, "unknown"
end

-- Learning: called on zone changes. Outside, remember the zone; on entering
-- a dungeon or raid, count that zone for it.
local function TrackZone()
	local inInstance, kind = Try(IsInInstance)
	if not Public(inInstance) then return end
	if not inInstance then
		local zoneID = ZoneOf(PublicNumber(Try(C_Map.GetBestMapForUnit, "player")))
		if zoneID then lastZone = zoneID end
		return
	end
	if not (kind == "party" or kind == "raid") or not lastZone then return end
	local instanceID = PublicNumber(select(8, Try(GetInstanceInfo)))
	if not instanceID then return end
	local counts = db.zones[instanceID]
	if type(counts) ~= "table" then
		counts = {}
		db.zones[instanceID] = counts
	end
	counts[lastZone] = (counts[lastZone] or 0) + 1
	lastZone = nil             -- one count per entry, not per zone change inside
end

--------------------------------------------------------------------------------
-- The listed group
--------------------------------------------------------------------------------

local function ActivityInstance(activityID)
	local info = Try(C_LFGList.GetActivityInfoTable, activityID)
	if type(info) ~= "table" then return end
	local mapID = PublicNumber(info.mapID)
	if not mapID or mapID == 0 then return end
	local name = PublicString(Try(GetRealZoneText, mapID)) or PublicString(info.fullName)
	return mapID, name
end

local function SelectedResult()
	local browse = LFGBrowseFrame
	local selection = browse and browse.selectionBehavior
	if not (selection and Try(selection.HasSelection, selection)) then return end
	local selected = Try(selection.GetSelectedElementData, selection)
	local element = type(selected) == "table" and selected[1]
	return element and element.data and PublicNumber(element.data.resultID)
end

local function CurrentResult()
	if db.hover and hoveredResult then return hoveredResult end
	return SelectedResult()
end

-- The result's dungeon: instance map ID, name, zone uiMapID (or nil) and how
-- many other dungeons the group listed. Prefers one whose zone is known.
local function ResultTarget(result)
	local activities = Public(result.activityIDs) and result.activityIDs
	if type(activities) ~= "table" then return end
	local seen, instances = {}, {}
	for _, activityID in ipairs(activities) do
		local mapID, name = ActivityInstance(activityID)
		if mapID and not seen[mapID] then
			seen[mapID] = true
			instances[#instances + 1] = { mapID = mapID, name = name, zone = (InstanceZone(mapID)) }
		end
	end
	if #instances == 0 then return end
	local pick = instances[1]
	for _, inst in ipairs(instances) do
		if inst.zone then pick = inst break end
	end
	return pick.mapID, pick.name, pick.zone, #instances - 1
end

local function ColoredName(classFile, name)
	local color = classFile and C_ClassColor and Try(C_ClassColor.GetClassColor, classFile)
	if color and color.WrapTextInColorCode then return color:WrapTextInColorCode(name) end
	return name
end

-- "inside", "here", "away", "unknown", or "" when the dungeon's zone isn't known.
local function Status(zone, targetName, targetZoneName)
	if not zone then return "unknown" end
	if targetName and zone == targetName then return "inside" end
	if not targetZoneName then return "" end
	return zone == targetZoneName and "here" or "away"
end

-- Everything the panel shows for one search result, or nil.
local function ReadResult(resultID)
	local result = Try(C_LFGList.GetSearchResultInfo, resultID)
	if type(result) ~= "table" then return end
	local g = { members = {} }
	g.instanceID, g.targetName, g.targetZone, g.others = ResultTarget(result)
	g.targetZoneName = g.targetZone and ZoneName(g.targetZone)

	-- The server only fills in areaName for the leader; the others are listed
	-- by name only.
	local count = PublicNumber(result.numMembers) or 0
	for i = 1, count do
		local info = Try(C_LFGList.GetSearchResultPlayerInfo, resultID, i)
		if type(info) == "table" then
			local name = PublicString(info.name) or UNKNOWN or "?"
			local m = {
				name = ColoredName(PublicString(info.classFilename), name),
				leader = Public(info.isLeader) and info.isLeader == true,
				zone = "",
				status = "",
			}
			if m.leader then
				local zone = PublicString(info.areaName)
				m.zone = zone or ""
				m.status = Status(zone, g.targetName, g.targetZoneName)
				g.leader = m
			end
			g.members[#g.members + 1] = m
		end
	end
	table.sort(g.members, function(a, b)
		if a.leader ~= b.leader then return a.leader end
		return a.name < b.name
	end)
	return g
end

local function FakeResult()
	local leader = { name = "|cffc79c6eTankguy|r", zone = "Westfall", status = "here", leader = true }
	return {
		instanceID = 36, targetName = "Deadmines", targetZone = 0, targetZoneName = "Westfall", others = 0,
		leader = leader,
		members = {
			leader,
			{ name = "|cff3fc7ebFrostbolt|r", zone = "", status = "" },
			{ name = "|cffffffffHealbot|r", zone = "", status = "" },
			{ name = "|cffaad372Pewpew|r", zone = "", status = "" },
		},
	}
end

--------------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------------

local STATUS_TEXT = {
	inside = S.GOOD .. "inside|r",
	here = S.GOOD .. "here|r",
	away = S.WARN .. "away|r",
	unknown = S.DIM .. "?|r",
	[""] = "",
}

local function Place(hovering)
	panel:ClearAllPoints()
	local tip = LFGBrowseSearchEntryTooltip
	if hovering and tip and tip:IsShown() then
		-- Hang under Blizzard's group tooltip, above everything like it.
		panel:SetFrameStrata("TOOLTIP")
		panel:SetPoint("TOPLEFT", tip, "BOTTOMLEFT", 0, -4)
		return
	end
	panel:SetFrameStrata(LFGParentFrame:GetFrameStrata())
	local tab = LFGParentFrame.WhoListingTab
	if tab and tab:IsShown() then
		panel:SetPoint("TOPLEFT", tab, "BOTTOMLEFT", 2, -14)
	else
		panel:SetPoint("TOPLEFT", LFGParentFrame, "TOPRIGHT", 4, -8)
	end
end

local function GetRow(i)
	local row = panel.rows[i]
	if row then return row end
	row = CreateFrame("Frame", nil, panel)
	row:SetHeight(ROW_H)
	row.name = S.Text(row, 12)
	row.name:SetPoint("LEFT")
	row.name:SetWidth(100)
	row.name:SetJustifyH("LEFT")
	row.status = S.Text(row, 11)
	row.status:SetPoint("RIGHT")
	row.status:SetWidth(42)
	row.status:SetJustifyH("RIGHT")
	row.zone = S.Text(row, 11)
	row.zone:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
	row.zone:SetPoint("RIGHT", row.status, "LEFT", -4, 0)
	row.zone:SetJustifyH("LEFT")
	row.zone:SetTextColor(0.75, 0.75, 0.75)
	panel.rows[i] = row
	return row
end

local function YourZoneLine(g)
	local mapID = PublicNumber(Try(C_Map.GetBestMapForUnit, "player"))
	local zoneID, zoneName = ZoneOf(mapID)
	local info = MapInfo(mapID)
	local zone = zoneName or (info and PublicString(info.name))
	if testMode then zone = "Elwynn Forest" end
	if not zone then return "" end
	local status = Status(zone, g.targetName, g.targetZoneName)
	if testMode then status = "away" end
	local mark = STATUS_TEXT[status] or ""
	return S.DIM .. "You: |r" .. zone .. (mark ~= "" and ("  " .. mark) or "")
end

local function Refresh()
	if not panel then return end
	local browsing = LFGParentFrame:IsShown() and LFGBrowseFrame and LFGBrowseFrame:IsShown()
	local resultID = not testMode and browsing and db.show and CurrentResult()
	local g = testMode and FakeResult() or (resultID and ReadResult(resultID))
	if not (g and (testMode or browsing)) then
		panel:Hide()
		return
	end
	Place(not testMode and db.hover and hoveredResult ~= nil and resultID == hoveredResult)

	local title = g.targetName or "?"
	if g.others and g.others > 0 then title = title .. S.DIM .. " +" .. g.others .. "|r" end
	if g.targetZoneName then title = title .. S.DIM .. " - " .. g.targetZoneName .. "|r" end
	panel.heading.text:SetText(title)

	local y = -S.PAD - 20
	local shown = math.min(#g.members, MAX_ROWS)
	for i = 1, shown do
		local m = g.members[i]
		local row = GetRow(i)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", S.PAD, y)
		row:SetPoint("TOPRIGHT", -S.PAD, y)
		row.name:SetText(m.leader and (LEADER_ICON .. m.name) or m.name)
		row.zone:SetText(m.zone)
		row.status:SetText(STATUS_TEXT[m.status] or "")
		row:Show()
		y = y - ROW_H
	end
	for i = shown + 1, #panel.rows do panel.rows[i]:Hide() end

	local status = g.leader and g.leader.status
	local summary
	if #g.members == 0 then
		summary = S.DIM .. "No member info for this group.|r"
	elseif not g.leader or status == "unknown" then
		summary = S.DIM .. "The leader's zone isn't shared.|r"
	elseif status == "inside" or status == "here" then
		summary = S.GOOD .. "The leader is at the dungeon.|r"
	elseif status == "away" then
		summary = S.WARN .. "The leader is away from the dungeon.|r"
	else
		summary = S.DIM .. "Dungeon's zone not known yet. Enter it once and it's learned.|r"
	end
	if #g.members > shown then summary = summary .. S.DIM .. "  (+" .. (#g.members - shown) .. " more)|r" end
	local you = YourZoneLine(g)
	if you ~= "" then summary = summary .. "\n" .. you end

	panel.summary:ClearAllPoints()
	panel.summary:SetPoint("TOPLEFT", S.PAD, y - 4)
	panel.summary:SetPoint("TOPRIGHT", -S.PAD, y - 4)
	panel.summary:SetText(summary)
	panel:SetHeight(-y + 4 + panel.summary:GetStringHeight() + S.PAD)
	panel:Show()
end

local queued = false
local function QueueRefresh()
	if queued then return end
	queued = true
	C_Timer.After(0.05, function()
		queued = false
		Refresh()
	end)
end

local function BuildPanel()
	if panel or not LFGParentFrame then return end
	panel = CreateFrame("Frame", "PredUIPartyLocations", LFGParentFrame)
	panel:SetSize(WIDTH, 80)
	panel:Hide()
	S.Body(panel)
	S.Glow(panel)
	panel.rows = {}
	panel.heading = S.Heading(panel, "", -S.PAD)
	panel.summary = S.Text(panel, 11)
	panel.summary:SetJustifyH("LEFT")
	panel.summary:SetWordWrap(true)

	-- Members move around; redraw while shown, and only then.
	local elapsed = 0
	panel:SetScript("OnUpdate", function(_, delta)
		elapsed = elapsed + delta
		if elapsed < REFRESH_INTERVAL then return end
		elapsed = 0
		Refresh()
	end)

	LFGParentFrame:HookScript("OnShow", QueueRefresh)
	LFGParentFrame:HookScript("OnHide", function() testMode = false hoveredResult = nil end)
	for _, frame in ipairs({ LFGListingFrame, LFGBrowseFrame, LFGWhoListFrame }) do
		if frame then
			frame:HookScript("OnShow", QueueRefresh)
			frame:HookScript("OnHide", QueueRefresh)
		end
	end
	-- Blizzard calls this by name from each result's OnEnter, so the hook sees
	-- every hover. Refresh right away so the panel moves with the tooltip.
	if LFGBrowseSearchEntryTooltip_UpdateAndShow then
		hooksecurefunc("LFGBrowseSearchEntryTooltip_UpdateAndShow", function(_, resultID)
			hoveredResult = PublicNumber(resultID)
			Refresh()
		end)
	end
	if LFGBrowseSearchEntryTooltip then
		LFGBrowseSearchEntryTooltip:HookScript("OnHide", function()
			hoveredResult = nil
			Refresh()
		end)
	end
	if LFGBrowseFrame and LFGBrowseFrame.UpdateButtonState then
		-- Runs on every selection change.
		hooksecurefunc(LFGBrowseFrame, "UpdateButtonState", QueueRefresh)
	end
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local function OpenGroupFinder()
	if not LFGParentFrame then Try(GroupFinderVanillaStyle_LoadUI) end
	if not LFGParentFrame then
		M.Say("the Group Finder isn't available on this character.")
		return false
	end
	BuildPanel()
	if not LFGParentFrame:IsShown() and LFGVanilla_ShowFrame then
		LFGVanilla_ShowFrame(LFGPARENT_BROWSING_TAB_INDEX or 2)
	end
	return true
end

local function PrintZones()
	local resultID = CurrentResult()
	local result = resultID and Try(C_LFGList.GetSearchResultInfo, resultID)
	local activities = type(result) == "table" and Public(result.activityIDs) and result.activityIDs
	if type(activities) ~= "table" or #activities == 0 then
		M.Say("select a group on the Browse tab first.")
		return
	end
	local seen = {}
	for _, activityID in ipairs(activities) do
		local mapID, name = ActivityInstance(activityID)
		if mapID and not seen[mapID] then
			seen[mapID] = true
			local zoneID, source = InstanceZone(mapID)
			M.Say(("%s (%d): %s, from %s"):format(name or "?", mapID, zoneID and (ZoneName(zoneID) or zoneID) or "zone unknown", source))
		end
	end
	local n = 0
	for _ in pairs(EntranceZones()) do n = n + 1 end
	M.Say(("the game knows %d dungeon entrances here."):format(n))
end

local function OnSlash(msg)
	msg = msg:lower():match("^%s*(.-)%s*$")
	if msg == "test" then
		testMode = not testMode
		if testMode and not OpenGroupFinder() then testMode = false end
		Refresh()
	elseif msg == "zones" then
		PrintZones()
	elseif msg == "forget" then
		ns.Confirm("Forget every dungeon zone Party Locations has learned?", function()
			wipe(db.zones)
			QueueRefresh()
			M.Say("learned zones cleared.")
		end)
	elseif msg == "options" then
		ns.OpenSettings(M)
	elseif msg == "" then
		OpenGroupFinder()
	else
		M.Say("Commands:")
		print("  /partyloc - open the Group Finder's Browse tab")
		print("  /partyloc test - show the panel with a made-up group")
		print("  /partyloc zones - which zone the selected group's dungeon is in, and where that came from")
		print("  /partyloc forget - forget learned dungeon zones")
		print("  /partyloc options - settings")
	end
end

M.options = {
	{ type = "checkbox", key = "show", label = "Show the panel", tooltip = "On the Browse tab, show the selected group's members and where its leader is.", onChange = QueueRefresh },
	{ type = "checkbox", key = "hover", label = "Follow the mouse", tooltip = "Show the group under the mouse (under its tooltip), not just the selected one.", onChange = QueueRefresh },
	{ type = "button", label = "Preview", button = "Test", tooltip = "Show the panel with a made-up group. Also /partyloc test.", func = function() OnSlash("test") end },
	{ type = "button", label = "Learned zones", button = "Forget", tooltip = "Forget which zone each dungeon is in. It's learned again as you enter them.", func = function() OnSlash("forget") end },
}

--------------------------------------------------------------------------------
-- Start-up
--------------------------------------------------------------------------------

function M:OnAddonLoaded(name)
	if name == GROUP_FINDER then BuildPanel() end
end

function M:Enable()
	db = self.db
	if type(rawget(db, "zones")) ~= "table" then db.zones = {} end

	BuildPanel()               -- in case the Group Finder loaded before us

	local events = CreateFrame("Frame")
	events:RegisterEvent("PLAYER_ENTERING_WORLD")
	events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	events:RegisterEvent("ZONE_CHANGED")
	events:RegisterEvent("LFG_LIST_SEARCH_RESULT_UPDATED")
	events:SetScript("OnEvent", function(_, event)
		if event ~= "LFG_LIST_SEARCH_RESULT_UPDATED" then TrackZone() end
		QueueRefresh()
	end)
end

SLASH_PREDUIPARTYLOC1 = "/partyloc"
SlashCmdList.PREDUIPARTYLOC = ns.SlashHandler(M, OnSlash)
