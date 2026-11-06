--------------------------------------------------------------------------------
-- Loot Room: when your bags are full, lists your lowest-value bag items next
-- to the loot window so one can be deleted to make room, and compares the loot
-- against the cheapest of them.
--
--   * Only regular bags count (not profession bags), and quest items are never
--     offered: neither ones flagged as quest items nor ones a quest in the log
--     asks for.
--   * Loot that fits onto a partial stack already in the bags doesn't need a
--     free slot, so the window stays hidden for it.
--   * Deleting asks first, and re-checks that the slot still holds the same
--     item and count.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.Style

local M = ns.NewModule("loot", {
	title = "Loot Room",
	notes = "When your bags are full, shows your lowest-value items next to the loot window so you can free a slot.",
	defaults = { count = 5 },
})

local MIN_COUNT, MAX_COUNT = 1, 10
local BIND_QUEST = 4
local LOOT_SLOT_ITEM = (Enum.LootSlotType and Enum.LootSlotType.Item) or 1

local ROW_HEIGHT = 28
local ROW_SPACING = 3
local FRAME_WIDTH = 380
local TAG_WIDTH = 56

local db
local lootOpen, testMode = false, false
local frame
local bagRows, lootRows = {}, {}

local function GetCount()
	local n = tonumber(db.count) or M.defaults.count
	return math.max(MIN_COUNT, math.min(MAX_COUNT, math.floor(n)))
end

--------------------------------------------------------------------------------
-- Scanning
--------------------------------------------------------------------------------

-- Regular (non-profession) bags only: backpack + equipped bags.
local function ForEachRegularBag(fn)
	for bag = 0, NUM_BAG_SLOTS do
		local free, family = C_Container.GetContainerNumFreeSlots(bag)
		if free and family == 0 and C_Container.GetContainerNumSlots(bag) > 0 then
			fn(bag, free)
		end
	end
end

local function BagsFull()
	local totalFree = 0
	ForEachRegularBag(function(_, free) totalFree = totalFree + free end)
	return totalFree == 0
end

local function Trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Names of items required by objectives of quests currently in the log.
local function GetActiveQuestItemNames()
	local list = {}
	local numEntries = C_QuestLog.GetNumQuestLogEntries() or 0
	for i = 1, numEntries do
		local info = C_QuestLog.GetInfo(i)
		if info and not info.isHeader and info.questID then
			local objectives = C_QuestLog.GetQuestObjectives(info.questID)
			for _, obj in ipairs(objectives or {}) do
				if obj.type == "item" and obj.text then
					local text = obj.text
					local name = text:match("^(.-):%s*%d+%s*/%s*%d+") -- "Linen Cloth: 3/10"
						or text:match("^%d+%s*/%s*%d+%s+(.+)$")       -- "3/10 Linen Cloth"
						or text
					list[Trim(name)] = true
				end
			end
		end
	end
	return list
end

local function GetCandidates()
	local questNames = GetActiveQuestItemNames()
	local list = {}

	ForEachRegularBag(function(bag)
		for slot = 1, C_Container.GetContainerNumSlots(bag) do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID and not info.isLocked and not info.hasNoValue then
				local name, _, _, _, _, _, _, _, _, _, sellPrice, classID, _, bindType =
					C_Item.GetItemInfo(info.itemID)
				local questInfo = C_Container.GetContainerItemQuestInfo(bag, slot)
				local isQuest = (classID == Enum.ItemClass.Questitem)
					or (bindType == BIND_QUEST)
					or (questInfo and (questInfo.isQuestItem or questInfo.questID))
					or (name and questNames[name])

				if name and sellPrice and sellPrice > 0 and not isQuest then
					local count = info.stackCount or 1
					list[#list + 1] = {
						bag = bag,
						slot = slot,
						itemID = info.itemID,
						count = count,
						link = info.hyperlink,
						icon = info.iconFileID,
						value = sellPrice * count,
					}
				end
			end
		end
	end)

	table.sort(list, function(a, b)
		if a.value ~= b.value then return a.value < b.value end
		return a.itemID < b.itemID
	end)

	local limit = GetCount()
	for i = #list, limit + 1, -1 do
		list[i] = nil
	end
	return list
end

-- How many more of itemID fit onto partial stacks already in the bags.
local function GetStackRoom(itemID, maxStack)
	if not maxStack or maxStack <= 1 then return 0 end
	local room = 0
	ForEachRegularBag(function(bag)
		for slot = 1, C_Container.GetContainerNumSlots(bag) do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.itemID == itemID then
				room = room + math.max(0, maxStack - (info.stackCount or 1))
			end
		end
	end)
	return room
end

-- Verdicts for loot items, compared against the cheapest bag item.
local VERDICT = {
	better = "|cff20ff20Better|r",
	same   = "|cffaaaaaaSame|r",
	worse  = "|cffff4040Worse|r",
	stacks = "|cff20ff20Stacks|r",
	quest  = "|cffffd100Quest|r",
	novalue = "|cff888888No value|r",
	unknown = "|cff888888?|r",
}

-- Returns the loot item entries, and whether any of them needs a free bag
-- slot (i.e. can't be fully absorbed by partial stacks already in the bags).
local function GetLootEntries(cheapest)
	local list = {}
	local needsRoom = false
	if not lootOpen then return list, needsRoom end

	-- Stack room left per itemID, shared between loot slots of the same item.
	local roomLeft = {}

	for lootSlot = 1, GetNumLootItems() do
		if GetLootSlotType(lootSlot) == LOOT_SLOT_ITEM then
			local texture, _, quantity, _, _, _, isQuestItem = GetLootSlotInfo(lootSlot)
			local link = GetLootSlotLink(lootSlot)
			quantity = quantity or 1
			local entry = { lootSlot = lootSlot, icon = texture, link = link, count = quantity }

			local itemID = link and C_Item.GetItemInfoInstant(link)
			local name, sellPrice, classID, bindType, maxStack
			if itemID then
				local _
				name, _, _, _, _, _, _, maxStack, _, _, sellPrice, classID, _, bindType = C_Item.GetItemInfo(itemID)
			end

			local fits = false
			if itemID then
				roomLeft[itemID] = roomLeft[itemID] or GetStackRoom(itemID, maxStack)
				if roomLeft[itemID] >= quantity then
					fits = true
					roomLeft[itemID] = roomLeft[itemID] - quantity
				end
			end
			if not fits then
				needsRoom = true
			end

			if fits then
				entry.verdict = VERDICT.stacks
			elseif isQuestItem or classID == Enum.ItemClass.Questitem or bindType == BIND_QUEST then
				entry.verdict = VERDICT.quest
			elseif not name then
				entry.verdict = VERDICT.unknown -- item data not cached yet
			elseif not sellPrice or sellPrice == 0 then
				entry.verdict = VERDICT.novalue
			end

			if sellPrice and sellPrice > 0 then
				entry.value = sellPrice * quantity
				if not entry.verdict then
					if not cheapest then
						entry.verdict = "" -- nothing in the bags to compare against
					elseif entry.value > cheapest then
						entry.verdict = VERDICT.better
					elseif entry.value == cheapest then
						entry.verdict = VERDICT.same
					else
						entry.verdict = VERDICT.worse
					end
				end
			end

			list[#list + 1] = entry
		end
	end
	return list, needsRoom
end

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------

local function BagRow_OnEnter(self)
	if not self.entry then return end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetBagItem(self.entry.bag, self.entry.slot)
	GameTooltip:Show()
end

local function LootRow_OnEnter(self)
	if not self.entry then return end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetLootItem(self.entry.lootSlot)
	GameTooltip:Show()
end

local function BagRow_OnClick(self)
	local entry = self.entry
	if not entry then return end
	if InCombatLockdown() then
		M.Say("can't delete items in combat.")
		return
	end
	local label = entry.link or ("item:" .. entry.itemID)
	if entry.count > 1 then
		label = label .. " x" .. entry.count
	end
	StaticPopup_Show("PREDUI_LOOTROOM_DELETE", label, nil, {
		bag = entry.bag, slot = entry.slot, itemID = entry.itemID, count = entry.count,
	})
end

local function CreateRow(isLoot)
	local row = CreateFrame("Button", nil, frame)
	row:SetSize(FRAME_WIDTH - S.PAD * 2, ROW_HEIGHT)
	S.RowHighlight(row)

	local iconEdge = S.Texture(row, "BACKGROUND", 0)
	iconEdge:SetVertexColor(0, 0, 0, 1)
	iconEdge:SetSize(ROW_HEIGHT, ROW_HEIGHT)
	iconEdge:SetPoint("LEFT")
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetPoint("TOPLEFT", iconEdge, 1, -1)
	row.icon:SetPoint("BOTTOMRIGHT", iconEdge, -1, 1)
	row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	row.count = row:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	row.count:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", 1, 0)

	-- Verdict column; kept on bag rows too so the value columns line up.
	row.tag = S.Text(row, 11)
	row.tag:SetPoint("RIGHT", -4, 0)
	row.tag:SetWidth(TAG_WIDTH)
	row.tag:SetJustifyH("RIGHT")

	row.value = S.Text(row, 12)
	row.value:SetPoint("RIGHT", row.tag, "LEFT", -6, 0)
	row.value:SetJustifyH("RIGHT")

	row.name = S.Text(row, 12)
	row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
	row.name:SetPoint("RIGHT", row.value, "LEFT", -8, 0)
	row.name:SetJustifyH("LEFT")

	row:SetScript("OnLeave", GameTooltip_Hide)
	if isLoot then
		row:SetScript("OnEnter", LootRow_OnEnter)
	else
		row:SetScript("OnEnter", BagRow_OnEnter)
		row:SetScript("OnClick", BagRow_OnClick)
	end
	return row
end

local function FillRows(pool, list, isLoot, y)
	for i, entry in ipairs(list) do
		local row = pool[i]
		if not row then
			row = CreateRow(isLoot)
			pool[i] = row
		end
		row.entry = entry
		row.icon:SetTexture(entry.icon)
		row.count:SetText(entry.count > 1 and entry.count or "")
		row.name:SetText(entry.link or "")
		row.value:SetText(entry.value and C_CurrencyInfo.GetCoinTextureString(entry.value) or "")
		row.tag:SetText(entry.verdict or "")
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", S.PAD, y)
		row:Show()
		y = y - ROW_HEIGHT - ROW_SPACING
	end
	for i = #list + 1, #pool do
		pool[i].entry = nil
		pool[i]:Hide()
	end
	return y
end

local function Anchor()
	frame:ClearAllPoints()
	if LootFrame and LootFrame:IsShown() then
		frame:SetPoint("TOPLEFT", LootFrame, "TOPRIGHT", 8, 0)
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 200, 100)
	end
end

local function BuildWindow()
	frame = S.Window({ name = "PredUILootRoom", title = "Bags full - lowest value items", width = FRAME_WIDTH, height = 80, movable = false })
	frame.close:SetScript("OnClick", function()
		testMode = false
		frame:Hide()
	end)

	frame.empty = S.Text(frame, 12)
	frame.empty:SetTextColor(0.5, 0.5, 0.5)
	frame.empty:SetText("No sellable candidates")

	frame.lootHeader = S.Heading(frame, "In this loot", 0)
	frame.click = S.Text(frame, 10)
	frame.click:SetTextColor(0.6, 0.6, 0.6)
	frame.click:SetText("Click an item to delete it")
end

local function Refresh()
	if not (lootOpen or testMode) or (not testMode and not BagsFull()) then
		frame:Hide()
		return
	end

	local bagList = GetCandidates()
	local cheapest = bagList[1] and bagList[1].value
	local lootList, needsRoom = GetLootEntries(cheapest)

	-- Full bags only matter if some loot can't go onto an existing stack.
	if not testMode and not needsRoom then
		frame:Hide()
		return
	end

	local y = -S.TITLE_H - 8
	if #bagList == 0 then
		frame.empty:ClearAllPoints()
		frame.empty:SetPoint("TOPLEFT", S.PAD, y - 6)
		frame.empty:Show()
		frame.click:Hide()
		y = y - ROW_HEIGHT
	else
		frame.empty:Hide()
		frame.click:ClearAllPoints()
		frame.click:SetPoint("TOPRIGHT", -S.PAD, y)
		frame.click:Show()
		y = y - 14
	end
	y = FillRows(bagRows, bagList, false, y)

	if #lootList > 0 then
		y = y - 8
		frame.lootHeader:SetY(y)
		frame.lootHeader:Show()
		y = y - 20
	else
		frame.lootHeader:Hide()
	end
	y = FillRows(lootRows, lootList, true, y)

	frame:SetHeight(-y + 8)
	Anchor()
	frame:Show()
end

-- Debounce bursts of bag/item events into one refresh.
local refreshPending = false
local function QueueRefresh()
	if refreshPending then return end
	refreshPending = true
	C_Timer.After(0.1, function()
		refreshPending = false
		Refresh()
	end)
end

local function HideWindow()
	StaticPopup_Hide("PREDUI_LOOTROOM_DELETE")
	frame:Hide()
end

--------------------------------------------------------------------------------
-- Delete confirmation
--------------------------------------------------------------------------------

local function DeleteEntry(data)
	if not data then return end
	if InCombatLockdown() then
		M.Say("can't delete items in combat.")
		return
	end
	local info = C_Container.GetContainerItemInfo(data.bag, data.slot)
	if not info or info.itemID ~= data.itemID or info.stackCount ~= data.count or info.isLocked then
		M.Say("that bag slot changed, item not deleted.")
		QueueRefresh()
		return
	end
	ClearCursor()
	C_Container.PickupContainerItem(data.bag, data.slot)
	if CursorHasItem() then
		DeleteCursorItem()
	end
	QueueRefresh()
end

StaticPopupDialogs.PREDUI_LOOTROOM_DELETE = {
	text = "Delete %s?",
	button1 = DELETE or "Delete",
	button2 = CANCEL or "Cancel",
	OnAccept = function(self, data)
		DeleteEntry(data or self.data)
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	showAlert = true,
	preferredIndex = 3,
}

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

function M.Test()
	testMode = true
	Refresh()
end

local function SetCount(n)
	n = tonumber(n)
	if not n then return false end
	db.count = math.max(MIN_COUNT, math.min(MAX_COUNT, math.floor(n)))
	if frame:IsShown() then Refresh() end
	return true
end

local function OnSlash(msg)
	local cmd, arg = msg:lower():match("^%s*(%S*)%s*(.-)%s*$")
	if cmd == "count" then
		if SetCount(arg) then
			M.Say("showing " .. GetCount() .. " item(s).")
		else
			M.Say("usage: /lootroom count N  (" .. MIN_COUNT .. "-" .. MAX_COUNT .. "), currently " .. GetCount())
		end
	elseif cmd == "test" then
		M.Test()
	elseif cmd == "" or cmd == "options" then
		ns.OpenSettings(M)
	else
		M.Say("/lootroom - options, /lootroom count N, /lootroom test")
	end
end

M.options = {
	{ type = "slider", key = "count", label = "Items shown", min = MIN_COUNT, max = MAX_COUNT, step = 1,
		tooltip = "How many of your lowest-value bag items to list when your bags are full.",
		onChange = function() if frame:IsShown() then Refresh() end end },
	{ type = "button", label = "Preview", button = "Show window", tooltip = "Show the window now, even with free bag space.", func = function() M.Test() end },
}

--------------------------------------------------------------------------------
-- Start-up
--------------------------------------------------------------------------------

function M:Enable()
	db = self.db
	BuildWindow()

	local events = CreateFrame("Frame")
	events:RegisterEvent("LOOT_OPENED")
	events:RegisterEvent("LOOT_CLOSED")
	events:RegisterEvent("LOOT_SLOT_CLEARED")
	events:RegisterEvent("BAG_UPDATE_DELAYED")
	events:RegisterEvent("QUEST_LOG_UPDATE")
	events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
	events:SetScript("OnEvent", function(_, event)
		if event == "LOOT_OPENED" then
			lootOpen = true
			QueueRefresh()
		elseif event == "LOOT_CLOSED" then
			lootOpen = false
			if not testMode then HideWindow() end
		elseif lootOpen or testMode then
			QueueRefresh()
		end
	end)
end

SLASH_PREDUILOOT1 = "/lootroom"
SlashCmdList.PREDUILOOT = ns.SlashHandler(M, OnSlash)
