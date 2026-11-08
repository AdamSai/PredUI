--------------------------------------------------------------------------------
-- Notes: post-it notes for reminders to yourself.
--
--   * /notes opens the list of notes. Click one to open it, right-click to
--     delete it. "New note" adds one.
--   * The Notes icon on the PredUI floating button (Launcher.lua) opens the
--     list too; right-click it for a new note, shift-right-click for a list.
--   * A note is a small paper window: title at the top, text below (saved as
--     you type). New notes belong to the character that wrote them (other
--     characters don't see them); untick "Only on <name>" under Areas to share
--     one, or change the default in the settings.
--   * Checklists: "List" on a note turns its lines into items you can tick
--     off (shopping lists...), and back into text. "New list" starts one.
--   * Tags: in a note or list item, @ picks a quest and # picks an item. They
--     are typed as [Quest Name] and #[Item Name] (the ID is saved in note.tags).
--     Edit boxes can't hold clickable links, so while you aren't editing, text
--     with tags is drawn by a read view on top of the box. Quests are shown in
--     amber with a "!", items with their icon, quality and Auctionator price.
--     Click a quest: opens it in the quest log, or if it isn't there sets a
--     waypoint where it starts (needs Questie). Click an item: its tooltip.
--     Backspace or Delete on a tag removes all of it.
--   * The same @ and # lists work in the chat box, after two letters, and put
--     in a real quest or item link. Off with "Quest and item tags in chat".
--     Chat boxes are Blizzard's, so they're only hooked, and nothing is stored
--     on them. Not in combat, and not on slash commands.
--   * SetHyperlinksEnabled is protected, so a note first made in combat gets
--     its links after combat.
--   * Pin: a pinned note has no close button and opens again after a login or
--     reload, so it stays on screen until you un-pin it.
--   * Areas: a note can open by itself when you enter a zone or subzone you
--     added to it, or any capital city. It opens every time you arrive there;
--     if you close it, it stays closed until you leave and come back.
--   * Capital cities are found by map ID (C_Map.GetBestMapForUnit), with the
--     English zone names as a fallback. /notes where prints what the game
--     reports where you stand, to check them.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.Style

local M = ns.NewModule("notes", {
	title = "Notes",
	notes = "Post-it notes for reminders: a list of notes, pin one to keep it on screen, or have it open when you enter a zone or a capital city.",
	defaults = { popup = true, sound = true, charOnly = true, opacity = 100, chatTags = true },
})

local NOTE_W, NOTE_H = 260, 210
local LIST_W, LIST_ROWS, ROW_H = 320, 12, 22
local INK = { 0.16, 0.13, 0.06 }
local ITEM_H = 20
local TEXT_W = NOTE_W - S.PAD * 2 - 10      -- width of the text / list area
local ITEM_W = TEXT_W - 20 - 18             -- item text, between tick box and remove button

-- Paper colours: { name, r, g, b }.
local PAPERS = {
	{ "Yellow", 0.99, 0.91, 0.52 },
	{ "Blue",   0.62, 0.82, 0.98 },
	{ "Green",  0.68, 0.92, 0.62 },
	{ "Pink",   0.98, 0.70, 0.80 },
}

-- uiMapIDs of the capital cities, and their (English) names as a fallback.
local CAPITAL_MAPS = {
	[1453] = true, [1454] = true, [1455] = true, [1456] = true, [1457] = true, [1458] = true,
	[1947] = true, [1954] = true, [1955] = true,
}
local CAPITAL_NAMES = {
	["Stormwind City"] = true, ["Ironforge"] = true, ["Darnassus"] = true, ["The Exodar"] = true,
	["Orgrimmar"] = true, ["Undercity"] = true, ["Thunder Bluff"] = true,
	["Silvermoon City"] = true, ["Shattrath City"] = true,
}

local db
local frames = {}              -- [id] = note window
local freeFrames = {}
local listFrame, areaPanel
local lastMatch = {}           -- [id] = true while you're in one of the note's areas
local RefreshList, RefreshAreaPanel, OpenNote, RefreshItems, ApplyMode, RefreshView

--------------------------------------------------------------------------------
-- Data
--------------------------------------------------------------------------------

local function Me()
	local name = ns.PublicString(UnitName("player")) or "?"
	local realm = ns.PublicString(GetRealmName()) or ""
	return name .. "-" .. realm
end

local function ShortMe()
	return ns.PublicString(UnitName("player")) or "this character"
end

local function Visible(note)
	return note and (not note.owner or note.owner == Me())
end

local function Paper(note)
	return PAPERS[note.color or 1] or PAPERS[1]
end

local function IsList(note)
	return note.kind == "list"
end

local function Trim(text)
	return (text or ""):match("^%s*(.-)%s*$")
end

-- Text lines become items; "[x] milk" comes back ticked, "- milk" loses the dash.
local function TextToItems(text, separator)
	local items = {}
	for line in (text or ""):gmatch(separator or "[^\n]+") do
		local mark, rest = line:match("^%s*%[([xX ]?)%]%s*(.*)$")
		local t = Trim(rest or line:match("^%s*[-*]?%s*(.*)$"))
		if t ~= "" then
			items[#items + 1] = { text = t, done = (mark == "x" or mark == "X") or nil }
		end
	end
	return items
end

local function ItemsToText(items)
	local lines = {}
	for _, item in ipairs(items or {}) do
		lines[#lines + 1] = (item.done and "[x] " or "") .. item.text
	end
	return table.concat(lines, "\n")
end

local function Progress(note)
	local done = 0
	for _, item in ipairs(note.items or {}) do
		if item.done then done = done + 1 end
	end
	return done, #(note.items or {})
end

-- kind "list": a checklist; text then holds the first items, split on commas.
local function NewNote(text, kind)
	local id = db.nextID
	db.nextID = id + 1
	local note = { id = id, title = "", text = text or "", created = time(), updated = time(), color = 1, zones = {} }
	if kind == "list" then
		note.kind = "list"
		note.items = TextToItems(text, "[^,;\n]+")
		note.text = ""
	end
	if db.charOnly then note.owner = Me() end
	db.list[id] = note
	return note
end

-- Note text for places that don't draw tags: an item tag loses its "#".
local function Plain(text)
	return (text:gsub("#%[", "["))
end

local function Label(note)
	if note.title ~= "" then return note.title end
	local first
	if IsList(note) then
		first = note.items[1] and note.items[1].text
	else
		first = note.text:match("^%s*([^\n]+)")
	end
	return first and Plain(first) or "(empty)"
end

-- Visible notes, pinned first, then the latest edited.
local function SortedNotes()
	local list = {}
	for _, note in pairs(db.list) do
		if Visible(note) then list[#list + 1] = note end
	end
	table.sort(list, function(a, b)
		if (a.pinned and true or false) ~= (b.pinned and true or false) then return a.pinned and true or false end
		return (a.updated or 0) > (b.updated or 0)
	end)
	return list
end

local function HasArea(note)
	return note.capitals or next(note.zones or {}) ~= nil
end

local function Touch(note)
	note.updated = time()
	if listFrame and listFrame:IsShown() then RefreshList() end
end

--------------------------------------------------------------------------------
-- Small widgets on paper
--------------------------------------------------------------------------------

-- A text-only button in ink colour, lit when `on`.
local function InkButton(parent, text, w)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w or 50, 18)
	b.label = S.Text(b, 11)
	b.label:SetShadowOffset(0, 0)
	b.label:SetPoint("CENTER")
	b.label:SetText(text)
	local function Color(self)
		local a = (self.hover or self.on) and 1 or 0.6
		self.label:SetTextColor(INK[1], INK[2], INK[3], a)
	end
	b.line = S.Texture(b, "ARTWORK", 0)
	b.line:SetHeight(1)
	b.line:SetPoint("BOTTOMLEFT", b.label, "BOTTOMLEFT", 0, -2)
	b.line:SetPoint("BOTTOMRIGHT", b.label, "BOTTOMRIGHT", 0, -2)
	b.line:SetVertexColor(INK[1], INK[2], INK[3], 0.8)
	b.line:Hide()
	function b:SetOn(on)
		self.on = on
		self.line:SetShown(on and true or false)
		Color(self)
	end
	b:SetScript("OnEnter", function(self)
		self.hover = true
		Color(self)
		if self.tooltip then
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText(self.tooltip, nil, nil, nil, nil, true)
			GameTooltip:Show()
		end
	end)
	b:SetScript("OnLeave", function(self)
		self.hover = nil
		Color(self)
		GameTooltip_Hide()
	end)
	Color(b)
	return b
end

-- A small tick box with a label (for the dark Areas panel).
local function Check(parent, text, onClick)
	local c = CreateFrame("Button", nil, parent)
	c:SetSize(200, 18)
	local box = CreateFrame("Frame", nil, c)
	box:SetSize(12, 12)
	box:SetPoint("LEFT", 1, 0)
	S.Body(box, { 0.03, 0.035, 0.045, 1 })
	c.fill = S.Texture(box, "ARTWORK", 0)
	c.fill:SetPoint("TOPLEFT", 2, -2)
	c.fill:SetPoint("BOTTOMRIGHT", -2, 2)
	c.fill:SetVertexColor(S.ACCENT[1], S.ACCENT[2], S.ACCENT[3])
	c.label = S.Text(c, 11)
	c.label:SetPoint("LEFT", box, "RIGHT", 6, 0)
	c.label:SetText(text)
	c.label:SetTextColor(0.9, 0.9, 0.9)
	function c:SetChecked(on) self.fill:SetShown(on and true or false) end
	c:SetScript("OnClick", onClick)
	S.RowHighlight(c)
	return c
end

--------------------------------------------------------------------------------
-- Note windows
--------------------------------------------------------------------------------

local function DefaultPoint()
	local n = 0
	for _, f in pairs(frames) do if f:IsShown() then n = n + 1 end end
	n = n % 8
	return { "CENTER", "CENTER", -150 + n * 24, 80 - n * 24 }
end

local function ApplyPaper(f)
	local _, r, g, b = unpack(Paper(f.note))
	-- Opacity setting: only the paper fades, the writing stays fully readable.
	local a = math.max(0.1, math.min(1, (tonumber(db.opacity) or 100) / 100))
	f.pBody:SetVertexColor(r, g, b, 0.97 * a)
	f.pEdge:SetVertexColor(r * 0.55, g * 0.55, b * 0.55, a)
	f.pShadow:SetVertexColor(0, 0, 0, 0.6 * a)
	f.band:SetVertexColor(r * 0.86, g * 0.86, b * 0.86, a)
	f.glow:SetColor(r, g, b)
	f.glow:SetAlpha(0.35 * a)
	f.swatch.tex:SetVertexColor(r * 0.8, g * 0.8, b * 0.8)
	-- Scroll bar in a darker shade of the paper instead of PredUI's blue.
	local thumb = f.bar:GetThumbTexture()
	if thumb then thumb:SetVertexColor(r * 0.55, g * 0.55, b * 0.55, 0.9) end
	if f.bar.track then f.bar.track:SetVertexColor(r * 0.7, g * 0.7, b * 0.7, 0.35) end
end

local function ApplyPin(f)
	local pinned = f.note.pinned and true or false
	f.pin:SetOn(pinned)
	f.pin.label:SetText(pinned and "Pinned" or "Pin")
	f.close:SetShown(not pinned)
end

local function ApplyAreaTag(f)
	f.areas:SetOn(HasArea(f.note))
end

local function UpdateScrollBar(f)
	local range = math.floor((f.scroll:GetVerticalScrollRange() or 0) + 0.5)
	f.bar:SetMinMaxValues(0, range)
	f.bar:SetShown(range > 0)
	f.bar:SetValue(math.min(range, math.floor((f.scroll:GetVerticalScroll() or 0) + 0.5)))
end

--------------------------------------------------------------------------------
-- Tags: @ and part of a quest name, or # and part of an item name; pick one
-- (Tab, Enter or a click). Quests in your log and items in your bags come
-- first. After that QuestieDB's quests and items, and the items Auctionator
-- has prices for if the client knows their names. Those lists are read once,
-- a few hundred per frame, the first time you need them.
--------------------------------------------------------------------------------

local TAG_ROWS, TAG_ROW_H, TAG_W = 8, 18, 250
local Tag = { sel = 1, results = {}, kind = "quest" }
local chatBoxes = {}            -- [chat edit box] = true, the ones we've hooked
local nameLists = {}            -- [kind] = sorted { { name, lower, id, level, kind }, ... }
local nameToID = {}             -- [kind] = { [name] = id }
local loadingNames = {}         -- [kind] = true while reading

local function QuestieEntity(which)
	local lib = _G.LibQuestieDB
	local entity = type(lib) == "table" and lib[which]
	if type(entity) == "table" and type(entity.Get) == "function" and type(entity.GetAllIds) == "function" then
		return entity
	end
end

local function NameIDs(kind)
	local ids, seen = {}, {}
	local entity = QuestieEntity(kind == "quest" and "Quest" or "Item")
	local all = entity and ns.Try(entity.GetAllIds)
	if type(all) == "table" then
		for _, id in ipairs(all) do
			ids[#ids + 1] = id
			seen[id] = true
		end
	end
	local auctionator = kind == "item" and _G.Auctionator
	local prices = auctionator and auctionator.Database and auctionator.Database.db
	if type(prices) == "table" then
		pcall(function()
			for key in pairs(prices) do
				-- Plain number keys are mats and other stackables; gear has "g:" keys.
				local id = type(key) == "string" and tonumber(key:match("^(%d+)$"))
				if id and not seen[id] then
					ids[#ids + 1] = id
					seen[id] = true
				end
			end
		end)
	end
	return ids, entity
end

local function ReadName(kind, entity, id)
	local name = entity and ns.Try(entity.Get, id, "name")
	if type(name) == "string" and name ~= "" then return name end
	if kind == "item" and ns.Try(C_Item.IsItemDataCachedByID, id) then
		return ns.PublicString(ns.Try(C_Item.GetItemNameByID, id))
	end
end

local function LoadNames(kind)
	if nameLists[kind] or loadingNames[kind] then return end
	local ids, entity = NameIDs(kind)
	loadingNames[kind] = true
	local list, map, i = {}, {}, 1
	local function Step()
		local last = math.min(#ids, i + 299)
		for n = i, last do
			local id = ids[n]
			local name = ReadName(kind, entity, id)
			if name and not map[name] then
				map[name] = id
				local level = kind == "quest" and entity and ns.Try(entity.Get, id, "questLevel")
				list[#list + 1] = { name = name, lower = name:lower(), id = id, level = tonumber(level), kind = kind }
			end
		end
		i = last + 1
		if i <= #ids then
			C_Timer.After(0, Step)
			return
		end
		table.sort(list, function(a, b) return a.lower < b.lower end)
		nameLists[kind], nameToID[kind], loadingNames[kind] = list, map, nil
		if Tag.Owns(Tag.box) and Tag.kind == kind then Tag.Search() end
	end
	Step()
end

-- Quests in the log (not headers or hidden ones).
local function LogQuests()
	local out = {}
	local log = C_QuestLog
	if not (log and log.GetNumQuestLogEntries and log.GetInfo) then return out end
	for i = 1, ns.Try(log.GetNumQuestLogEntries) or 0 do
		local info = ns.Try(log.GetInfo, i)
		local title = info and not info.isHeader and not info.isHidden and ns.PublicString(info.title)
		if title then
			out[#out + 1] = { name = title, lower = title:lower(), id = ns.PublicNumber(info.questID),
				level = ns.PublicNumber(info.level), inLog = true, kind = "quest" }
		end
	end
	return out
end

-- Items in the backpack and bags, one row per item.
local function BagItems()
	local out, seen = {}, {}
	for bag = 0, NUM_BAG_SLOTS or 4 do
		for slot = 1, ns.Try(C_Container.GetContainerNumSlots, bag) or 0 do
			local info = ns.Try(C_Container.GetContainerItemInfo, bag, slot)
			local id = info and ns.PublicNumber(info.itemID)
			local name = info and ns.PublicString(info.itemName)
			if id and name and not seen[id] then
				seen[id] = true
				out[#out + 1] = { name = name, lower = name:lower(), id = id, kind = "item" }
			end
		end
	end
	return out
end

-- Auctionator's last-scan price of an item. Grey items have none (as ns.AuctionPrice).
local function ItemPrice(id)
	local auctionator = _G.Auctionator
	local api = auctionator and auctionator.API and auctionator.API.v1
	if not (api and api.GetAuctionPriceByItemID) then return end
	if ns.PublicNumber(ns.Try(C_Item.GetItemQualityByID, id)) == 0 then return end
	return ns.PublicNumber(ns.Try(api.GetAuctionPriceByItemID, "PredUI", id))
end

local function PriceText(id)
	local price = ItemPrice(id)
	return price and ns.PublicString(ns.Try(C_CurrencyInfo.GetCoinTextureString, math.floor(price + 0.5), 12))
end

-- 1 = name starts with q, 2 = a word starts with q, 3 = q anywhere, nil = no match.
local function Rank(lower, q)
	if q == "" then return 1 end
	local s = lower:find(q, 1, true)
	if not s then return nil end
	if s == 1 then return 1 end
	return lower:sub(s - 1, s - 1):find("[%s%p]") and 2 or 3
end

local function BuildTagPopup()
	local p = CreateFrame("Frame", nil, UIParent)
	p:SetFrameStrata("DIALOG")
	p:SetClampedToScreen(true)
	p:SetWidth(TAG_W)
	S.Body(p)
	p.rows = {}
	for i = 1, TAG_ROWS do
		local row = CreateFrame("Button", nil, p)
		row:SetHeight(TAG_ROW_H)
		row:SetPoint("TOPLEFT", 4, -4 - (i - 1) * TAG_ROW_H)
		row:SetPoint("TOPRIGHT", -4, -4 - (i - 1) * TAG_ROW_H)
		S.RowHighlight(row)
		row.sel = S.Texture(row, "BACKGROUND", 1)
		row.sel:SetAllPoints()
		row.sel:SetVertexColor(S.ACCENT[1], S.ACCENT[2], S.ACCENT[3], 0.25)
		row.info = S.Text(row, 10)
		row.info:SetPoint("RIGHT", -4, 0)
		row.info:SetJustifyH("RIGHT")
		row.info:SetTextColor(0.6, 0.6, 0.6)
		row.name = S.Text(row, 12)
		row.name:SetPoint("LEFT", 4, 0)
		row.name:SetPoint("RIGHT", row.info, "LEFT", -6, 0)
		row.name:SetJustifyH("LEFT")
		row:SetScript("OnClick", function() Tag.Accept(i) end)
		row:SetScript("OnEnter", function()
			Tag.sel = i
			Tag.Draw()
		end)
		p.rows[i] = row
	end
	p.hint = S.Text(p, 10)
	p.hint:SetPoint("BOTTOMLEFT", 8, 6)
	p.hint:SetTextColor(0.6, 0.6, 0.6)
	p:EnableKeyboard(true)
	-- A list that takes the keyboard gets the keys before the text box, so it
	-- does the list's keys itself and passes every other key on.
	p:SetScript("OnKeyDown", function(self, key)
		local used = true
		if key == "UP" or key == "DOWN" then
			Tag.Move(key)
		elseif (key == "ENTER" or key == "NUMPADENTER" or key == "TAB") and #Tag.results > 0 then
			if Tag.box and Tag.box.MarkEnter then Tag.box:MarkEnter() end
			Tag.Accept()
		elseif key == "ESCAPE" then
			Tag.Hide()
		else
			used = false
		end
		-- Blocked in combat, but the list doesn't take the keyboard then.
		if not InCombatLockdown() then self:SetPropagateKeyboardInput(not used) end
	end)
	p:Hide()
	Tag.popup = p
end

function Tag.Owns(box)
	return box ~= nil and Tag.box == box and Tag.popup ~= nil and Tag.popup:IsShown()
end

-- A multi-line box uses the arrow keys for its cursor. While the list is open
-- its box is told to ignore them (as the chat box does), so they come through
-- to the list's own OnKeyDown.
function Tag.TakeArrows(box)
	if Tag.arrowBox == box then return end
	if Tag.arrowBox then Tag.arrowBox:SetAltArrowKeyMode(false) end
	Tag.arrowBox = box
	if box then box:SetAltArrowKeyMode(true) end
end

function Tag.Hide()
	if Tag.popup then Tag.popup:Hide() end
	Tag.TakeArrows(nil)
	Tag.box = nil
end

-- Moves the selection, wrapping round. A key press can arrive by both routes.
function Tag.Move(key)
	local n = #Tag.results
	if n == 0 or (key ~= "UP" and key ~= "DOWN") then return end
	local now = GetTime()
	if Tag.moved == now then return end
	Tag.moved = now
	Tag.sel = key == "UP" and (Tag.sel - 2) % n + 1 or Tag.sel % n + 1
	Tag.Draw()
end

function Tag.Draw()
	local p, results = Tag.popup, Tag.results
	for i, row in ipairs(p.rows) do
		local r = results[i]
		if r then
			row.name:SetText(r.name)
			local info
			if r.kind == "item" then
				info = PriceText(r.id) or ""
				-- Chat needs a real link, which only exists once the client has the item.
				if chatBoxes[Tag.box] and not ns.Try(C_Item.IsItemDataCachedByID, r.id) then
					ns.Try(C_Item.RequestLoadItemDataByID, r.id)
				end
			else
				info = r.level and r.level > 0 and ("Lvl " .. r.level) or ""
				if r.inLog then info = info .. (info ~= "" and "  " or "") .. "|cff8fd16ein log|r" end
			end
			row.info:SetText(info)
			row.sel:SetShown(i == Tag.sel)
			row:Show()
		else
			row:Hide()
		end
	end
	local isQuest = Tag.kind == "quest"
	if loadingNames[Tag.kind] then
		p.hint:SetText(isQuest and "Loading quest names..." or "Loading item names...")
	elseif #results == 0 then
		if Tag.query == "" then
			p.hint:SetText(isQuest and "No quests in your log." or "Type part of an item name.")
		else
			p.hint:SetText(isQuest and "No quests match." or "No items match.")
		end
	else
		p.hint:SetText("Up/Down to choose, Tab or Enter to add")
	end
	p:SetHeight(8 + #results * TAG_ROW_H + 20)
end

function Tag.Search()
	local q, results, inLog = Tag.query, {}, {}
	local buckets = { {}, {}, {} }
	for _, r in ipairs(Tag.kind == "quest" and LogQuests() or BagItems()) do
		local rank = Rank(r.lower, q)
		if rank and not inLog[r.name] then
			inLog[r.name] = true
			table.insert(buckets[rank], r)
		end
	end
	for _, bucket in ipairs(buckets) do
		table.sort(bucket, function(a, b) return a.lower < b.lower end)
		for _, r in ipairs(bucket) do results[#results + 1] = r end
	end
	-- The long lists (sorted already), after two letters so the list means something.
	local names = nameLists[Tag.kind]
	if names and #q >= 2 and #results < TAG_ROWS then
		buckets = { {}, {}, {} }
		for _, r in ipairs(names) do
			local rank = not inLog[r.name] and Rank(r.lower, q)
			if rank then
				local bucket = buckets[rank]
				if #bucket < TAG_ROWS then bucket[#bucket + 1] = r end
				if rank == 1 and #bucket >= TAG_ROWS then break end
			end
		end
		for _, bucket in ipairs(buckets) do
			for _, r in ipairs(bucket) do results[#results + 1] = r end
		end
	end
	for i = #results, TAG_ROWS + 1, -1 do results[i] = nil end
	Tag.results = results
	Tag.sel = math.max(1, math.min(Tag.sel, #results))

	if not Tag.popup then BuildTagPopup() end
	local box, p = Tag.box, Tag.popup
	Tag.Draw()
	p:ClearAllPoints()
	-- Keys go to the highest frame first, and the chat box is in DIALOG itself.
	-- Blizzard's own name list uses TOOLTIP for the same reason.
	p:SetFrameStrata(chatBoxes[box] and "TOOLTIP" or "DIALOG")
	if chatBoxes[box] then
		p:SetPoint("BOTTOMLEFT", box, "TOPLEFT", 0, 4)
	else
		p:SetPoint("TOPLEFT", box, "TOPLEFT", math.max(0, math.min(box.tagX or 0, box:GetWidth() - 60)),
			(box.tagY or 0) - (box.tagH or 14) - 2)
	end
	p:Show()
	-- In combat keys can't be passed on, so the box keeps them: Tab and Enter
	-- still pick, but Up and Down move the cursor.
	local combat = InCombatLockdown()
	p:EnableKeyboard(not combat)
	if not combat then p:SetPropagateKeyboardInput(true) end
	if not chatBoxes[box] then Tag.TakeArrows(not combat and box or nil) end
end

-- Opens, updates or closes the list for what's just before the cursor.
function Tag.Update(box)
	local text = box:GetText() or ""
	local cursor = box:GetCursorPosition() or #text
	local before = text:sub(1, cursor)
	local at, sign, q = before:match("()([@#])([^@#%[%]\r\n]*)$")
	if at and at > 1 and not before:sub(at - 1, at - 1):find("%s") then at = nil end
	-- In chat @ and # are everyday characters ("meet @ the inn", "#1"), so the
	-- list needs two letters right after them.
	if at and chatBoxes[box] and (#q < 2 or q:find("^%s") or text:sub(1, 1) == "/" or InCombatLockdown()) then
		at = nil
	end
	if not at or #q > 50 then
		if Tag.box == box then Tag.Hide() end
		return
	end
	local kind = sign == "#" and "item" or "quest"
	if Tag.box ~= box or Tag.kind ~= kind then Tag.sel = 1 end
	Tag.box, Tag.start, Tag.stop, Tag.kind = box, at, cursor, kind
	Tag.raw = text:sub(at, cursor)
	Tag.query = q:gsub("^%s+", ""):lower()
	LoadNames(kind)
	Tag.Search()
end

-- Puts the picked quest in place of "@query".
function Tag.Accept(i)
	local box, r = Tag.box, Tag.results[i or Tag.sel]
	if not (box and r) then
		Tag.Hide()
		return
	end
	local text = box:GetText() or ""
	if chatBoxes[box] then
		-- A real link; a quest or item the game can't link goes in as its name.
		-- No saving here, and Blizzard's OnTextChanged runs by itself.
		local link
		if r.kind == "item" then
			link = Tag.RealItemLink(r.id)
		else
			-- GetQuestLink only knows quests in your log, and the server strips a
			-- hand-made link for any other. "[Name (ID)]" is Questie's chat format:
			-- it survives sending, and Questie users get it as a link.
			link = ns.PublicString(ns.Try(GetQuestLink, r.id))
			if not link and r.id then link = ("[%s (%d)]"):format(r.name, r.id) end
		end
		local placeholder = "[" .. r.name .. "]"
		local chatHead = text:sub(1, Tag.start - 1) .. (link or placeholder) .. " "
		local chatTail = text:sub(Tag.stop + 1)
		Tag.Hide()
		box:SetText(chatHead .. chatTail)
		box:SetCursorPosition(#chatHead)
		-- The client didn't have the item yet: swap in the link when it arrives.
		if not link and r.kind == "item" and Item and Item.CreateFromItemID then
			local item = Item:CreateFromItemID(r.id)
			ns.Try(item.ContinueOnItemLoad, item, function()
				local real = Tag.RealItemLink(r.id)
				local now = box:GetText() or ""
				local from, to = now:find(placeholder, 1, true)
				if real and from then
					box:SetText(now:sub(1, from - 1) .. real .. now:sub(to + 1))
					box:SetCursorPosition(from - 1 + #real + 1)
				end
			end)
		end
		return
	end
	local head = text:sub(1, Tag.start - 1) .. (r.kind == "item" and "#[" or "[") .. r.name .. "]"
	local note = box.tagFrame and box.tagFrame.note
	if note and r.id then
		if type(note.tags) ~= "table" then note.tags = {} end
		note.tags[(r.kind == "item" and "i:" or "q:") .. r.name] = r.id
	end
	local tail = text:sub(Tag.stop + 1)
	if not tail:find("^%s") then head = head .. " " end
	Tag.Hide()
	box:SetText(head .. tail)
	box:SetCursorPosition(#head)
	box.tagLast = head .. tail
	if not box:HasFocus() then box:SetFocus() end
	-- SetText doesn't count as typing, so save the way typing does.
	local onChanged = box:GetScript("OnTextChanged")
	if onChanged then onChanged(box, true) end
	box.justPicked = true
end

-- If this edit only removed part of a tag, takes out the whole tag. Backspace
-- right after picking a tag counts the space that was added with it.
local function DeleteWholeTag(box, old, new)
	local note = box.tagFrame and box.tagFrame.note
	if not (note and old and #new < #old) then return end
	local p = 0
	while p < #new and old:byte(p + 1) == new:byte(p + 1) do p = p + 1 end
	local count = #old - #new
	if old:sub(p + count + 1) ~= new:sub(p + 1) then return end
	local first, last = p + 1, p + count
	local from, to = first, last
	local removedSpace = count == 1 and old:sub(first, first):find("^%s") ~= nil
	local touched = false
	for s, hash, name, e in old:gmatch("()(#?)%[([^%[%]\r\n]+)%]()") do
		local kind = hash == "#" and "item" or "quest"
		local overlaps = s <= last and e - 1 >= first
		local justPicked = box.justPicked and removedSpace and e == first
		if (overlaps or justPicked) and Tag.IDOf(note, kind, name) then
			touched = true
			from, to = math.min(from, s), math.max(to, e - 1)
		end
	end
	if not touched then return end
	-- Don't leave two spaces where the tag was.
	if old:sub(to + 1, to + 1) == " " and (from == 1 or old:sub(from - 1, from - 1):find("%s")) then
		to = to + 1
	end
	local text = old:sub(1, from - 1) .. old:sub(to + 1)
	box:SetText(text)
	box:SetCursorPosition(from - 1)
	return text
end

-- Call first in a box's OnTextChanged; true means the change was Enter
-- picking a quest, and nothing else should handle it.
function Tag.OnText(box, userInput)
	local text = box:GetText() or ""
	if not userInput then
		box.tagLast = text
		return false
	end
	text = DeleteWholeTag(box, box.tagLast, text) or text
	box.tagLast = text
	box.justPicked = nil
	if Tag.Owns(box) and text:sub(Tag.start, Tag.stop) == Tag.raw
		and text:sub(Tag.stop + 1, Tag.stop + 1):find("[\r\n]") then
		Tag.stop = Tag.stop + 1          -- take the line break out with the query
		if box.MarkEnter then box:MarkEnter() end
		Tag.Accept()
		return true
	end
	Tag.Update(box)
	return false
end

-- Wires a text box up for @ and # tags. Call after its own scripts are set.
local function AttachTags(box, f)
	box.tagFrame = f
	box:HookScript("OnCursorChanged", function(self, x, y, _, h)
		self.tagX, self.tagY, self.tagH = x, y, h
	end)
	box:SetScript("OnTabPressed", function(self)
		if Tag.Owns(self) then Tag.Accept() end
	end)
	box:SetScript("OnArrowPressed", function(self, key)
		if Tag.Owns(self) then Tag.Move(key) end
	end)
	local escape = box:GetScript("OnEscapePressed")
	box:SetScript("OnEscapePressed", function(self)
		if Tag.Owns(self) then
			Tag.Hide()
		elseif escape then
			escape(self)
		end
	end)
	box:HookScript("OnEditFocusLost", function(self)
		self.justPicked = nil
		if Tag.Owns(self) and not Tag.popup:IsMouseOver() then Tag.Hide() end
	end)
end

local LINE_H = 14              -- height of one line of item text

--------------------------------------------------------------------------------
-- Drawing tags, and what clicking them does
--------------------------------------------------------------------------------

local function Hex(r, g, b)
	return ("%02x%02x%02x"):format(r * 255, g * 255, b * 255)
end

local INK_HEX = Hex(INK[1], INK[2], INK[3])
local QUEST_HEX = "7a4a00"      -- amber: game's quest yellow can't be read on the paper
local QUEST_ICON = "|TInterface\\GossipFrame\\AvailableQuestIcon:0|t"
local waitingForItems

local function ItemHex(id)
	local quality = ns.PublicNumber(ns.Try(C_Item.GetItemQualityByID, id))
	if not quality then
		waitingForItems = true
		ns.Try(C_Item.RequestLoadItemDataByID, id)
		return INK_HEX
	end
	local c = quality > 1 and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
	if not c then return INK_HEX end
	return Hex(c.r * 0.6, c.g * 0.6, c.b * 0.6)      -- darkened for the paper
end

local function TagID(note, kind, name)
	local id = type(note.tags) == "table" and note.tags[(kind == "quest" and "q:" or "i:") .. name]
	if id then return id end
	for _, r in ipairs(kind == "quest" and LogQuests() or BagItems()) do
		if r.name == name then return r.id end
	end
	return nameToID[kind] and nameToID[kind][name]
end

Tag.IDOf = TagID

-- The text with its tags as links. Second return: whether there were any.
local function Render(note, text)
	local found = false
	local out = (text or ""):gsub("(#?)%[([^%[%]\r\n]+)%]", function(hash, name)
		local kind = hash == "#" and "item" or "quest"
		local id = TagID(note, kind, name)
		if not id then return nil end
		found = true
		if kind == "quest" then
			return ("|cff%s|Hquest:%d|h%s[%s]|h|r"):format(QUEST_HEX, id, QUEST_ICON, name)
		end
		local icon = ns.Try(C_Item.GetItemIconByID, id)
		local price = PriceText(id)
		return ("|cff%s|Hitem:%d|h%s[%s]|h|r%s"):format(ItemHex(id), id,
			icon and ("|T%s:0|t"):format(icon) or "", name, price and (" " .. price) or "")
	end)
	return out, found
end

local function RealItemLink(id)
	local _, link = ns.Try(C_Item.GetItemInfo, id)
	return ns.PublicString(link)
end

Tag.RealItemLink = RealItemLink

local function QuestName(id)
	local quest = QuestieEntity("Quest")
	return ns.PublicString(ns.Try(C_QuestLog.GetTitleForQuestID, id))
		or (quest and ns.PublicString(ns.Try(quest.Get, id, "name")))
		or ("Quest " .. id)
end

local function InLog(id)
	return ns.PublicNumber(ns.Try(C_QuestLog.GetLogIndexForQuestID, id)) ~= nil
end

-- Where a quest is picked up: map, x, y (0-100), the giver's name, and whether
-- an item starts it instead. From QuestieDB's givers and spawns, using
-- Questie's area -> map table; a spawn on the map you're on wins.
local function QuestStart(id)
	local quest = QuestieEntity("Quest")
	local startedBy = quest and ns.Try(quest.Get, id, "startedBy")
	if type(startedBy) ~= "table" then return end
	local loader = _G.QuestieLoader
	local zones = loader and loader.ImportModule and ns.Try(loader.ImportModule, loader, "ZoneDB")
	local here = ns.PublicNumber(ns.Try(C_Map.GetBestMapForUnit, "player"))
	local best
	if zones and zones.GetUiMapIdByAreaId then
		for i, which in ipairs({ "Npc", "Object" }) do
			local entity = QuestieEntity(which)
			for _, giver in ipairs(entity and type(startedBy[i]) == "table" and startedBy[i] or {}) do
				local spawns = ns.Try(entity.Get, giver, "spawns")
				for area, points in pairs(type(spawns) == "table" and spawns or {}) do
					local map = ns.Try(zones.GetUiMapIdByAreaId, zones, area)
					local p = type(points) == "table" and points[1]
					if map and p and tonumber(p[1]) and tonumber(p[2]) and p[1] >= 0 and p[2] >= 0
						and ns.Try(C_Map.CanSetUserWaypointOnMap, map) then
						if not best or map == here then
							best = { map = map, x = p[1], y = p[2], giver = ns.Try(entity.Get, giver, "name") }
						end
						if map == here then return best end
					end
				end
			end
		end
	end
	if best then return best end
	if type(startedBy[3]) == "table" and startedBy[3][1] then return { fromItem = startedBy[3][1] } end
end

local function ShowQuestStart(id)
	local name = QuestName(id)
	if ns.Try(C_QuestLog.IsQuestFlaggedCompleted, id) then
		ns.Print(("You've already done %s."):format(name))
	end
	local start = QuestStart(id)
	if start and start.map then
		ns.Try(C_Map.SetUserWaypoint, UiMapPoint.CreateFromCoordinates(start.map, start.x / 100, start.y / 100))
		ns.Try(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
		ns.Try(OpenWorldMap, start.map)
		ns.Print(("%s starts at %s: waypoint set."):format(name, ns.PublicString(start.giver) or "the marked spot"))
	elseif start and start.fromItem then
		local item = QuestieEntity("Item")
		local itemName = item and ns.Try(item.Get, start.fromItem, "name")
		ns.Print(("%s starts from an item: %s."):format(name, ns.PublicString(itemName) or ("item " .. start.fromItem)))
	else
		ns.Print(("No location known for %s (needs Questie)."):format(name))
	end
end

local function OnLinkClick(_, link, text, button)
	local kind, id = tostring(link):match("^(%a+):(%d+)")
	id = tonumber(id)
	if not id then return end
	if kind == "quest" then
		if InLog(id) then
			ns.Try(QuestMapFrame_OpenToQuestDetails, id)
		else
			ShowQuestStart(id)
		end
	elseif kind == "item" then
		local full = RealItemLink(id)
		local payload = full and full:match("|H(item:[^|]+)|h") or ("item:" .. id)
		ns.Try(SetItemRef, payload, full or text, button)
	end
end

local function OnLinkEnter(self, link)
	self.overLink = true
	local kind, id = tostring(link):match("^(%a+):(%d+)")
	id = tonumber(id)
	if not id then return end
	GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
	if kind == "item" then
		GameTooltip:SetHyperlink("item:" .. id)
	else
		GameTooltip:SetText(QuestName(id), 1, 0.82, 0)
		local quest = QuestieEntity("Quest")
		local level = quest and tonumber(ns.Try(quest.Get, id, "questLevel"))
		if level and level > 0 then GameTooltip:AddLine("Level " .. level, 0.9, 0.9, 0.9) end
		GameTooltip:AddLine(InLog(id) and "In your quest log: click to open." or "Click to show where it starts.", 0.5, 0.8, 1)
	end
	GameTooltip:Show()
end

local pendingLinks = {}

local function EnableLinks(view)
	if InCombatLockdown() then
		pendingLinks[view] = true
		return
	end
	view:SetHyperlinksEnabled(true)
	view.linksOn = true
end

-- A read view lying over a text box. Clicking off a link starts editing.
local function CreateView(parent, box, width)
	local v = CreateFrame("Frame", nil, parent)
	v:SetPoint("TOPLEFT", box, "TOPLEFT")
	v:SetSize(width, LINE_H)
	v:SetFrameLevel(box:GetFrameLevel() + 2)
	v:EnableMouse(true)
	v.text = v:CreateFontString(nil, "OVERLAY")
	v.text:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 12, "")
	v.text:SetTextColor(INK[1], INK[2], INK[3])
	v.text:SetPoint("TOPLEFT")
	v.text:SetWidth(width)
	v.text:SetJustifyH("LEFT")
	v.text:SetWordWrap(true)
	if v.text.SetNonSpaceWrap then v.text:SetNonSpaceWrap(true) end
	EnableLinks(v)
	v:SetScript("OnHyperlinkClick", OnLinkClick)
	v:SetScript("OnHyperlinkEnter", OnLinkEnter)
	v:SetScript("OnHyperlinkLeave", function(self)
		self.overLink = nil
		GameTooltip:Hide()
	end)
	v:SetScript("OnHide", function(self)
		if self.overLink then GameTooltip:Hide() end
		self.overLink = nil
	end)
	v:SetScript("OnMouseUp", function(self)
		if self.overLink then return end
		box:SetFocus()
		box:SetCursorPosition(#(box:GetText() or ""))
	end)
	v:Hide()
	return v
end

-- Shows the view if the text has tags and isn't being edited. True if shown.
local function SetView(v, box, note, text, dim)
	local out, found
	if note and v.linksOn and not box:HasFocus() then out, found = Render(note, text) end
	if found then
		v.text:SetText(out)
		v:SetHeight(math.max(LINE_H, math.ceil(v.text:GetStringHeight())))
		v:SetAlpha(dim and 0.45 or 1)
		v:Show()
		box:SetAlpha(0)
	else
		v:Hide()
		box:SetAlpha(1)
	end
	return found
end

local function UpdateTextHolder(f)
	local h = f.edit:GetHeight() or 0
	if f.view:IsShown() then h = math.max(h, f.view:GetHeight()) end
	f.textChild:SetHeight(math.max(h, 1))
end

-- A borderless edit box in ink for checklist items. It's multi-line so long
-- items wrap, but an item stays one paragraph: Enter runs onEnter instead of
-- adding a line break (on whichever of OnEnterPressed / a typed "\n" the
-- client delivers, once per key press).
local function ItemBox(parent, onEnter)
	local e = CreateFrame("EditBox", nil, parent)
	e:SetMultiLine(true)
	e:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 12, "")
	e:SetTextColor(INK[1], INK[2], INK[3])
	e:SetShadowOffset(0, 0)
	e:SetAutoFocus(false)
	e:SetMaxLetters(200)
	e:SetWidth(ITEM_W)
	e:SetHeight(LINE_H)
	e:SetScript("OnEscapePressed", e.ClearFocus)
	local lastEnter
	local function Enter(self)
		local now = GetTime()
		if lastEnter == now then return end
		lastEnter = now
		if Tag.Owns(self) then
			Tag.Accept()
			return
		end
		onEnter(self)
	end
	e:SetScript("OnEnterPressed", Enter)
	e.Enter = Enter
	-- A quest tag picked with Enter uses up this key press.
	function e:MarkEnter() lastEnter = GetTime() end
	-- Called first by the boxes' own OnTextChanged: takes out a typed line
	-- break and returns true if there was one (the caller saves, then Enters).
	function e:StripBreaks(userInput)
		local text = self:GetText()
		if not text:find("[\r\n]") then return false end
		self:SetText((text:gsub("[\r\n]+", " "):gsub("%s+$", "")))
		return userInput and true or false
	end
	return e
end

-- Height the text takes, wrapped at the item width.
local function TextHeight(f, text)
	f.measure:SetText((text and text ~= "") and text or " ")
	return math.max(LINE_H, math.ceil(f.measure:GetStringHeight()))
end

-- Ticked items are dimmed; a one-line item also gets a line through it.
local function UpdateStrike(row, height)
	local done = row.item and row.item.done
	row.edit:SetTextColor(INK[1], INK[2], INK[3], done and 0.45 or 1)
	if not done or height > LINE_H + 4 then
		row.strike:Hide()
		return
	end
	row.measure:SetText(row.edit:GetText())
	local width = row.view:IsShown() and row.view.text:GetStringWidth() or row.measure:GetStringWidth()
	row.strike:SetWidth(math.max(1, math.min(ITEM_W, width)))
	row.strike:Show()
end

local function CreateItemRow(f)
	local row = CreateFrame("Frame", nil, f.listChild)
	row:SetSize(TEXT_W, ITEM_H)

	row.check = CreateFrame("Button", nil, row)
	row.check:SetSize(12, 12)
	row.check:SetPoint("TOPLEFT", 2, -4)
	S.Body(row.check, { 1, 1, 1, 0.35 }, INK)
	row.check.pShadow:Hide()
	row.check.tick = S.Texture(row.check, "ARTWORK", 0)
	row.check.tick:SetPoint("TOPLEFT", 2, -2)
	row.check.tick:SetPoint("BOTTOMRIGHT", -2, 2)
	row.check.tick:SetVertexColor(INK[1], INK[2], INK[3], 0.85)
	row.check:SetScript("OnClick", function()
		local item = row.item
		if not item then return end
		item.done = not item.done or nil
		if SOUNDKIT then
			PlaySound(item.done and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
		end
		Touch(f.note)
		RefreshItems(f)
	end)

	row.edit = ItemBox(row, function() f.addBox:SetFocus() end)
	row.edit:SetPoint("TOPLEFT", 20, -3)
	row.edit:SetScript("OnTextChanged", function(self, userInput)
		if Tag.OnText(self, userInput) then return end
		local broke = self:StripBreaks(userInput)
		if (userInput or broke) and row.item then
			row.item.text = self:GetText()
			Touch(f.note)
			RefreshItems(f)     -- the row may need another line
		end
		if broke then self:Enter() end
	end)
	-- An item emptied by hand is removed.
	row.edit:SetScript("OnEditFocusLost", function(self)
		self:HighlightText(0, 0)
		if row.item and Trim(self:GetText()) == "" and f.note and f.note.items then
			table.remove(f.note.items, row.index)
			Touch(f.note)
			RefreshItems(f)
		end
	end)

	row.strike = S.Texture(row, "OVERLAY", 0)
	row.strike:SetHeight(1)
	row.strike:SetPoint("TOPLEFT", row.edit, "TOPLEFT", 0, -math.floor(LINE_H / 2))
	row.strike:SetVertexColor(INK[1], INK[2], INK[3], 0.6)
	row.measure = row:CreateFontString(nil, "OVERLAY")
	row.measure:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 12, "")
	row.measure:Hide()

	row.remove = InkButton(row, "x", 16)
	row.remove:SetPoint("TOPRIGHT", 0, -1)
	row.remove.tooltip = "Remove this item."
	row.remove:SetScript("OnClick", function()
		if not row.item then return end
		table.remove(f.note.items, row.index)
		Touch(f.note)
		RefreshItems(f)
	end)
	AttachTags(row.edit, f)
	row.view = CreateView(row, row.edit, ITEM_W)
	row.edit:HookScript("OnEditFocusGained", function() RefreshItems(f) end)
	row.edit:HookScript("OnEditFocusLost", function() RefreshItems(f) end)
	return row
end

RefreshItems = function(f)
	local items = f.note and f.note.items
	if not items then return end
	local y = 0
	for i, item in ipairs(items) do
		local row = f.itemRows[i]
		if not row then
			row = CreateItemRow(f)
			f.itemRows[i] = row
		end
		row.index, row.item = i, item
		if row.edit:GetText() ~= item.text then
			row.edit:SetText(item.text)
			row.edit:SetCursorPosition(0)
		end
		row.check.tick:SetShown(item.done and true or false)
		local h = TextHeight(f, item.text)
		if SetView(row.view, row.edit, f.note, item.text, item.done) then
			h = math.max(h, row.view:GetHeight())
		end
		row.edit:SetHeight(h)
		row:SetHeight(math.max(ITEM_H, h + 6))
		UpdateStrike(row, h)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 0, y)
		row:Show()
		y = y - math.max(ITEM_H, h + 6)
	end
	for i = #items + 1, #f.itemRows do
		local row = f.itemRows[i]
		row.item = nil
		row:Hide()
	end
	local addH = TextHeight(f, f.addBox:GetText())
	if SetView(f.addView, f.addBox, f.note, f.addBox:GetText()) then
		addH = math.max(addH, f.addView:GetHeight())
	end
	f.addBox:SetHeight(addH)
	f.addBox:ClearAllPoints()
	f.addBox:SetPoint("TOPLEFT", 20, y - 3)
	f.listChild:SetHeight(-y + math.max(ITEM_H, addH + 6))
	f.clear:SetShown(Progress(f.note) > 0)
end

ApplyMode = function(f)
	local list = IsList(f.note)
	if list and type(f.note.items) ~= "table" then f.note.items = {} end
	f.textChild:SetShown(not list)
	f.listChild:SetShown(list)
	f.scroll:SetScrollChild(list and f.listChild or f.textChild)
	f.scroll:SetVerticalScroll(0)
	f.mode:SetOn(list)
	if list then
		RefreshItems(f)
	else
		f.clear:Hide()
		RefreshView(f)
	end
	UpdateScrollBar(f)
end

-- Draws the note's tags again (open, edit finished, new prices or item data).
RefreshView = function(f)
	if not f.note then return end
	if IsList(f.note) then
		RefreshItems(f)
	else
		SetView(f.view, f.edit, f.note, f.note.text)
		UpdateTextHolder(f)
		UpdateScrollBar(f)
	end
end

local function ChatText(box, userInput)
	if userInput and db.chatTags then
		Tag.Update(box)
	elseif Tag.Owns(box) then
		Tag.Hide()
	end
end

local function ChatFocusLost(box)
	if Tag.Owns(box) and not Tag.popup:IsMouseOver() then Tag.Hide() end
end

-- Hooks each chat window's edit box once.
local function HookChatBoxes()
	for i = 1, NUM_CHAT_WINDOWS or 10 do
		local box = _G["ChatFrame" .. i .. "EditBox"]
		if box and not chatBoxes[box] then
			chatBoxes[box] = true
			box:HookScript("OnTextChanged", ChatText)
			box:HookScript("OnEditFocusLost", ChatFocusLost)
		end
	end
end

local function RefreshAllViews()
	for _, f in pairs(frames) do
		if f:IsShown() then RefreshView(f) end
	end
end

local function CreateNoteFrame()
	local f = S.Window({ title = "", width = NOTE_W, height = NOTE_H, strata = "MEDIUM",
		onMoved = function(self) if self.note then S.SavePoint(self, self.note, "point") end end })
	f.title:Hide()
	f.close.label:SetTextColor(INK[1], INK[2], INK[3], 0.6)
	f.close:SetScript("OnLeave", function(self) self.label:SetTextColor(INK[1], INK[2], INK[3], 0.6) end)

	-- A darker band of paper behind the title.
	f.band = S.Texture(f, "BACKGROUND", -2)
	f.band:SetPoint("TOPLEFT")
	f.band:SetPoint("TOPRIGHT")
	f.band:SetHeight(S.TITLE_H)

	f.titleBox = CreateFrame("EditBox", nil, f)
	f.titleBox:SetFontObject(GameFontNormal)
	f.titleBox:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 13, "")
	f.titleBox:SetTextColor(INK[1], INK[2], INK[3])
	f.titleBox:SetShadowOffset(0, 0)
	f.titleBox:SetAutoFocus(false)
	f.titleBox:SetMaxLetters(60)
	f.titleBox:SetPoint("TOPLEFT", S.PAD - 2, -3)
	f.titleBox:SetPoint("RIGHT", f, "RIGHT", -76, 0)
	f.titleBox:SetHeight(S.TITLE_H - 6)
	f.titleHint = S.Text(f.titleBox, 13)
	f.titleHint:SetShadowOffset(0, 0)
	f.titleHint:SetPoint("LEFT")
	f.titleHint:SetTextColor(INK[1], INK[2], INK[3], 0.4)
	f.titleHint:SetText("Title")
	f.titleBox:SetScript("OnEscapePressed", f.titleBox.ClearFocus)
	f.titleBox:SetScript("OnEnterPressed", function()
		if IsList(f.note) then f.addBox:SetFocus() else f.edit:SetFocus() end
	end)
	f.titleBox:SetScript("OnTextChanged", function(self, userInput)
		f.titleHint:SetShown(self:GetText() == "")
		if userInput and f.note then
			f.note.title = self:GetText()
			Touch(f.note)
		end
	end)

	f.pin = InkButton(f, "Pin", 46)
	f.pin:SetPoint("RIGHT", f.close, "LEFT", -2, 0)
	f.pin.tooltip = "A pinned note stays open, also after a reload, until you un-pin it."
	f.pin:SetScript("OnClick", function()
		f.note.pinned = not f.note.pinned or nil
		ApplyPin(f)
		Touch(f.note)
	end)

	-- The title box would swallow drags on the title bar, so a handle sits on
	-- top of it: drag it to move the note, click it to edit the title. While
	-- the title is being edited the handle steps aside, so the cursor can be
	-- placed with the mouse.
	f.dragHandle = CreateFrame("Button", nil, f)
	f.dragHandle:SetPoint("TOPLEFT")
	f.dragHandle:SetPoint("BOTTOMRIGHT", f.pin, "BOTTOMLEFT", -2, -4)
	f.dragHandle:SetFrameLevel(f.titleBox:GetFrameLevel() + 2)
	f.dragHandle:RegisterForDrag("LeftButton")
	f.dragHandle:SetScript("OnDragStart", function() f:StartMoving() end)
	f.dragHandle:SetScript("OnDragStop", function()
		f:StopMovingOrSizing()
		if f.note then S.SavePoint(f, f.note, "point") end
	end)
	f.dragHandle:SetScript("OnMouseDown", function() f:Raise() end)
	f.dragHandle:SetScript("OnClick", function()
		f.titleBox:SetFocus()
		f.titleBox:SetCursorPosition(#f.titleBox:GetText())
	end)
	f.titleBox:SetScript("OnEditFocusGained", function() f.dragHandle:Hide() end)
	f.titleBox:SetScript("OnEditFocusLost", function()
		f.titleBox:HighlightText(0, 0)
		f.dragHandle:Show()
	end)

	-- The text, in a scroll frame with a slim bar.
	f.scroll = CreateFrame("ScrollFrame", nil, f)
	f.scroll:SetPoint("TOPLEFT", S.PAD, -S.TITLE_H - 6)
	f.scroll:SetPoint("BOTTOMRIGHT", -S.PAD - 10, 30)
	f.textChild = CreateFrame("Frame", nil, f.scroll)
	f.textChild:SetSize(TEXT_W, 1)
	f.edit = CreateFrame("EditBox", nil, f.textChild)
	f.edit:SetPoint("TOPLEFT")
	f.edit:SetMultiLine(true)
	f.edit:SetAutoFocus(false)
	f.edit:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 12, "")
	f.edit:SetTextColor(INK[1], INK[2], INK[3])
	f.edit:SetShadowOffset(0, 0)
	f.edit:SetWidth(NOTE_W - S.PAD * 2 - 10)
	f.edit:SetMaxLetters(4000)
	f.scroll:SetScrollChild(f.textChild)
	f.view = CreateView(f.textChild, f.edit, TEXT_W)
	f.edit:SetScript("OnSizeChanged", function() UpdateTextHolder(f) end)
	f.edit:SetScript("OnEditFocusGained", function() RefreshView(f) end)
	f.edit:SetScript("OnEditFocusLost", function() RefreshView(f) end)
	f.textHint = S.Text(f.edit, 12)
	f.textHint:SetShadowOffset(0, 0)
	f.textHint:SetPoint("TOPLEFT")
	f.textHint:SetTextColor(INK[1], INK[2], INK[3], 0.4)
	f.textHint:SetText("Write a reminder...")
	f.edit:SetScript("OnEscapePressed", f.edit.ClearFocus)
	f.edit:SetScript("OnTextChanged", function(self, userInput)
		if Tag.OnText(self, userInput) then return end
		f.textHint:SetShown(self:GetText() == "")
		if userInput and f.note then
			f.note.text = self:GetText()
			Touch(f.note)
		end
	end)
	-- Checklist: rows of tick box + item text, and an "Add item" box at the end.
	f.listChild = CreateFrame("Frame", nil, f.scroll)
	f.listChild:SetSize(TEXT_W, ITEM_H)
	f.listChild:Hide()
	f.itemRows = {}
	-- Measures wrapped item text, so rows can grow to fit it.
	f.measure = f.listChild:CreateFontString(nil, "OVERLAY")
	f.measure:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 12, "")
	f.measure:SetWidth(ITEM_W)
	f.measure:SetWordWrap(true)
	if f.measure.SetNonSpaceWrap then f.measure:SetNonSpaceWrap(true) end
	f.measure:Hide()
	f.addBox = ItemBox(f.listChild, function(self)
		local text = Trim(self:GetText())
		if text == "" then
			self:ClearFocus()
			return
		end
		table.insert(f.note.items, { text = text })
		self:SetText("")
		Touch(f.note)
		RefreshItems(f)
		-- Keep the add box in view as the list grows.
		C_Timer.After(0, function()
			f.scroll:SetVerticalScroll(f.scroll:GetVerticalScrollRange() or 0)
			UpdateScrollBar(f)
		end)
	end)
	f.addHint = S.Text(f.addBox, 12)
	f.addHint:SetShadowOffset(0, 0)
	f.addHint:SetPoint("TOPLEFT")
	f.addHint:SetTextColor(INK[1], INK[2], INK[3], 0.4)
	f.addHint:SetText("+ Add item")
	f.addBox:SetScript("OnTextChanged", function(self, userInput)
		if Tag.OnText(self, userInput) then return end
		local broke = self:StripBreaks(userInput)
		f.addHint:SetShown(self:GetText() == "")
		if (userInput or broke) and f.note and f.note.items then RefreshItems(f) end
		if broke then self:Enter() end
	end)

	-- Keep the cursor in view while typing.
	f.edit:SetScript("OnCursorChanged", function(_, _, y, _, h)
		local top = -y
		local view = f.scroll:GetHeight()
		local scroll = f.scroll:GetVerticalScroll()
		if top < scroll then
			f.scroll:SetVerticalScroll(top)
		elseif top + h > scroll + view then
			f.scroll:SetVerticalScroll(math.min(f.scroll:GetVerticalScrollRange(), top + h - view))
		end
		UpdateScrollBar(f)
	end)
	f.scroll:SetScript("OnScrollRangeChanged", function() UpdateScrollBar(f) end)
	f.scroll:EnableMouseWheel(true)
	f.scroll:SetScript("OnMouseWheel", function(self, delta)
		local v = math.max(0, math.min(self:GetVerticalScrollRange(), self:GetVerticalScroll() - delta * 24))
		self:SetVerticalScroll(v)
		UpdateScrollBar(f)
	end)
	-- Clicking the empty part of the paper puts the cursor in the text.
	f.scroll:SetScript("OnMouseDown", function()
		if IsList(f.note) then f.addBox:SetFocus() else f.edit:SetFocus() end
	end)

	f.bar = S.ScrollBar(f, function(v) f.scroll:SetVerticalScroll(v) end)
	f.bar:SetPoint("TOPRIGHT", -S.PAD + 4, -S.TITLE_H - 6)
	f.bar:SetPoint("BOTTOMRIGHT", -S.PAD + 4, 30)
	f.bar:Hide()

	-- Bottom row: areas, colour, delete.
	f.areas = InkButton(f, "Areas", 44)
	f.areas:SetPoint("BOTTOMLEFT", S.PAD - 4, 7)
	f.areas.tooltip = "Make this note open by itself in a zone or capital city."
	f.areas:SetScript("OnClick", function()
		if areaPanel and areaPanel:IsShown() and areaPanel.owner == f then
			areaPanel:Hide()
		else
			RefreshAreaPanel(f)
		end
	end)

	f.swatch = CreateFrame("Button", nil, f)
	f.swatch:SetSize(14, 14)
	f.swatch:SetPoint("LEFT", f.areas, "RIGHT", 8, 0)
	S.Body(f.swatch, nil, INK)
	f.swatch.tex = S.Texture(f.swatch, "ARTWORK", 0)
	f.swatch.tex:SetAllPoints()
	f.swatch:SetScript("OnClick", function()
		f.note.color = (f.note.color or 1) % #PAPERS + 1
		ApplyPaper(f)
	end)
	f.swatch:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Paper colour: " .. Paper(f.note)[1] .. "\nClick for the next one.", nil, nil, nil, nil, true)
		GameTooltip:Show()
	end)
	f.swatch:SetScript("OnLeave", GameTooltip_Hide)

	f.mode = InkButton(f, "List", 30)
	f.mode:SetPoint("LEFT", f.swatch, "RIGHT", 8, 0)
	f.mode.tooltip = "Switch between text and a checklist. Each line becomes an item, and back."
	f.mode:SetScript("OnClick", function()
		local note = f.note
		if IsList(note) then
			note.text = ItemsToText(note.items)
			note.kind, note.items = nil, nil
			f.edit:SetText(note.text)
			f.textHint:SetShown(note.text == "")
		else
			note.items = TextToItems(note.text)
			note.kind = "list"
			note.text = ""
			f.edit:SetText("")
		end
		Touch(note)
		ApplyMode(f)
	end)

	f.clear = InkButton(f, "Clear ticked", 70)
	f.clear.tooltip = "Remove the ticked items."
	f.clear:SetScript("OnClick", function()
		local items = f.note.items
		for i = #items, 1, -1 do
			if items[i].done then table.remove(items, i) end
		end
		Touch(f.note)
		RefreshItems(f)
	end)

	f.delete = InkButton(f, "Delete", 46)
	f.delete:SetPoint("BOTTOMRIGHT", -S.PAD + 4, 7)
	f.clear:SetPoint("RIGHT", f.delete, "LEFT", -4, 0)
	f.delete:SetScript("OnClick", function()
		local note = f.note
		ns.Confirm(("Delete the note \"%s\"?"):format(Label(note)), function() M.Delete(note.id) end)
	end)

	f:SetScript("OnHide", function(self)
		self.titleBox:ClearFocus()
		self.edit:ClearFocus()
		self.addBox:ClearFocus()
		for _, row in ipairs(self.itemRows) do row.edit:ClearFocus() end
		if areaPanel and areaPanel.owner == self then areaPanel:Hide() end
	end)
	f:SetScript("OnMouseDown", function(self) self:Raise() end)
	AttachTags(f.edit, f)
	AttachTags(f.addBox, f)
	f.addView = CreateView(f.listChild, f.addBox, ITEM_W)
	f.addBox:HookScript("OnEditFocusGained", function() RefreshItems(f) end)
	f.addBox:HookScript("OnEditFocusLost", function() RefreshItems(f) end)
	return f
end

-- Shows a note's window (creating it when needed). Returns the window.
OpenNote = function(id)
	local note = db.list[id]
	if not note then return end
	local f = frames[id]
	if not f then
		f = table.remove(freeFrames) or CreateNoteFrame()
		frames[id] = f
		f.note = note
		f.titleBox:SetText(note.title or "")
		f.edit:SetText(note.text or "")
		f.titleHint:SetShown((note.title or "") == "")
		f.textHint:SetShown((note.text or "") == "")
		f.addBox:SetText("")
		ApplyMode(f)
		ApplyPaper(f)
		ApplyPin(f)
		ApplyAreaTag(f)
		S.RestorePoint(f, note, "point", DefaultPoint())
	end
	f:Show()
	f:Raise()
	return f
end

local function CloseNote(id)
	local f = frames[id]
	if f then f:Hide() end
end

function M.Delete(id)
	local f = frames[id]
	if f then
		f:Hide()
		f.note = nil
		frames[id] = nil
		freeFrames[#freeFrames + 1] = f
	end
	db.list[id] = nil
	lastMatch[id] = nil
	if listFrame and listFrame:IsShown() then RefreshList() end
end

--------------------------------------------------------------------------------
-- Areas panel (one, shared, attached under the note that opened it)
--------------------------------------------------------------------------------

local function CurrentPlace()
	local zone = ns.PublicString(GetRealZoneText and GetRealZoneText())
	local sub = ns.PublicString(GetSubZoneText and GetSubZoneText())
	local mapID = C_Map and ns.PublicNumber(ns.Try(C_Map.GetBestMapForUnit, "player"))
	if sub == zone then sub = nil end
	return zone, sub, mapID
end

local function InCapital(zone, mapID)
	return (mapID and CAPITAL_MAPS[mapID]) or (zone and CAPITAL_NAMES[zone]) or false
end

local function BuildAreaPanel()
	areaPanel = CreateFrame("Frame", nil, UIParent)
	areaPanel:SetSize(NOTE_W, 100)
	areaPanel:SetFrameStrata("MEDIUM")
	areaPanel:EnableMouse(true)
	S.Body(areaPanel)
	S.Scaled(areaPanel)
	areaPanel:Hide()
	areaPanel.heading = S.Heading(areaPanel, "Opens by itself in", -8)
	areaPanel.empty = S.Text(areaPanel, 11)
	areaPanel.empty:SetTextColor(0.5, 0.5, 0.5)
	areaPanel.empty:SetText("No zones yet.")
	areaPanel.rows = {}

	areaPanel.addZone = S.Button(areaPanel, "+ This zone", 112, 20)
	areaPanel.addSub = S.Button(areaPanel, "+ Subzone", 112, 20)
	local function Add(which)
		local note = areaPanel.owner and areaPanel.owner.note
		if not note then return end
		local zone, sub = CurrentPlace()
		local name = (which == "sub") and sub or zone
		if not name then return end
		note.zones = note.zones or {}
		note.zones[name] = true
		lastMatch[note.id] = true          -- you're already here; don't pop it open now
		Touch(note)
		RefreshAreaPanel(areaPanel.owner)
	end
	areaPanel.addZone:SetScript("OnClick", function() Add("zone") end)
	areaPanel.addSub:SetScript("OnClick", function() Add("sub") end)

	areaPanel.capitals = Check(areaPanel, "Any capital city", function()
		local note = areaPanel.owner.note
		note.capitals = not note.capitals or nil
		Touch(note)
		RefreshAreaPanel(areaPanel.owner)
	end)
	areaPanel.mine = Check(areaPanel, "Only on this character", function()
		local note = areaPanel.owner.note
		note.owner = (not note.owner) and Me() or nil
		Touch(note)
		RefreshAreaPanel(areaPanel.owner)
	end)
end

RefreshAreaPanel = function(f)
	if not areaPanel then BuildAreaPanel() end
	local note = f.note
	areaPanel.owner = f
	areaPanel:SetScale(f:GetScale())

	local names = {}
	for name in pairs(note.zones or {}) do names[#names + 1] = name end
	table.sort(names)

	local y = -28
	for i, name in ipairs(names) do
		local row = areaPanel.rows[i]
		if not row then
			row = CreateFrame("Frame", nil, areaPanel)
			row:SetHeight(18)
			row.text = S.Text(row, 11)
			row.text:SetPoint("LEFT", 4, 0)
			row.text:SetTextColor(0.9, 0.9, 0.9)
			row.remove = S.CloseButton(row)
			row.remove:SetPoint("RIGHT")
			row.remove:SetScript("OnClick", function()
				local owner = areaPanel.owner
				owner.note.zones[row.name] = nil
				Touch(owner.note)
				RefreshAreaPanel(owner)
			end)
			areaPanel.rows[i] = row
		end
		row.name = name
		row.text:SetText(name)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", S.PAD, y)
		row:SetPoint("TOPRIGHT", -S.PAD, y)
		row:Show()
		y = y - 18
	end
	for i = #names + 1, #areaPanel.rows do areaPanel.rows[i]:Hide() end
	areaPanel.empty:SetShown(#names == 0)
	if #names == 0 then
		areaPanel.empty:ClearAllPoints()
		areaPanel.empty:SetPoint("TOPLEFT", S.PAD + 4, y - 3)
		y = y - 18
	end

	y = y - 6
	local zone, sub = CurrentPlace()
	areaPanel.addZone:ClearAllPoints()
	areaPanel.addZone:SetPoint("TOPLEFT", S.PAD, y)
	areaPanel.addZone.tooltip = zone and ("Add " .. zone) or "No zone name here."
	areaPanel.addZone:SetEnabled(zone ~= nil)
	areaPanel.addSub:ClearAllPoints()
	areaPanel.addSub:SetPoint("TOPRIGHT", -S.PAD, y)
	areaPanel.addSub.tooltip = sub and ("Add " .. sub) or "You're not in a subzone."
	areaPanel.addSub:SetEnabled(sub ~= nil)
	y = y - 28

	areaPanel.capitals:ClearAllPoints()
	areaPanel.capitals:SetPoint("TOPLEFT", S.PAD, y)
	areaPanel.capitals:SetChecked(note.capitals)
	y = y - 20
	areaPanel.mine:ClearAllPoints()
	areaPanel.mine:SetPoint("TOPLEFT", S.PAD, y)
	areaPanel.mine.label:SetText("Only on " .. ShortMe())
	areaPanel.mine:SetChecked(note.owner ~= nil)
	y = y - 26

	areaPanel:SetHeight(-y)
	areaPanel:ClearAllPoints()
	areaPanel:SetPoint("TOP", f, "BOTTOM", 0, -4)
	areaPanel:Show()
	ApplyAreaTag(f)
end

--------------------------------------------------------------------------------
-- Opening notes when you enter their area
--------------------------------------------------------------------------------

local function Matches(note, zone, sub, mapID, testAll)
	if testAll then return HasArea(note) end
	local zones = note.zones or {}
	if (zone and zones[zone]) or (sub and zones[sub]) then return true end
	return note.capitals and InCapital(zone, mapID) and true or false
end

-- Opens notes whose area you just entered. testAll: act as if you entered
-- every note's area.
local function CheckAreas(testAll)
	if not db.popup and not testAll then return 0 end
	local zone, sub, mapID = CurrentPlace()
	local opened = 0
	for id, note in pairs(db.list) do
		if Visible(note) then
			local now = Matches(note, zone, sub, mapID, testAll)
			if now and (testAll or not lastMatch[id]) then
				local f = frames[id]
				if not (f and f:IsShown()) then
					OpenNote(id)
					opened = opened + 1
				end
			end
			if not testAll then lastMatch[id] = now or nil end
		end
	end
	if opened > 0 and db.sound and SOUNDKIT then
		PlaySound(SOUNDKIT.IG_QUEST_LOG_OPEN)
	end
	return opened
end

--------------------------------------------------------------------------------
-- The list
--------------------------------------------------------------------------------

local offset, sorted = 0, {}

local function MaxOffset()
	return math.max(0, #sorted - LIST_ROWS)
end

local function Ago(t)
	local secs = time() - (t or 0)
	if secs < 3600 then return math.max(1, math.floor(secs / 60)) .. "m" end
	if secs < 86400 then return math.floor(secs / 3600) .. "h" end
	return math.floor(secs / 86400) .. "d"
end

local function Tags(note)
	local tags = {}
	if note.pinned then tags[#tags + 1] = "|cff4fc3f7pinned|r" end
	if HasArea(note) then tags[#tags + 1] = "|cffffd100area|r" end
	if not note.owner then tags[#tags + 1] = "|cff40ff40shared|r" end
	if IsList(note) then
		local done, total = Progress(note)
		tags[#tags + 1] = ("|cffd9c79a%d/%d|r"):format(done, total)
	end
	tags[#tags + 1] = S.DIM .. Ago(note.updated) .. "|r"
	return table.concat(tags, "  ")
end

RefreshList = function()
	sorted = SortedNotes()
	offset = math.min(offset, MaxOffset())
	for i, row in ipairs(listFrame.rows) do
		local note = sorted[offset + i]
		row.note = note
		if note then
			local _, r, g, b = unpack(Paper(note))
			row.swatch:SetVertexColor(r, g, b)
			row.name:SetText(Label(note))
			local f = frames[note.id]
			local open = f and f:IsShown()
			row.name:SetTextColor(open and 1 or 0.85, open and 1 or 0.85, open and 1 or 0.85)
			row.tags:SetText(Tags(note))
			row:Show()
		else
			row:Hide()
		end
	end
	listFrame.empty:SetShown(#sorted == 0)
	listFrame.scrollBar:SetMinMaxValues(0, MaxOffset())
	listFrame.scrollBar:SetValue(offset)
	listFrame.scrollBar:SetShown(MaxOffset() > 0)
end

local function Row_OnClick(self, button)
	local note = self.note
	if not note then return end
	if button == "RightButton" then
		ns.Confirm(("Delete the note \"%s\"?"):format(Label(note)), function() M.Delete(note.id) end)
		return
	end
	local f = frames[note.id]
	if f and f:IsShown() and not note.pinned then
		CloseNote(note.id)
	else
		OpenNote(note.id)
	end
	RefreshList()
end

local function Row_OnEnter(self)
	if not self.note then return end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText(Label(self.note), 1, 0.95, 0.85)
	if IsList(self.note) then
		for i, item in ipairs(self.note.items) do
			if i > 15 then
				GameTooltip:AddLine(("... and %d more"):format(#self.note.items - 15), 0.6, 0.6, 0.6)
				break
			end
			if item.done then
				GameTooltip:AddLine("[x] " .. Plain(item.text), 0.5, 0.5, 0.5)
			else
				GameTooltip:AddLine("[  ] " .. Plain(item.text), 0.9, 0.9, 0.9)
			end
		end
	elseif self.note.text ~= "" then
		GameTooltip:AddLine(Plain(self.note.text):sub(1, 300), 0.9, 0.9, 0.9, true)
	end
	local areas = {}
	for name in pairs(self.note.zones or {}) do areas[#areas + 1] = name end
	if self.note.capitals then areas[#areas + 1] = "any capital city" end
	if #areas > 0 then
		table.sort(areas)
		GameTooltip:AddLine("Opens in: " .. table.concat(areas, ", "), 1, 0.82, 0, true)
	end
	GameTooltip:AddLine("Click: open / close. Right-click: delete.", 0.5, 0.5, 0.5)
	GameTooltip:Show()
end

local function BuildList()
	local top = -S.TITLE_H - 8
	listFrame = S.Window({ name = "PredUINotesList", title = "Notes", width = LIST_W,
		height = -top + LIST_ROWS * ROW_H + 44,
		onMoved = function(self) S.SavePoint(self, db, "listPoint") end })
	S.RestorePoint(listFrame, db, "listPoint", { "CENTER", "CENTER", 0, 0 })

	listFrame.rows = {}
	for i = 1, LIST_ROWS do
		local row = CreateFrame("Button", nil, listFrame)
		row:SetHeight(ROW_H)
		row:SetPoint("TOPLEFT", S.PAD, top - (i - 1) * ROW_H)
		row:SetPoint("TOPRIGHT", -S.PAD - 12, top - (i - 1) * ROW_H)
		row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		S.RowHighlight(row)
		row.swatch = S.Texture(row, "ARTWORK", 0)
		row.swatch:SetSize(4, ROW_H - 6)
		row.swatch:SetPoint("LEFT", 2, 0)
		row.tags = S.Text(row, 10)
		row.tags:SetPoint("RIGHT", -4, 0)
		row.tags:SetJustifyH("RIGHT")
		row.name = S.Text(row, 12)
		row.name:SetPoint("LEFT", row.swatch, "RIGHT", 8, 0)
		row.name:SetPoint("RIGHT", row.tags, "LEFT", -8, 0)
		row.name:SetJustifyH("LEFT")
		row:SetScript("OnClick", Row_OnClick)
		row:SetScript("OnEnter", Row_OnEnter)
		row:SetScript("OnLeave", GameTooltip_Hide)
		listFrame.rows[i] = row
	end

	listFrame.empty = S.Text(listFrame, 12)
	listFrame.empty:SetPoint("TOP", 0, top - 20)
	listFrame.empty:SetTextColor(0.5, 0.5, 0.5)
	listFrame.empty:SetText("No notes yet.")

	listFrame.scrollBar = S.ScrollBar(listFrame, function(v)
		offset = v
		RefreshList()
	end)
	listFrame.scrollBar:SetPoint("TOPRIGHT", -S.PAD, top)
	listFrame.scrollBar:SetHeight(LIST_ROWS * ROW_H)
	listFrame:EnableMouseWheel(true)
	listFrame:SetScript("OnMouseWheel", function(_, delta)
		listFrame.scrollBar:SetValue(math.max(0, math.min(MaxOffset(), offset - delta * 2)))
	end)

	local new = S.Button(listFrame, "New note", 86, 22)
	new:SetPoint("BOTTOMLEFT", S.PAD, 12)
	new:SetScript("OnClick", function() M.New() end)
	local newList = S.Button(listFrame, "New list", 86, 22)
	newList:SetPoint("LEFT", new, "RIGHT", 6, 0)
	newList:SetScript("OnClick", function() M.New(nil, "list") end)
	newList.tooltip = "A checklist: add items and tick them off (shopping lists...)."

	listFrame.hint = S.Text(listFrame, 10)
	listFrame.hint:SetPoint("BOTTOMRIGHT", -S.PAD, 18)
	listFrame.hint:SetTextColor(0.5, 0.5, 0.5)
	listFrame.hint:SetText("Right-click: delete")

	listFrame:SetScript("OnShow", RefreshList)
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

function M.SetOpacity(value)
	db.opacity = math.max(10, math.min(100, math.floor((tonumber(value) or 100) / 5 + 0.5) * 5))
	for _, f in pairs(frames) do
		if f.note then ApplyPaper(f) end
	end
end

function M.ToggleList()
	if listFrame:IsShown() then listFrame:Hide() else listFrame:Show() end
end

function M.New(text, kind)
	local note = NewNote(text, kind)
	local f = OpenNote(note.id)
	if listFrame:IsShown() then RefreshList() end
	if kind == "list" then
		if #note.items > 0 then f.addBox:SetFocus() else f.titleBox:SetFocus() end
	elseif text and text ~= "" then
		f.edit:SetFocus()
	else
		f.titleBox:SetFocus()
	end
	return note
end

-- Plain text for the title box, which can't show coin icons: "3g 20s".
local function PlainMoney(copper)
	copper = math.floor(copper + 0.5)
	local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	if g > 0 then return s > 0 and ("%dg %ds"):format(g, s) or g .. "g" end
	if s > 0 then return c > 0 and ("%ds %dc"):format(s, c) or s .. "s" end
	return c .. "c"
end

-- "12 x #[Copper Ore]" -> 12, "Copper Ore"; nil for lines you typed yourself.
local function ParseShoppingLine(item)
	local qty, name = item.text:match("^(%d+) x #%[(.+)%]$")
	if qty then return tonumber(qty), name end
end

-- Puts the remaining total in the title and redraws the note if it's open.
local function RefreshShoppingNote(note, priceOf)
	local total = 0
	for _, item in ipairs(note.items) do
		local qty, name = ParseShoppingLine(item)
		local id = qty and note.tags["i:" .. name]
		local price = id and not item.done and priceOf(id)
		if price then total = total + price * qty end
	end
	note.title = total > 0 and ("Shopping list (~%s)"):format(PlainMoney(total)) or "Shopping list"
	note.updated = time()
	local f = frames[note.id]
	if f then
		f.titleBox:SetText(note.title)
		f.titleHint:Hide()
		ApplyPin(f)
		RefreshItems(f)
		UpdateScrollBar(f)
	end
end

-- The shopping list's lines as { id, name, qty, done }, or nil if the note is gone.
function ns.GetShoppingList(noteID)
	local note = db and noteID and db.list[noteID]
	if not (note and IsList(note) and Visible(note) and type(note.tags) == "table") then return end
	local lines = {}
	for _, item in ipairs(note.items) do
		local qty, name = ParseShoppingLine(item)
		local id = qty and note.tags["i:" .. name]
		if id then
			lines[#lines + 1] = { id = id, name = name, qty = qty, done = item.done and true or false }
		end
	end
	return lines
end

-- Takes `amount` off a line; at 0 the line is ticked and marked as bought.
function ns.ReduceShoppingLine(noteID, itemID, amount, priceOf)
	local note = db and noteID and db.list[noteID]
	if not (note and IsList(note) and type(note.tags) == "table") then return end
	for _, item in ipairs(note.items) do
		local qty, name = ParseShoppingLine(item)
		if qty and note.tags["i:" .. name] == itemID and not item.done then
			local left = qty - amount
			if left > 0 then
				item.text = ("%d x #[%s]"):format(left, name)
			else
				item.done, item.bought = true, true
			end
			RefreshShoppingNote(note, priceOf)
			return
		end
	end
end

-- For Craft Cost: adds { id, name, qty } lines to the shopping list note, raising
-- the quantity of a line that's already there. priceOf(itemID) prices the total
-- in the title. Makes a new note if noteID is gone. Returns the note's ID.
function ns.AddToShoppingList(noteID, wanted, priceOf)
	local note = noteID and db.list[noteID]
	if not (note and IsList(note) and Visible(note)) then
		note = NewNote("", "list")
	end
	note.tags = type(note.tags) == "table" and note.tags or {}
	local byName = {}
	for _, item in ipairs(note.items) do
		local qty, name = ParseShoppingLine(item)
		if qty then byName[name] = { item = item, qty = qty } end
	end
	for _, w in ipairs(wanted) do
		note.tags["i:" .. w.name] = w.id
		local line = byName[w.name]
		if line then
			-- A line that was all bought starts again; its old amount is done with.
			line.qty = line.item.bought and w.qty or line.qty + w.qty
			line.item.text = ("%d x #[%s]"):format(line.qty, w.name)
			line.item.done, line.item.bought = nil, nil
		else
			local item = { text = ("%d x #[%s]"):format(w.qty, w.name) }
			note.items[#note.items + 1] = item
			byName[w.name] = { item = item, qty = w.qty }
		end
	end

	note.pinned = true
	RefreshShoppingNote(note, priceOf)
	OpenNote(note.id)
	if listFrame:IsShown() then RefreshList() end
	return note.id
end

function M.ResetPosition()
	db.listPoint = nil
	listFrame:ClearAllPoints()
	listFrame:SetPoint("CENTER")
	local n = 0
	for _, note in pairs(db.list) do
		note.point = nil
		local f = frames[note.id]
		if f then
			f:ClearAllPoints()
			f:SetPoint("CENTER", UIParent, "CENTER", -150 + n * 24, 80 - n * 24)
			n = (n + 1) % 8
		end
	end
end

M.launcher = {
	{ icon = "Interface\\Icons\\INV_Misc_Note_01", label = "Notes",
		hint = "Click: your notes. Right-click: new note. Shift-right-click: new checklist.",
		func = function() M.ToggleList() end,
		rightClick = function() if IsShiftKeyDown() then M.New(nil, "list") else M.New() end end,
		count = function() return #SortedNotes() end },
}

function M.MinimapTooltip()
	local n = #SortedNotes()
	if n > 0 then GameTooltip:AddLine(("Notes: %d"):format(n), 1, 1, 1) end
end

local function OnSlash(msg)
	local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
	cmd = cmd:lower()
	if cmd == "" then
		M.ToggleList()
	elseif cmd == "new" then
		M.New(rest)
	elseif cmd == "newlist" or cmd == "checklist" then
		M.New(rest, "list")
	elseif cmd == "where" then
		local zone, sub, mapID = CurrentPlace()
		M.Say(("zone: %s, subzone: %s, map ID: %s%s"):format(zone or "-", sub or "-", tostring(mapID or "-"),
			InCapital(zone, mapID) and " (capital city)" or ""))
	elseif cmd == "test" then
		local n = CheckAreas(true)
		M.Say(n > 0 and ("opened %d note(s) that have an area."):format(n) or "no closed notes with an area to open. Add one with Areas on a note.")
	elseif cmd == "opacity" then
		local n = tonumber(rest)
		if n then
			M.SetOpacity(n)
			M.Say(("notes at %d%% opacity."):format(db.opacity))
		else
			M.Say(("usage: /notes opacity 10-100, now %d%%."):format(db.opacity))
		end
	elseif cmd == "reset" then
		M.ResetPosition()
		M.Say("windows moved back to the middle of the screen.")
	elseif cmd == "options" then
		ns.OpenSettings(M)
	else
		M.Say("/notes - list, /notes new [text], /notes newlist [milk, eggs], /notes where, /notes test, /notes opacity N, /notes reset, /notes options")
	end
end

M.options = {
	{ type = "checkbox", key = "chatTags", label = "Quest and item tags in chat",
		tooltip = "In the chat box, @ and # followed by two letters list quests and items. Tab or Enter puts in a link." },
	{ type = "button", label = "Your notes", button = "Open list", tooltip = "The list of notes (/notes).", func = function() M.ToggleList() end },
	{ type = "slider", key = "opacity", label = "Note opacity", min = 10, max = 100, step = 5,
		format = function(v) return ("%d%%"):format(v) end,
		tooltip = "How see-through the paper of every note is. The writing stays fully readable.",
		onChange = function(v) M.SetOpacity(v) end },
	{ type = "checkbox", key = "charOnly", label = "New notes: this character only",
		tooltip = "New notes are only seen by the character that wrote them. Untick to share new notes with all your characters. Each note can still be changed under Areas." },
	{ type = "checkbox", key = "popup", label = "Open notes in their areas",
		tooltip = "Notes with a zone or capital city open by themselves when you arrive there." },
	{ type = "checkbox", key = "sound", label = "Sound when a note opens",
		tooltip = "Plays a page-turn sound when a note opens because you entered its area." },
}

--------------------------------------------------------------------------------
-- Start-up
--------------------------------------------------------------------------------

function M:Enable()
	db = self.db
	if type(rawget(db, "list")) ~= "table" then db.list = {} end
	if type(rawget(db, "nextID")) ~= "number" then db.nextID = 1 end
	for id, note in pairs(db.list) do
		if type(note) ~= "table" then
			db.list[id] = nil
		else
			note.id = id
			note.title = note.title or ""
			note.text = note.text or ""
			note.zones = type(note.zones) == "table" and note.zones or {}
			if note.kind == "list" and type(note.items) ~= "table" then note.items = {} end
			if id >= db.nextID then db.nextID = id + 1 end
		end
	end
	BuildList()

	-- Tags: links held back by combat, item data arriving, new prices.
	local redraw
	local function QueueRedraw()
		if redraw then return end
		redraw = true
		C_Timer.After(0.2, function()
			redraw = nil
			RefreshAllViews()
		end)
	end
	local tagEvents = CreateFrame("Frame")
	tagEvents:RegisterEvent("PLAYER_REGEN_ENABLED")
	tagEvents:RegisterEvent("PLAYER_REGEN_DISABLED")
	tagEvents:RegisterEvent("GET_ITEM_INFO_RECEIVED")
	tagEvents:SetScript("OnEvent", function(_, event)
		if event == "PLAYER_REGEN_DISABLED" then
			Tag.Hide()           -- it can't pass keys on once combat has started
		elseif event == "PLAYER_REGEN_ENABLED" then
			if next(pendingLinks) then
				for view in pairs(pendingLinks) do EnableLinks(view) end
				pendingLinks = {}
				QueueRedraw()
			end
		elseif waitingForItems then
			waitingForItems = nil
			QueueRedraw()
		end
	end)
	local auctionator = _G.Auctionator and _G.Auctionator.API and _G.Auctionator.API.v1
	if auctionator and auctionator.RegisterForDBUpdate then
		ns.Try(auctionator.RegisterForDBUpdate, "PredUI", QueueRedraw)
	end

	local events = CreateFrame("Frame")
	events:RegisterEvent("PLAYER_ENTERING_WORLD")
	events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	events:RegisterEvent("ZONE_CHANGED")
	events:RegisterEvent("ZONE_CHANGED_INDOORS")
	local shownPinned = false
	events:SetScript("OnEvent", function(_, event)
		if event == "PLAYER_ENTERING_WORLD" and not shownPinned then
			shownPinned = true
			HookChatBoxes()
			for id, note in pairs(db.list) do
				if note.pinned and Visible(note) then OpenNote(id) end
			end
		end
		-- Zone names can lag a moment behind the event.
		C_Timer.After(0.5, function() CheckAreas(false) end)
	end)
end

SLASH_PREDUINOTES1, SLASH_PREDUINOTES2 = "/notes", "/note"
SlashCmdList.PREDUINOTES = ns.SlashHandler(M, OnSlash)
