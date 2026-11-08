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
--   * Filters: a bar under the Group Finder hides listings by size (min/max
--     players), solo players, groups with no open slot for a role you ticked,
--     and words in the leader's name, title or comment. Blizzard builds the
--     list as GetFilteredSearchResults -> LFGBrowseUtil_SortSearchResults(t)
--     -> draw from t, so a post-hook on the sort removes entries from t in
--     place (the order stays). Editing that table taints the list build, so
--     it's only touched while a filter is on, and your own listing is never
--     hidden. Anything we can't read (secret, missing) keeps the group shown.
--     Titles and comments are "kstring" values that may come back protected
--     (|K...|k) and unreadable; then only the leader's name is searched
--     (/partyloc filters tells which).
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.Style
local Public, PublicNumber, PublicString, Try = ns.Public, ns.PublicNumber, ns.PublicString, ns.Try

local M = ns.NewModule("partyloc", {
	title = "Party Locations",
	notes = "Shows where a listed group's leader is, and filters the Group Finder's Browse list by group size, role and text.",
	defaults = {
		show = true,          -- show the panel on the Browse tab
		hover = true,         -- follow the group under the mouse, not just the selected one
		filterBar = true,     -- show the filter bar under the Group Finder
		minPlayers = 0,       -- 0 = no limit
		maxPlayers = 0,       -- 0 = no limit
		noSolo = false,       -- hide single players looking for a group
		myRole = false,       -- hide groups with no open slot for a role you ticked
		search = "",          -- words that must all appear (leader, title, comment)
	},
})

local GROUP_FINDER = "Blizzard_GroupFinder_VanillaStyle"
local REFRESH_INTERVAL = 1     -- seconds between redraws while the panel is shown
local MAX_ROWS = 10
local ROW_H = 16
local WIDTH = 290              -- room for long zone names ("Hillsbrad Foothills")
local LEADER_ICON = "|TInterface\\GroupFrame\\UI-Group-LeaderIcon:12:12|t"

local ZONE_TYPE = Enum.UIMapType and Enum.UIMapType.Zone or 3

local MAX_PLAYERS = 40         -- largest raid
local FILTER_DELAY = 0.3       -- seconds after the last keystroke before the list reruns

local db
local panel
local bar                      -- the filter bar
local testMode = false
local QueueRefresh             -- defined with the panel
local stats = { hidden = 0, total = 0 }
local textReadable             -- nil = not seen yet; true/false = titles/comments readable
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
-- Filters
--------------------------------------------------------------------------------

local function Words(text)
	local words = {}
	for w in tostring(text or ""):lower():gmatch("%S+") do words[#words + 1] = w end
	return words
end

-- The filters as they apply now: min/max (0 = none, swapped if reversed),
-- noSolo, roles (the ticked roles, or nil) and words.
local function CurrentFilters()
	local f = {
		min = math.max(0, math.floor(tonumber(db.minPlayers) or 0)),
		max = math.max(0, math.floor(tonumber(db.maxPlayers) or 0)),
		noSolo = db.noSolo and true or false,
		words = Words(db.search),
	}
	if f.min > 0 and f.max > 0 and f.min > f.max then f.min, f.max = f.max, f.min end
	if db.myRole and C_LFGListRoles then
		local roles = Try(C_LFGListRoles.GetRoles)
		if type(roles) == "table" and Public(roles.tank) then
			local tank, healer, dps = roles.tank == true, roles.healer == true, roles.dps == true
			if tank or healer or dps then f.roles = { tank = tank, healer = healer, dps = dps } end
		end
	end
	return f
end

local function FiltersActive()
	return (tonumber(db.minPlayers) or 0) > 0 or (tonumber(db.maxPlayers) or 0) > 0
		or db.noSolo or db.myRole or #Words(db.search) > 0
end

-- Text we can search: plain, not secret and not a protected |K string.
local function Readable(s)
	s = PublicString(s)
	if s and not s:find("|K", 1, true) then return s end
end

local function Remaining(counts, key)
	return PublicNumber(counts[key])
end

-- Does one search result pass? Unreadable values keep it.
local function Passes(resultID, f)
	local info = Try(C_LFGList.GetSearchResultInfo, resultID)
	if type(info) ~= "table" then return true end
	if Public(info.hasSelf) and info.hasSelf == true then return true end

	local n = PublicNumber(info.numMembers)
	if n then
		if f.min > 0 and n < f.min then return false end
		if f.max > 0 and n > f.max then return false end
		if f.noSolo and n <= 1 then return false end
	end

	if f.roles and n and n > 1 then
		local counts = Try(C_LFGList.GetSearchResultMemberCounts, resultID)
		if type(counts) == "table" and Public(counts) then
			local tank = Remaining(counts, "TANK_REMAINING")
			local healer = Remaining(counts, "HEALER_REMAINING")
			local dps = Remaining(counts, "DAMAGER_REMAINING")
			if tank or healer or dps then
				local fits = (f.roles.tank and (tank or 0) > 0)
					or (f.roles.healer and (healer or 0) > 0)
					or (f.roles.dps and (dps or 0) > 0)
				if not fits then return false end
			end
		end
	end

	if #f.words > 0 then
		local parts = {}
		local leader = Readable(info.leaderName)
		if leader then parts[#parts + 1] = leader:lower() end
		for _, key in ipairs({ "name", "comment" }) do
			local raw = info[key]
			local s = Readable(raw)
			if s then
				parts[#parts + 1] = s:lower()
				textReadable = true
			elseif (not Public(raw) or (raw ~= nil and raw ~= "")) and textReadable == nil then
				textReadable = false
			end
		end
		local text = table.concat(parts, "\n")
		for _, w in ipairs(f.words) do
			if not text:find(w, 1, true) then return false end
		end
	end
	return true
end

-- Post-hook on LFGBrowseUtil_SortSearchResults(results): drop what doesn't pass.
local hiddenIDs = {}            -- [resultID] = true for what the last pass hid

local function ApplyFilters(results)
	if not db or type(results) ~= "table" or not Public(results) then return end
	stats.total, stats.hidden = #results, 0
	wipe(hiddenIDs)
	if FiltersActive() then
		local f = CurrentFilters()
		for i = #results, 1, -1 do
			local resultID = results[i]
			if not Passes(resultID, f) then
				table.remove(results, i)
				stats.hidden = stats.hidden + 1
				if PublicNumber(resultID) then hiddenIDs[resultID] = true end
			end
		end
	end
	if QueueRefresh then QueueRefresh() end
end

-- Redraw Blizzard's list from the results it already has (no new search).
local rerunTimer
local function RerunList()
	if rerunTimer then rerunTimer:Cancel() end
	rerunTimer = C_Timer.NewTimer(FILTER_DELAY, function()
		rerunTimer = nil
		local browse = LFGBrowseFrame
		if browse and browse:IsShown() and browse.UpdateResultList then
			Try(browse.UpdateResultList, browse)
		end
		if QueueRefresh then QueueRefresh() end
	end)
end

local SyncBar                  -- defined with the bar

-- A listed group changed (someone joined or left). Blizzard updates that row
-- without rebuilding the list, so the filters never see it: if it should now
-- be hidden, or shown again, redraw the list.
local function ResultChanged(resultID)
	resultID = PublicNumber(resultID)
	if not (resultID and db and FiltersActive()) then return end
	local passes = Passes(resultID, CurrentFilters())
	if passes == (hiddenIDs[resultID] == true) then RerunList() end
end

local function FiltersChanged()
	if SyncBar then SyncBar() end
	RerunList()
end

local function ClearFilters()
	db.minPlayers, db.maxPlayers, db.noSolo, db.myRole, db.search = 0, 0, false, false, ""
	FiltersChanged()
end

-- Whether titles/comments can be searched, from the current results.
local function ProbeText()
	local _, results = Try(C_LFGList.GetFilteredSearchResults)
	if type(results) ~= "table" or not Public(results) then return textReadable end
	for _, resultID in ipairs(results) do
		local info = Try(C_LFGList.GetSearchResultInfo, resultID)
		if type(info) == "table" then
			for _, key in ipairs({ "name", "comment" }) do
				local raw = info[key]
				if Readable(raw) then textReadable = true return true end
				if not Public(raw) or (raw ~= nil and raw ~= "") then textReadable = false end
			end
		end
	end
	return textReadable
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

-- Beside the Group Finder (under its Who tab when that shows).
local function PlaceBeside(frame)
	frame:ClearAllPoints()
	local tab = LFGParentFrame.WhoListingTab
	if tab and tab:IsShown() then
		frame:SetPoint("TOPLEFT", tab, "BOTTOMLEFT", 2, -14)
	else
		frame:SetPoint("TOPLEFT", LFGParentFrame, "TOPRIGHT", 4, -8)
	end
end

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
	PlaceBeside(panel)
end

--------------------------------------------------------------------------------
-- Filter bar
--------------------------------------------------------------------------------

local function Tip(frame, text)
	frame:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(type(text) == "function" and text() or text, nil, nil, nil, nil, true)
		GameTooltip:Show()
	end)
	frame:SetScript("OnLeave", GameTooltip_Hide)
end

local function SearchTip()
	local s = "Only groups whose leader, title or comment has all these words."
	if textReadable == false then
		s = s .. "\n\n" .. S.WARN .. "The game hides group titles and comments from addons here, so only the leader's name is searched.|r"
	end
	return s
end

local function NumberBox(key)
	local e = S.EditBox(bar, 30, 20)
	e:SetNumeric(true)
	e:SetMaxLetters(2)
	e:SetJustifyH("CENTER")
	e:SetTextInsets(2, 2, 0, 0)
	e:SetScript("OnEnterPressed", e.ClearFocus)
	e:SetScript("OnTextChanged", function(self, userInput)
		if not userInput then return end
		db[key] = math.min(MAX_PLAYERS, tonumber(self:GetText()) or 0)
		RerunList()
	end)
	e:HookScript("OnEditFocusLost", function() SyncBar() end)
	return e
end

local function Check(key, label, tooltip)
	local c = CreateFrame("CheckButton", nil, bar, "UICheckButtonTemplate")
	c:SetSize(22, 22)
	c.label = S.Text(bar, 11)
	c.label:SetPoint("LEFT", c, "RIGHT", 1, 1)
	c.label:SetText(label)
	c:SetScript("OnClick", function(self)
		db[key] = self:GetChecked() and true or false
		FiltersChanged()
	end)
	Tip(c, tooltip)
	return c
end

local function BuildBar()
	if bar or not LFGParentFrame then return end
	bar = CreateFrame("Frame", "PredUIPartyFilters", LFGParentFrame)
	-- Under the Group Finder: Blizzard's group tooltip opens to its right,
	-- beside the hovered row, so anything there gets covered.
	bar:SetHeight(64)
	bar:SetPoint("TOPLEFT", LFGParentFrame, "BOTTOMLEFT", 4, -6)
	bar:SetPoint("TOPRIGHT", LFGParentFrame, "BOTTOMRIGHT", -4, -6)
	bar:Hide()
	S.Body(bar)
	S.Glow(bar)

	local players = S.Text(bar, 12)
	players:SetPoint("TOPLEFT", S.PAD, -14)
	players:SetText("Players")
	bar.min = NumberBox("minPlayers")
	bar.min:SetPoint("LEFT", players, "RIGHT", 8, 0)
	local to = S.Text(bar, 11)
	to:SetPoint("LEFT", bar.min, "RIGHT", 6, 0)
	to:SetText("to")
	bar.max = NumberBox("maxPlayers")
	bar.max:SetPoint("LEFT", to, "RIGHT", 6, 0)
	Tip(bar.min, "Hide groups with fewer players than this. Empty means no limit.")
	Tip(bar.max, "Hide groups with more players than this. Empty means no limit.")

	local clear = S.Button(bar, "Clear", 54, 20)
	clear:SetPoint("TOPRIGHT", -S.PAD, -10)
	clear.tooltip = "Turn every filter off."
	clear:SetScript("OnClick", ClearFilters)

	bar.search = S.EditBox(bar, 10, 20)
	bar.search:SetPoint("TOPLEFT", S.PAD, -36)
	bar.search:SetPoint("TOPRIGHT", -130, -36)
	bar.search:SetMaxLetters(60)
	bar.search:SetScript("OnEnterPressed", bar.search.ClearFocus)
	bar.search.hint = S.Text(bar.search, 11)
	bar.search.hint:SetPoint("LEFT", 6, 0)
	bar.search.hint:SetText("Search leader, title or comment")
	bar.search.hint:SetTextColor(0.5, 0.5, 0.5)
	local function Hint(self) self.hint:SetShown(self:GetText() == "" and not self:HasFocus()) end
	bar.search:SetScript("OnTextChanged", function(self, userInput)
		Hint(self)
		if not userInput then return end
		db.search = self:GetText()
		RerunList()
	end)
	bar.search:HookScript("OnEditFocusGained", Hint)
	bar.search:HookScript("OnEditFocusLost", Hint)
	Tip(bar.search, SearchTip)

	bar.noSolo = Check("noSolo", "No solo", "Hide single players looking for a group.")
	bar.noSolo:SetPoint("LEFT", bar.max, "RIGHT", 14, 0)
	bar.myRole = Check("myRole", "My role", "Hide groups with no open slot for any role you ticked in the Group Finder.")
	bar.myRole:SetPoint("LEFT", bar.noSolo.label, "RIGHT", 10, -1)

	bar.status = S.Text(bar, 11)
	bar.status:SetPoint("LEFT", bar.search, "RIGHT", 8, 0)
	bar.status:SetPoint("RIGHT", -S.PAD, 0)
	bar.status:SetJustifyH("RIGHT")
end

function SyncBar()
	if not bar then return end
	local function Num(v) v = tonumber(v) or 0 return v > 0 and tostring(v) or "" end
	if not bar.min:HasFocus() then bar.min:SetText(Num(db.minPlayers)) end
	if not bar.max:HasFocus() then bar.max:SetText(Num(db.maxPlayers)) end
	if not bar.search:HasFocus() then bar.search:SetText(db.search or "") end
	bar.noSolo:SetChecked(db.noSolo and true or false)
	bar.myRole:SetChecked(db.myRole and true or false)
end

local function StatusLine()
	if testMode then return S.WARN .. "3|r of 17 hidden" end
	if not FiltersActive() then return S.DIM .. "No filters|r" end
	if stats.total > 0 and stats.hidden == stats.total then
		return S.WARN .. "All " .. stats.total .. " hidden|r"
	end
	if stats.hidden == 0 then return S.DIM .. "None hidden|r" end
	return S.WARN .. stats.hidden .. "|r of " .. stats.total .. " hidden"
end

local function UpdateBar(browsing)
	if not bar then return end
	if not (db.filterBar and (browsing or testMode)) then
		bar:Hide()
		return
	end
	if not bar:IsShown() then SyncBar() end
	bar.status:SetText(StatusLine())
	bar:Show()
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
	UpdateBar(browsing)
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
function QueueRefresh()
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
	BuildBar()

	-- Blizzard sorts the results right before drawing them; filter there.
	if LFGBrowseUtil_SortSearchResults then
		hooksecurefunc("LFGBrowseUtil_SortSearchResults", ApplyFilters)
	end

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

M.launcher = {
	{ icon = "Interface\\Icons\\INV_Misc_GroupNeedMore", label = "Group Finder", hint = "Browse and filter listed groups and see where their leaders are (/partyloc).", func = OpenGroupFinder },
}

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

local function PrintFilters()
	local f = CurrentFilters()
	local size
	if f.min > 0 and f.max > 0 then size = f.min .. " to " .. f.max
	elseif f.min > 0 then size = f.min .. " or more"
	elseif f.max > 0 then size = f.max .. " or fewer"
	else size = "any" end
	M.Say("filters:")
	print("  Players: " .. size)
	print("  No solo: " .. (f.noSolo and "on" or "off"))
	local roleText = "off"
	if db.myRole then
		if f.roles then
			local names = {}
			if f.roles.tank then names[#names + 1] = "tank" end
			if f.roles.healer then names[#names + 1] = "healer" end
			if f.roles.dps then names[#names + 1] = "damage" end
			roleText = "on (" .. table.concat(names, ", ") .. ")"
		else
			roleText = "on, but no role is ticked in the Group Finder, so it does nothing"
		end
	end
	print("  My role: " .. roleText)
	print("  Search: " .. (#f.words > 0 and table.concat(f.words, " ") or "none"))
	print("  Hidden: " .. (FiltersActive() and (stats.hidden .. " of " .. stats.total) or "nothing"))
	local readable = ProbeText()
	if readable == true then
		print("  Group titles and comments can be searched.")
	elseif readable == false then
		print("  Group titles and comments are hidden from addons; only leader names are searched.")
	else
		print("  Search a category first to see whether titles and comments can be searched.")
	end
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
	elseif msg == "filters" then
		PrintFilters()
	elseif msg == "clear" then
		ClearFilters()
		M.Say("filters cleared.")
	elseif msg == "options" then
		ns.OpenSettings(M)
	elseif msg == "" then
		OpenGroupFinder()
	else
		M.Say("Commands:")
		print("  /partyloc - open the Group Finder's Browse tab")
		print("  /partyloc test - show the panel with a made-up group")
		print("  /partyloc zones - which zone the selected group's dungeon is in, and where that came from")
		print("  /partyloc filters - show the filters and what they hide")
		print("  /partyloc clear - turn every filter off")
		print("  /partyloc forget - forget learned dungeon zones")
		print("  /partyloc options - settings")
	end
end

M.options = {
	{ type = "header", label = "Members panel" },
	{ type = "checkbox", key = "show", label = "Show the panel", tooltip = "On the Browse tab, show the selected group's members and where its leader is.", onChange = QueueRefresh },
	{ type = "checkbox", key = "hover", label = "Follow the mouse", tooltip = "Show the group under the mouse (under its tooltip), not just the selected one.", onChange = QueueRefresh },
	{ type = "button", label = "Preview", button = "Test", tooltip = "Show the panel with a made-up group. Also /partyloc test.", func = function() OnSlash("test") end },
	{ type = "button", label = "Learned zones", button = "Forget", tooltip = "Forget which zone each dungeon is in. It's learned again as you enter them.", func = function() OnSlash("forget") end },
	{ type = "header", label = "Filters", tooltip = "Hide listings on the Browse tab. Also on the bar under the Group Finder." },
	{ type = "checkbox", key = "filterBar", label = "Show the filter bar", tooltip = "A bar under the Group Finder's Browse tab with the filters below and a text search. Filters still apply when it's hidden.", onChange = QueueRefresh },
	{ type = "slider", key = "minPlayers", label = "Fewest players", min = 0, max = MAX_PLAYERS, step = 1, format = function(v) return v == 0 and "Any" or tostring(v) end, tooltip = "Hide groups with fewer players than this.", onChange = FiltersChanged },
	{ type = "slider", key = "maxPlayers", label = "Most players", min = 0, max = MAX_PLAYERS, step = 1, format = function(v) return v == 0 and "Any" or tostring(v) end, tooltip = "Hide groups with more players than this.", onChange = FiltersChanged },
	{ type = "checkbox", key = "noSolo", label = "Hide solo players", tooltip = "Hide single players looking for a group.", onChange = FiltersChanged },
	{ type = "checkbox", key = "myRole", label = "Only groups with a slot for my role", tooltip = "Hide groups with no open slot for any role you ticked in the Group Finder.", onChange = FiltersChanged },
	{ type = "button", label = "All filters", button = "Clear", tooltip = "Turn every filter off. Also /partyloc clear.", func = function() OnSlash("clear") end },
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
	events:SetScript("OnEvent", function(_, event, ...)
		if event == "LFG_LIST_SEARCH_RESULT_UPDATED" then
			ResultChanged(...)
		else
			TrackZone()
		end
		QueueRefresh()
	end)
end

SLASH_PREDUIPARTYLOC1 = "/partyloc"
SlashCmdList.PREDUIPARTYLOC = ns.SlashHandler(M, OnSlash)
