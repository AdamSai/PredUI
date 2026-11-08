--------------------------------------------------------------------------------
-- Invite Whispers: when someone whispers you for an invite ("inv", "invite",
-- "inv pls"...), lists them in a small window with their level and class, and
-- an Invite button, and tags their whisper in chat with the level.
--
--   * The game doesn't tell addons a stranger's level from a whisper. The
--     level is filled in from what the game already knows, without asking
--     the server: your group, your friends list, your guild roster, members
--     of the groups listed in the Group Finder, and /who results seen this
--     session (yours or PredUI's).
--   * Otherwise the row has a Who button. C_FriendList.SendWho only works
--     from a click (HasRestrictions) and the server rate-limits it, so it's
--     never sent on its own. An exact-name /who answers in chat as a system
--     message ("[Name]: Level 32 ..."), which is read here; a bigger answer
--     comes as WHO_LIST_UPDATE, which is read too.
--   * The class comes from the whisper's GUID (GetPlayerInfoByGUID), so it's
--     known even when the level isn't.
--   * Names: Forever names have surnames, and the separator differs between
--     chat links and other lists, so names are compared with spaces and
--     dashes taken out.
--   * Whispers can be secret during chat lockdown (combat, encounters); those
--     are left alone.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.Style
local Public, PublicNumber, PublicString, Try = ns.Public, ns.PublicNumber, ns.PublicString, ns.Try

local M = ns.NewModule("invwhisper", {
	title = "Invite Whispers",
	notes = "When someone whispers you for an invite, shows their level and class, with Invite and Who buttons.",
	defaults = {
		window = true,         -- pop up the request list
		tagChat = true,        -- put the level in front of the whisper in chat
	},
})

local MAX_ROWS = 6
local ROW_H = 22
local WIDTH = 320
local REQUEST_LIFETIME = 300   -- seconds a request stays listed
local INVITED_LIFETIME = 30    -- seconds a row stays after Invite
local WHO_TIMEOUT = 6          -- seconds to wait for a /who answer
local CACHE_LIFETIME = 1800    -- seconds a seen level is trusted
local DEFAULT_POINT = { "TOPLEFT", "TOPLEFT", 40, -220 }

local db
local frame
local requests = {}            -- newest first: { key, name, guid, class, level, source, at, state }
local seen = {}                -- [key] = { level, class, at, source }
local pendingWho = {}          -- [key] = time sent
local testMode = false

--------------------------------------------------------------------------------
-- Names and levels
--------------------------------------------------------------------------------

local function Key(name)
	name = PublicString(name)
	if not name then return end
	return (name:lower():gsub("[%s%-]", ""))
end

-- "Name Surname" from a unit, as UnitName gives name and surname apart.
local function UnitFullName(unit)
	local name, surname = Try(UnitName, unit)
	name, surname = PublicString(name), PublicString(surname)
	if not name then return end
	return surname and (name .. " " .. surname) or name
end

local function Remember(name, level, class, source)
	local key = Key(name)
	level = PublicNumber(level)
	if not key or not level or level <= 0 then return end
	seen[key] = { level = level, class = PublicString(class), at = GetTime(), source = source }
end

local function FromGroup(key)
	local units = {}
	if IsInRaid() then
		for i = 1, 40 do units[#units + 1] = "raid" .. i end
	else
		for i = 1, 4 do units[#units + 1] = "party" .. i end
	end
	for _, unit in ipairs(units) do
		if Key(UnitFullName(unit)) == key then
			local level = PublicNumber(Try(UnitLevel, unit))
			local _, class = Try(UnitClass, unit)
			if level and level > 0 then return level, PublicString(class), "your group" end
		end
	end
end

local function FromFriends(name)
	local info = C_FriendList and Try(C_FriendList.GetFriendInfo, name)
	if type(info) ~= "table" or not Public(info.connected) or not info.connected then return end
	local level = PublicNumber(info.level)
	if level and level > 0 then return level, nil, "your friends list" end
end

local function FromGuild(key)
	if not (Try(IsInGuild) and GetNumGuildMembers) then return end
	local count = PublicNumber(Try(GetNumGuildMembers)) or 0
	for i = 1, count do
		local name, _, _, level, _, _, _, _, _, _, class = Try(GetGuildRosterInfo, i)
		if Key(name) == key then
			level = PublicNumber(level)
			if level and level > 0 then return level, PublicString(class), "your guild" end
			return
		end
	end
end

local function FromGroupFinder(key)
	if not (C_LFGList and C_LFGList.GetFilteredSearchResults) then return end
	local _, results = Try(C_LFGList.GetFilteredSearchResults)
	if type(results) ~= "table" or not Public(results) then return end
	for _, resultID in ipairs(results) do
		local info = Try(C_LFGList.GetSearchResultInfo, resultID)
		local count = type(info) == "table" and PublicNumber(info.numMembers) or 0
		for i = 1, count do
			local member = Try(C_LFGList.GetSearchResultPlayerInfo, resultID, i)
			if type(member) == "table" and Key(member.name) == key then
				local level = PublicNumber(member.level)
				if level and level > 0 then return level, PublicString(member.classFilename), "the Group Finder" end
			end
		end
	end
end

-- level, class file, where it came from; nil when nobody knows.
local function KnownLevel(name)
	local key = Key(name)
	if not key then return end
	local level, class, source = FromGroup(key)
	if not level then level, class, source = FromFriends(name) end
	if not level then level, class, source = FromGuild(key) end
	if not level then level, class, source = FromGroupFinder(key) end
	if level then
		seen[key] = { level = level, class = class, at = GetTime(), source = source }
		return level, class, source
	end
	local s = seen[key]
	if s and GetTime() - s.at < CACHE_LIFETIME then return s.level, s.class, s.source end
end

local function ClassFromGUID(guid)
	if not (Public(guid) and type(guid) == "string" and guid ~= "") then return end
	local _, class = Try(GetPlayerInfoByGUID, guid)
	return PublicString(class)
end

local function LevelColor(level)
	local c = Try(GetQuestDifficultyColor, level)
	if type(c) == "table" and c.r then
		return ("|cff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255)
	end
	return "|cffffffff"
end

local function ClassColored(class, text)
	local color = class and C_ClassColor and Try(C_ClassColor.GetClassColor, class)
	if color and color.WrapTextInColorCode then return color:WrapTextInColorCode(text) end
	return text
end

-- "inv", "invite", "invites", "inv pls", "inv?"... but not "invis" or "inventory".
local function IsInviteRequest(text)
	if not (Public(text) and type(text) == "string") then return false end
	text = text:lower()
	for word in text:gmatch("%a+") do
		if word:sub(1, 3) == "inv" and not (word:find("^invis") or word:find("^invent")) then
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Requests
--------------------------------------------------------------------------------

local Refresh                  -- defined with the window

local function FindRequest(key)
	for i, r in ipairs(requests) do
		if r.key == key then return r, i end
	end
end

local function Fill(r)
	local level, class, source = KnownLevel(r.name)
	if level then
		r.level, r.source = level, source
		if class then r.class = class end
		if r.state == "looking" or r.state == "notfound" then r.state = "asked" end
	end
end

local function AddRequest(name, guid)
	local key = Key(name)
	if not key then return end
	local r, index = FindRequest(key)
	if r then
		table.remove(requests, index)
	else
		r = { key = key, name = name, state = "asked" }
	end
	r.at = GetTime()
	if r.state == "invited" then r.state = "asked" end
	r.class = ClassFromGUID(guid) or r.class
	Fill(r)
	table.insert(requests, 1, r)
	while #requests > MAX_ROWS do table.remove(requests) end
	if Refresh then Refresh(true) end
end

local function SendWhoFor(r)
	if not (C_FriendList and C_FriendList.SendWho) then return end
	local name = Try(C_NameUtil and C_NameUtil.ReplaceSurnameSeparatorWithLinkSeparator, r.name) or r.name
	local origin = Enum.SocialWhoOrigin and Enum.SocialWhoOrigin.Item
	local ok = pcall(C_FriendList.SendWho, (WHO_TAG_EXACT or "n-") .. name, origin)
	if not ok then
		M.Say("the game didn't send the /who. Try again in a moment.")
		return
	end
	r.state = "looking"
	pendingWho[r.key] = GetTime()
	C_Timer.After(WHO_TIMEOUT, function()
		pendingWho[r.key] = nil
		if r.state == "looking" then
			r.state = "notfound"
			if Refresh then Refresh() end
		end
	end)
	Refresh()
end

local function Invite(r)
	if not (C_PartyInfo and C_PartyInfo.InviteUnit) then return end
	Try(C_PartyInfo.InviteUnit, r.name)
	r.state = "invited"
	r.at = GetTime()
	Refresh()
end

-- "[Name]: Level 32 Human Warrior - Zone": the first number after the link.
local function OnSystemMessage(text)
	if not (Public(text) and type(text) == "string") or not next(pendingWho) then return end
	local name, rest = text:match("|Hplayer:([^:|]+)[^|]*|h.-|h(.*)$")
	local key = Key(name)
	if not (key and pendingWho[key]) then return end
	local level = tonumber(rest and rest:match("(%d+)"))
	if not level then return end
	pendingWho[key] = nil
	local r = FindRequest(key)
	seen[key] = { level = level, class = r and r.class, at = GetTime(), source = "/who" }
	if r then Fill(r) Refresh() end
end

local function OnWhoList()
	local count = PublicNumber(Try(C_FriendList.GetNumWhoResults)) or 0
	for i = 1, count do
		local info = Try(C_FriendList.GetWhoInfo, i)
		if type(info) == "table" then
			Remember(info.fullName, info.level, info.filename, "/who")
			local key = Key(info.fullName)
			if key then pendingWho[key] = nil end
		end
	end
	local changed = false
	for _, r in ipairs(requests) do
		local before = r.level
		Fill(r)
		if r.level ~= before then changed = true end
	end
	if changed then Refresh() end
end

-- Drop old rows and people who are in the group now.
local function Prune()
	local now = GetTime()
	for i = #requests, 1, -1 do
		local r = requests[i]
		local life = r.state == "invited" and INVITED_LIFETIME or REQUEST_LIFETIME
		if not r.test and (now - r.at > life or FromGroup(r.key)) then table.remove(requests, i) end
	end
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------

local function LevelText(r)
	if r.level then return LevelColor(r.level) .. r.level .. "|r" end
	if r.state == "looking" then return S.DIM .. "...|r" end
	if r.state == "notfound" then return S.DIM .. "not found|r" end
	return S.DIM .. "?|r"
end

local function RowTooltip(row)
	local r = row.request
	if not r then return end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	GameTooltip:SetText(ClassColored(r.class, r.name))
	if r.level then
		GameTooltip:AddLine("Level " .. r.level .. " (from " .. (r.source or "?") .. ")", 1, 1, 1)
	elseif r.state == "notfound" then
		GameTooltip:AddLine("/who didn't find them (offline, or the server didn't answer).", 1, 1, 1, true)
	else
		GameTooltip:AddLine("Level not known. Click Who to look it up.", 1, 1, 1, true)
	end
	local ago = math.floor((GetTime() - r.at) / 60)
	GameTooltip:AddLine(ago < 1 and "Asked just now" or ("Asked " .. ago .. " min ago"), 0.6, 0.6, 0.6)
	GameTooltip:Show()
end

local function GetRow(i)
	local row = frame.rows[i]
	if row then return row end
	row = CreateFrame("Frame", nil, frame)
	row:SetHeight(ROW_H)
	row:EnableMouse(true)
	row:SetScript("OnEnter", RowTooltip)
	row:SetScript("OnLeave", GameTooltip_Hide)
	row.invite = S.Button(row, "Invite", 54, 18)
	row.invite:SetPoint("RIGHT")
	row.invite:SetScript("OnClick", function(self) if self:GetParent().request then Invite(self:GetParent().request) end end)
	row.who = S.Button(row, "Who", 40, 18)
	row.who:SetPoint("RIGHT", row.invite, "LEFT", -4, 0)
	row.who.tooltip = "Look up their level with /who."
	row.who:SetScript("OnClick", function(self) if self:GetParent().request then SendWhoFor(self:GetParent().request) end end)
	row.level = S.Text(row, 12)
	row.level:SetPoint("RIGHT", row.who, "LEFT", -6, 0)
	row.level:SetWidth(58)
	row.level:SetJustifyH("RIGHT")
	row.name = S.Text(row, 12)
	row.name:SetPoint("LEFT")
	row.name:SetPoint("RIGHT", row.level, "LEFT", -4, 0)
	row.name:SetJustifyH("LEFT")
	frame.rows[i] = row
	return row
end

local function Build()
	if frame then return end
	frame = S.Window({
		name = "PredUIInviteWhispers", title = "Invite requests", width = WIDTH, height = 80,
		onMoved = function(self) S.SavePoint(self, db, "point") end,
	})
	frame.rows = {}
	frame.empty = S.Text(frame, 11)
	frame.empty:SetPoint("TOPLEFT", S.PAD, -S.TITLE_H - 12)
	frame.empty:SetText(S.DIM .. "No one has asked for an invite yet.|r")
	S.RestorePoint(frame, db, "point", DEFAULT_POINT)
	frame:HookScript("OnHide", function()
		if testMode then
			testMode = false
			for i = #requests, 1, -1 do if requests[i].test then table.remove(requests, i) end end
		end
	end)
	-- Rows age out; check now and then while the window is up.
	local elapsed = 0
	frame:SetScript("OnUpdate", function(_, delta)
		elapsed = elapsed + delta
		if elapsed < 5 then return end
		elapsed = 0
		Refresh()
	end)
end

function Refresh(popUp)
	Prune()
	if not frame then
		if not (popUp and db.window and #requests > 0) then return end
		Build()
	end
	local y = -S.TITLE_H - 8
	for i, r in ipairs(requests) do
		local row = GetRow(i)
		row.request = r
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", S.PAD, y)
		row:SetPoint("TOPRIGHT", -S.PAD, y)
		row.name:SetText(ClassColored(r.class, r.name))
		row.level:SetText(LevelText(r))
		row.who:SetShown(not r.level)
		row.who:SetEnabled(r.state ~= "looking")
		row.invite:SetText(r.state == "invited" and "Sent" or "Invite")
		row.invite:SetEnabled(r.state ~= "invited")
		row:Show()
		y = y - ROW_H
	end
	for i = #requests + 1, #frame.rows do
		frame.rows[i]:Hide()
		frame.rows[i].request = nil
	end
	frame.empty:SetShown(#requests == 0)
	if #requests == 0 then y = y - 20 end
	frame:SetHeight(-y + 8)
	if popUp and db.window and #requests > 0 then frame:Show() end
end

function M.ResetPosition()
	db.point = nil
	if frame then S.RestorePoint(frame, db, "point", DEFAULT_POINT) end
end

--------------------------------------------------------------------------------
-- Chat
--------------------------------------------------------------------------------

-- Puts "[32]" in front of an invite whisper when the level is known. Runs
-- once per chat window that shows the whisper.
local function ChatFilter(_, _, text, author, ...)
	if not (db and db.tagChat and M.enabled) then return false end
	if not (IsInviteRequest(text) and PublicString(author)) then return false end
	local level = KnownLevel(author)
	if not level then return false end
	return false, LevelColor(level) .. "[" .. level .. "]|r " .. text, author, ...
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local function Show()
	Build()
	Refresh()
	frame:Show()
end

local function Test()
	testMode = true
	local now = GetTime()
	for i = #requests, 1, -1 do if requests[i].test then table.remove(requests, i) end end
	local fake = {
		{ name = "Tankguy", class = "WARRIOR", level = 32, source = "your guild" },
		{ name = "Frostbolt Emberwake", class = "MAGE", state = "asked" },
		{ name = "Healbot", class = "PRIEST", level = 29, source = "/who" },
	}
	for i = #fake, 1, -1 do
		local r = fake[i]
		r.key, r.at, r.state, r.test = Key(r.name), now, r.state or "asked", true
		table.insert(requests, 1, r)
	end
	while #requests > MAX_ROWS do table.remove(requests) end
	Show()
end

local function OnSlash(msg)
	msg = msg:lower():match("^%s*(.-)%s*$")
	if msg == "" then
		Show()
	elseif msg == "test" then
		Test()
	elseif msg == "clear" then
		wipe(requests)
		Refresh()
		M.Say("request list cleared.")
	elseif msg == "options" then
		ns.OpenSettings(M)
	else
		M.Say("Commands:")
		print("  /invwhisper - show the invite request list")
		print("  /invwhisper test - show it with made-up requests")
		print("  /invwhisper clear - empty the list")
		print("  /invwhisper options - settings")
	end
end

M.options = {
	{ type = "checkbox", key = "window", label = "Pop up the request list", tooltip = "Show the list of people who whispered for an invite, with their level, Who and Invite buttons, when a new request comes in." },
	{ type = "checkbox", key = "tagChat", label = "Level in chat", tooltip = "Put the level in front of an invite whisper in chat, when the game already knows it (group, friends, guild, Group Finder or an earlier /who)." },
	{ type = "button", label = "Preview", button = "Test", tooltip = "Show the list with made-up requests. Also /invwhisper test.", func = function() OnSlash("test") end },
	{ type = "button", label = "Position", button = "Reset", tooltip = "Put the list back in its default place.", func = function() M.ResetPosition() end },
}

--------------------------------------------------------------------------------
-- Start-up
--------------------------------------------------------------------------------

function M:Enable()
	db = self.db

	local events = CreateFrame("Frame")
	events:RegisterEvent("CHAT_MSG_WHISPER")
	events:RegisterEvent("CHAT_MSG_SYSTEM")
	events:RegisterEvent("WHO_LIST_UPDATE")
	events:RegisterEvent("GROUP_ROSTER_UPDATE")
	events:SetScript("OnEvent", function(_, event, ...)
		if event == "CHAT_MSG_WHISPER" then
			local text, author = ...
			local guid = select(12, ...)
			if IsInviteRequest(text) and PublicString(author) and not FromGroup(Key(author)) then
				AddRequest(author, guid)
			end
		elseif event == "CHAT_MSG_SYSTEM" then
			OnSystemMessage((...))
		elseif event == "WHO_LIST_UPDATE" then
			OnWhoList()
		elseif event == "GROUP_ROSTER_UPDATE" then
			if #requests > 0 then Refresh() end
		end
	end)

	local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
	if addFilter then addFilter("CHAT_MSG_WHISPER", ChatFilter) end
end

SLASH_PREDUIINVWHISPER1 = "/invwhisper"
SlashCmdList.PREDUIINVWHISPER = ns.SlashHandler(M, OnSlash)
