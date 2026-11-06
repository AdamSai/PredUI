--------------------------------------------------------------------------------
-- Bank Alt: marks the items in your bags worth sending to a bank alt.
--
--   * Bind on Equip items that aren't soulbound yet get a coloured glow.
--   * Valuable items (not soulbound, and their Auctionator price is at least
--     the set percentage above the vendor price) get a gold coin on the icon,
--     a gold glow, or both. It compares one item's prices, so it works the same
--     for copper herbs and gold-priced gear. Items with an AH price but no
--     vendor price count as valuable; items with no AH price never do, and
--     grey items never have one (ns.AuctionPrice skips them). The
--     coin is coloured by how far above vendor it is (see TIERS).
--   * Ctrl+Alt+right-click an item in your bags to ignore it (no marks at all,
--     left out of /bankalt list); db.ignored holds the item IDs.
--   * Soulbound items get a small padlock (same corner as the coin, since an
--     item is never both).
--   * Item tooltips get an "AH vs vendor" line under Auctionator's prices.
--   * Items cheaper on the AH than "Min AH price" (10c by default, per item)
--     get neither the coin nor the tooltip line.
--   * Bind type comes from the item info (bindType 2 = on equip) and "is it
--     soulbound" from the bag slot, so no tooltip scanning is needed.
--   * Baganator: its item buttons are hooked on SetItemDetails (found through
--     its skin listener), which covers bags, bank and other characters' views.
--     The coin is a Baganator corner widget ("PredUI: valuable"), so it can be
--     moved to any corner in Baganator's settings and doesn't fight its other
--     corner icons.
--   * Default bags and bank: re-applied from the same redraw hooks Bag Value
--     uses, debounced.
--   * Auctionator: prices are re-read whenever it finishes a scan.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.Style

local M = ns.NewModule("bankalt", {
	title = "Bank Alt",
	notes = "Glows Bind on Equip items that aren't soulbound and marks valuable ones (Auctionator price), so you know what to send to your bank alt. Type /bankalt.",
	defaults = {
		boe = true,              -- glow on unbound BoE items
		bou = false,             -- also unbound Bind on Use items
		boeColor = "teal",
		valuable = true,         -- mark valuable items
		valueStyle = "icon",     -- "icon", "bottom", "iconbottom", "glow" or "both" (icon + glow)
		trash = true,            -- trash can when the AH price is barely above vendor
		trashPercent = 20,       -- AH price less than this % above vendor -> trash can
		minPercent = 50,         -- AH price at least this % above vendor price (100 = double)
		minPrice = 10,           -- copper: below this AH price (one item) no coin and no tooltip line
		tierColors = true,       -- colour the coin by how far the AH price is above vendor
		lockBound = true,        -- padlock on soulbound items
		questMark = true,        -- scroll on items your current quests need
		tooltipPercent = true,   -- "AH vs vendor" line under Auctionator's prices
	},
})

local CALLER_ID = "PredUI"
local BIND_ON_EQUIP, BIND_ON_USE = 2, 3     -- Enum.ItemBind
local COIN_SIZE = 14
local LOCK_SIZE = 18
local LOCK_COLOR = { 0.35, 1.00, 0.35 }
local QUEST_SIZE = 18
local QUEST_COLOR = { 1.00, 0.82, 0.20 }
local TRASH_SIZE = 17
local TRASH_COLOR = { 1.00, 0.45, 0.40 }
local BOTTOM_ALPHA = 0.85      -- strength of the bottom gradient at the icon's edge
local QUEST_ITEM_CLASS = Enum.ItemClass and Enum.ItemClass.Questitem or 12
local MAX_SLIDER_PERCENT = 1000
-- Steps for the "Min AH price" slider, in copper (a plain copper slider would
-- be useless from 1c to 100g).
local PRICE_STEPS = { 0, 1, 5, 10, 25, 50, 100, 500, 1000, 5000, 10000, 50000, 100000, 500000, 1000000 }

local function MinPrice()
	return tonumber(M.db and M.db.minPrice) or 0
end

-- "1g 50s 3c", without icons, for chat and the settings slider.
local function ShortMoney(copper)
	copper = math.floor(copper)
	if copper == 0 then return "0c" end
	local parts = {}
	local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
	if g > 0 then parts[#parts + 1] = g .. "g" end
	if s > 0 then parts[#parts + 1] = s .. "s" end
	if c > 0 then parts[#parts + 1] = c .. "c" end
	return table.concat(parts, " ")
end

-- "10c", "1g50s", "2s 5c" or a bare number of copper -> copper, or nil.
local function ParseMoney(text)
	text = (text or ""):lower():gsub("%s+", "")
	if text == "" then return end
	if text:match("^%d+$") then return tonumber(text) end
	local total, rest = 0, text
	for amount, unit in text:gmatch("(%d+)([gsc])") do
		total = total + tonumber(amount) * (unit == "g" and 10000 or unit == "s" and 100 or 1)
	end
	rest = rest:gsub("%d+[gsc]", "")
	if rest ~= "" then return end
	return total
end

local COLORS = {
	teal   = { "Teal",   0.20, 0.90, 1.00 },
	green  = { "Green",  0.25, 1.00, 0.30 },
	purple = { "Purple", 0.75, 0.40, 1.00 },
	pink   = { "Pink",   1.00, 0.35, 0.75 },
	white  = { "White",  1.00, 1.00, 1.00 },
}
local COLOR_ORDER = { "teal", "green", "purple", "pink", "white" }
local GOLD_GLOW = { 1.00, 0.80, 0.10 }

-- Coin colour by how far the AH price is above the vendor price, like item
-- quality: green, blue, purple, orange. Items that can't be vendored keep the
-- plain gold coin.
local TIERS = {
	{ min = 1000, name = "orange", r = 1.00, g = 0.55, b = 0.10 },
	{ min = 300,  name = "purple", r = 0.80, g = 0.45, b = 1.00 },
	{ min = 100,  name = "blue",   r = 0.35, g = 0.65, b = 1.00 },
	{ min = 0,    name = "green",  r = 0.35, g = 1.00, b = 0.35 },
}
local TIER_LEGEND = "green under +100%, blue +100%, purple +300%, orange +1000%, plain gold = can't be vendored"

local function Tier(percent)
	if not percent then return end
	for _, tier in ipairs(TIERS) do
		if percent >= tier.min then return tier end
	end
end

local db
local testMode = false
local baganatorButtons = setmetatable({}, { __mode = "k" })   -- [button] = its last item details

--------------------------------------------------------------------------------
-- Classifying an item
--------------------------------------------------------------------------------

-- Auctionator's price for one item, or nil (no Auctionator, no data).
local AuctionPrice = ns.AuctionPrice

-- Returns isBoE, isValuable, stackValue (copper, AH price x count) and the AH
-- price's % over the vendor price (nil when there's no vendor price).
-- Returns nil when the item info isn't cached yet (the caller retries later).
local function Classify(link, isBound, count, hasNoValue)
	if not ns.PublicString(link) then return false, false end
	if testMode then return true, true, 123456, 250 end
	if isBound then return false, false end

	local _, _, _, _, _, _, _, _, _, _, sellPrice, _, _, bindType = C_Item.GetItemInfo(link)
	bindType = ns.PublicNumber(bindType)
	if not bindType then return nil end

	local boe = bindType == BIND_ON_EQUIP or (db.bou and bindType == BIND_ON_USE)

	local ah = AuctionPrice(link)
	if not ah or ah <= 0 or ah < MinPrice() then return boe, false end

	local vendor = not hasNoValue and ns.PublicNumber(sellPrice) or 0
	local percent, valuable
	if vendor > 0 then
		percent = (ah - vendor) / vendor * 100
		valuable = percent >= (tonumber(db.minPercent) or 0)
	else
		valuable = true            -- sells on the AH, can't be vendored
	end
	return boe, valuable, ah * (ns.PublicNumber(count) or 1), percent
end

--------------------------------------------------------------------------------
-- Items your current quests need
--------------------------------------------------------------------------------

-- Quest objectives only give text ("Linen Cloth: 3/10"), not item IDs, so
-- "collect" objectives are matched by item name. Finished ones count too: you
-- still need the items to hand the quest in. Quest-class items count as well,
-- except ones that start a quest you don't have yet.
local questNames = {}          -- [lowercase item name] = true
local questSignature = ""

local function ObjectiveItemName(text)
	text = ns.PublicString(text)
	if not text then return end
	text = text:gsub("%d+%s*/%s*%d+", ""):gsub("%(.-%)", "")
	text = text:gsub("^[%s:%-]+", ""):gsub("[%s:%-]+$", "")
	return text ~= "" and text:lower() or nil
end

-- Returns true when the quest list changed.
local function ScanQuestLog()
	local log = C_QuestLog
	if not (log and log.GetNumQuestLogEntries and log.GetInfo and log.GetQuestObjectives) then return false end
	local names, list = {}, {}
	for i = 1, (ns.Try(log.GetNumQuestLogEntries)) or 0 do
		local info = ns.Try(log.GetInfo, i)
		local questID = info and not info.isHeader and ns.PublicNumber(info.questID)
		if questID then
			for _, objective in ipairs(ns.Try(log.GetQuestObjectives, questID) or {}) do
				if objective.type == "item" then
					local name = ObjectiveItemName(objective.text)
					if name and not names[name] then
						names[name] = true
						list[#list + 1] = name
					end
				end
			end
		end
	end
	table.sort(list)
	local signature = table.concat(list, "\n")
	questNames = names
	if signature == questSignature then return false end
	questSignature = signature
	return true
end

-- bag/slot are optional (not known for Baganator's other-character views).
local function IsQuestNeeded(link, bag, slot)
	if not (db.questMark and ns.PublicString(link)) then return false end
	if testMode then return true end
	local name, _, _, _, _, _, _, _, _, _, _, classID = C_Item.GetItemInfo(link)
	name = ns.PublicString(name)
	if name and questNames[name:lower()] then return true end
	if classID ~= QUEST_ITEM_CLASS then return false end
	if bag and slot then
		local info = ns.Try(C_Container.GetContainerItemQuestInfo, bag, slot)
		-- Starts a quest you haven't taken: not needed for a current one.
		if info and info.questID and not info.isActive then return false end
	end
	return true
end

-- What to draw: glow colour (or nil) and whether to show the coin.
-- What to draw for an item:
--   glow    colour of the full glow, or nil
--   coin    show the coin
--   bottom  colour of the bottom gradient, or nil
--   trash   show the trash can (AH price barely above vendor: just vendor it)
local function Look(boe, valuable, percent)
	local style = db.valueStyle
	local marked = db.valuable and valuable
	local coin = marked and (style == "icon" or style == "both" or style == "iconbottom") or false
	local bottom
	if marked and (style == "bottom" or style == "iconbottom") then
		local tier = db.tierColors and Tier(percent)
		bottom = tier and { tier.r, tier.g, tier.b } or GOLD_GLOW
	end
	local trash = db.trash and not valuable and percent ~= nil and not testMode
		and percent < (tonumber(db.trashPercent) or 0) or false
	local glow
	if marked and (style == "glow" or style == "both") then
		glow = GOLD_GLOW
	elseif db.boe and boe then
		local c = COLORS[db.boeColor] or COLORS.teal
		glow = { c[2], c[3], c[4] }
	end
	return glow, coin, bottom, trash
end

--------------------------------------------------------------------------------
-- Overlays on item buttons
--------------------------------------------------------------------------------

local function SetCoinTexture(tex)
	if not tex:SetAtlas("coin-gold") then
		tex:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
	end
end

local function SetLockTexture(tex)
	-- Our own white padlock with a black outline (Media\Lock.tga), tinted
	-- green: Blizzard's padlock atlases are dark and vanish on item icons.
	tex:SetTexture(S.MEDIA .. "Lock")
	tex:SetVertexColor(LOCK_COLOR[1], LOCK_COLOR[2], LOCK_COLOR[3])
end

-- Our own white trash can with a black outline (Media\\Trash.tga), tinted red.
local function SetTrashTexture(tex)
	tex:SetDesaturated(false)
	tex:SetTexture(S.MEDIA .. "Trash")
	tex:SetVertexColor(TRASH_COLOR[1], TRASH_COLOR[2], TRASH_COLOR[3])
end

-- Our own quest scroll (Media\Quest.tga), tinted quest yellow. Not the
-- game's "!", which already means "this item starts a quest".
local function SetQuestTexture(tex)
	tex:SetTexture(S.MEDIA .. "Quest")
	tex:SetVertexColor(QUEST_COLOR[1], QUEST_COLOR[2], QUEST_COLOR[3])
end

-- Grey the coin and tint it with the tier colour, or leave it gold.
local function ColorCoin(tex, percent)
	local tier = db.tierColors and Tier(percent)
	if tier then
		tex:SetDesaturated(true)
		tex:SetVertexColor(tier.r, tier.g, tier.b)
	else
		tex:SetDesaturated(false)
		tex:SetVertexColor(1, 1, 1)
	end
end

local function GetOverlay(button)
	local overlay = button.PredUIBankAlt
	if overlay then return overlay end
	-- Own child frame so it draws above the icon, its border and the bag's
	-- own new-item glow.
	overlay = CreateFrame("Frame", nil, button)
	overlay:SetAllPoints()
	overlay:SetFrameLevel(button:GetFrameLevel() + 4)

	overlay.glow = overlay:CreateTexture(nil, "OVERLAY")
	local icon = button.icon or button.Icon or button
	overlay.glow:SetPoint("TOPLEFT", icon, "TOPLEFT", -2, 2)
	overlay.glow:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 2, -2)
	if not overlay.glow:SetAtlas("bags-glow-white") then
		overlay.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
		overlay.glow:ClearAllPoints()
		overlay.glow:SetPoint("CENTER", icon)
		overlay.glow:SetSize(icon:GetWidth() * 1.8, icon:GetHeight() * 1.8)
	end
	overlay.glow:SetBlendMode("ADD")
	overlay.glow:Hide()

	overlay.coin = overlay:CreateTexture(nil, "OVERLAY", nil, 2)
	overlay.coin:SetSize(COIN_SIZE, COIN_SIZE)
	overlay.coin:SetPoint("BOTTOMLEFT", 2, 2)
	SetCoinTexture(overlay.coin)
	overlay.coin:Hide()

	-- Same corner again: trash means "not valuable", so never with the coin.
	overlay.trash = overlay:CreateTexture(nil, "OVERLAY", nil, 2)
	overlay.trash:SetSize(TRASH_SIZE, TRASH_SIZE)
	overlay.trash:SetPoint("BOTTOMLEFT", 0, 0)
	SetTrashTexture(overlay.trash)
	overlay.trash:Hide()

	-- Coloured gradient over the lower half of the icon, fading out upwards.
	overlay.bottom = overlay:CreateTexture(nil, "OVERLAY", nil, -1)
	overlay.bottom:SetTexture("Interface\\Buttons\\WHITE8x8")
	overlay.bottom:SetPoint("TOPLEFT", icon, "LEFT", 0, 0)
	overlay.bottom:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 0, 0)
	overlay.bottom:Hide()

	-- Same corner as the coin: an item is either soulbound or can be valuable.
	overlay.lock = overlay:CreateTexture(nil, "OVERLAY", nil, 2)
	overlay.lock:SetSize(LOCK_SIZE, LOCK_SIZE)
	overlay.lock:SetPoint("BOTTOMLEFT", -1, 0)
	SetLockTexture(overlay.lock)
	overlay.lock:Hide()

	overlay.quest = overlay:CreateTexture(nil, "OVERLAY", nil, 3)
	overlay.quest:SetSize(QUEST_SIZE, QUEST_SIZE)
	overlay.quest:SetPoint("TOPRIGHT", 2, 1)
	SetQuestTexture(overlay.quest)
	overlay.quest:Hide()

	button.PredUIBankAlt = overlay
	return overlay
end

local function ClearButton(button)
	local overlay = button.PredUIBankAlt
	if overlay then
		overlay.glow:Hide()
		overlay.coin:Hide()
		overlay.trash:Hide()
		overlay.bottom:Hide()
		overlay.lock:Hide()
		overlay.quest:Hide()
	end
end

-- drawIcons: false on Baganator buttons, where the coin, lock and scroll are its
-- corner widgets.
local function Draw(button, boe, valuable, drawIcons, percent, bound, quest)
	local color, coin, bottom, trash = Look(boe, valuable, percent)
	local lock = drawIcons and bound and db.lockBound and not testMode
	quest = drawIcons and quest and db.questMark
	trash = drawIcons and trash
	if not color and not (coin and drawIcons) and not lock and not quest and not trash and not bottom then
		ClearButton(button)
		return
	end
	local drawCoin = drawIcons
	local overlay = GetOverlay(button)
	overlay.lock:SetShown(lock or false)
	overlay.quest:SetShown(quest or false)
	overlay.trash:SetShown(trash or false)
	if bottom then
		overlay.bottom:SetGradient("VERTICAL",
			CreateColor(bottom[1], bottom[2], bottom[3], BOTTOM_ALPHA),
			CreateColor(bottom[1], bottom[2], bottom[3], 0))
		overlay.bottom:Show()
	else
		overlay.bottom:Hide()
	end
	if color then
		overlay.glow:SetVertexColor(color[1], color[2], color[3], 1)
		overlay.glow:Show()
	else
		overlay.glow:Hide()
	end
	local showCoin = coin and drawCoin or false
	if showCoin then ColorCoin(overlay.coin, percent) end
	overlay.coin:SetShown(showCoin)
end

--------------------------------------------------------------------------------
-- Ignored items: no marks at all (a profession tool you'll never sell...)
--------------------------------------------------------------------------------

-- db.ignored = { [itemID] = true }, account-wide. Per item, not per slot.
local IGNORE_HINT = "Ctrl+Alt+right-click"
local OnIgnoreChanged          -- set further down, once the refresh exists

local function ItemID(link)
	return link and ns.PublicNumber((C_Item.GetItemInfoInstant(link)))
end

local function IsIgnored(link)
	local id = ItemID(link)
	return id ~= nil and db.ignored[id] == true
end

local function ToggleIgnore(link)
	local id = ItemID(link)
	if not id then return end
	if db.ignored[id] then
		db.ignored[id] = nil
		M.Say(link .. " is no longer ignored.")
	else
		db.ignored[id] = true
		M.Say("ignoring " .. link .. ". " .. IGNORE_HINT .. " it again to undo.")
	end
	if OnIgnoreChanged then OnIgnoreChanged() end
end

-- Ctrl+Alt+right-click toggles ignore. A modified click never uses or equips
-- the item (ContainerFrameItemButtonMixin:OnClick sends it to
-- OnModifiedClick), and dressing room is Ctrl+left only.
local function IsIgnoreClick(mouseButton)
	return mouseButton == "RightButton" and IsControlKeyDown() and IsAltKeyDown() and not IsShiftKeyDown()
end

-- getLink(button) returns the item link behind the button, or nil.
local function HookIgnoreClick(button, getLink)
	if button.PredUIBankAltClick then return end
	button.PredUIBankAltClick = true
	button:HookScript("OnClick", function(self, mouseButton)
		if M.enabled and IsIgnoreClick(mouseButton) then
			local link = getLink(self)
			if link then ToggleIgnore(link) end
		end
	end)
end

--------------------------------------------------------------------------------
-- Default bags and bank
--------------------------------------------------------------------------------

local function SlotLink(button)
	local bag, slot = button.PredUIBankAltBag, button.PredUIBankAltSlot
	return bag and slot and ns.PublicString(C_Container.GetContainerItemLink(bag, slot))
end

local function UpdateSlotButton(button, bag, slot)
	button.PredUIBankAltBag, button.PredUIBankAltSlot = bag, slot
	HookIgnoreClick(button, SlotLink)
	local info = C_Container.GetContainerItemInfo(bag, slot)
	if not (info and info.hyperlink) or IsIgnored(info.hyperlink) then
		ClearButton(button)
		return
	end
	local boe, valuable, _, percent = Classify(info.hyperlink, info.isBound, info.stackCount, info.hasNoValue)
	if boe == nil then
		-- Not cached yet: GET_ITEM_INFO_RECEIVED brings us back.
		ClearButton(button)
		if info.itemID then C_Item.RequestLoadItemDataByID(info.itemID) end
		return
	end
	Draw(button, boe, valuable, true, percent, info.isBound, IsQuestNeeded(info.hyperlink, bag, slot))
end

local function GetButtonBag(button)
	if button.GetBagID then return button:GetBagID() end
	return button:GetParent():GetID()
end

local function UpdateContainerFrame(frame)
	if not frame:IsShown() then return end
	if frame.EnumerateValidItems then
		for _, button in frame:EnumerateValidItems() do
			UpdateSlotButton(button, GetButtonBag(button), button:GetID())
		end
	else
		local name, bag = frame:GetName(), frame:GetID()
		for i = 1, frame.size or 0 do
			local button = _G[name .. "Item" .. i]
			if button then UpdateSlotButton(button, bag, button:GetID()) end
		end
	end
end

local function ForEachContainerFrame(fn)
	for i = 1, NUM_CONTAINER_FRAMES or 13 do
		local frame = _G["ContainerFrame" .. i]
		if frame then fn(frame) end
	end
	if ContainerFrameCombinedBags then fn(ContainerFrameCombinedBags) end
end

local function UpdateBank()
	local panel = BankPanel
	if not (panel and panel:IsShown() and panel.EnumerateValidItems) then return end
	for button in panel:EnumerateValidItems() do
		local bag, slot = button:GetBankTabID(), button:GetContainerSlotID()
		if bag and slot then UpdateSlotButton(button, bag, slot) end
	end
end

--------------------------------------------------------------------------------
-- Baganator
--------------------------------------------------------------------------------

local function UpdateBaganatorButton(button, details)
	baganatorButtons[button] = details or false
	local link = details and details.itemLink
	if not link or IsIgnored(link) then
		ClearButton(button)
		return
	end
	local boe, valuable, _, percent = Classify(link, details.isBound, details.itemCount, details.hasNoValue)
	if boe == nil then
		ClearButton(button)
		local item = Item:CreateFromItemLink(link)
		item:ContinueOnItemLoad(function()
			if baganatorButtons[button] == details then UpdateBaganatorButton(button, details) end
		end)
		return
	end
	-- Coin, trash can, lock and scroll are Baganator corner widgets; here only
	-- the glow and the bottom gradient.
	Draw(button, boe, valuable, false, percent)
end

local function HookBaganatorButton(button)
	if button.PredUIBankAltHooked or type(button.SetItemDetails) ~= "function" then return end
	button.PredUIBankAltHooked = true
	hooksecurefunc(button, "SetItemDetails", function(self, details)
		if M.enabled then UpdateBaganatorButton(self, details) end
	end)
	HookIgnoreClick(button, function(self)
		local details = baganatorButtons[self]
		return details and ns.PublicString(details.itemLink)
	end)
end

local function OnBaganatorFrame(details)
	if not (details and details.regionType == "ItemButton" and details.region) then return end
	if details.tags and tIndexOf(details.tags, "containerBag") then return end   -- bag slots
	HookBaganatorButton(details.region)
end

local function RefreshBaganator()
	for button, details in pairs(baganatorButtons) do
		if details and button:IsShown() then
			UpdateBaganatorButton(button, details)
		elseif not details then
			ClearButton(button)
		end
	end
	local api = Baganator and Baganator.API
	if api and api.RequestItemButtonsRefresh and Baganator.Constants then
		ns.Try(api.RequestItemButtonsRefresh, { Baganator.Constants.RefreshReason.ItemWidgets })
	end
end

local function SetupBaganator()
	local api = Baganator and Baganator.API
	if not api then return end

	if api.RegisterCornerWidget then
		-- One widget for the coin and the trash can: they never show together.
		ns.Try(api.RegisterCornerWidget, "PredUI: value (coin / trash)", "predui_valuable",
			function(frame, details)
				if not M.enabled or not details.itemLink or IsIgnored(details.itemLink) then return false end
				local boe, valuable, _, percent = Classify(details.itemLink, details.isBound, details.itemCount, details.hasNoValue)
				if boe == nil then return nil end        -- Baganator retries later
				local _, coin, _, trash = Look(boe, valuable, percent)
				if coin then
					frame.tex:SetSize(COIN_SIZE, COIN_SIZE)
					SetCoinTexture(frame.tex)
					ColorCoin(frame.tex, percent)
				elseif trash then
					frame.tex:SetSize(TRASH_SIZE, TRASH_SIZE)
					SetTrashTexture(frame.tex)
				end
				return (coin or trash) and true or false
			end,
			function(itemButton)
				local frame = CreateFrame("Frame", nil, itemButton)
				frame:SetSize(TRASH_SIZE, TRASH_SIZE)
				frame.tex = frame:CreateTexture(nil, "OVERLAY")
				frame.tex:SetPoint("BOTTOMLEFT")
				frame.tex:SetSize(COIN_SIZE, COIN_SIZE)
				SetCoinTexture(frame.tex)
				return frame
			end,
			{ corner = "bottom_left", priority = 1 })

		-- Last in the same corner: an item is either soulbound or can be
		-- valuable, and Baganator's equipment set icon still wins.
		ns.Try(api.RegisterCornerWidget, "PredUI: soulbound", "predui_soulbound",
			function(_, details)
				return M.enabled and db.lockBound and not testMode and details.itemLink ~= nil and details.isBound == true
					and not IsIgnored(details.itemLink)
			end,
			function(itemButton)
				local frame = CreateFrame("Frame", nil, itemButton)
				frame:SetSize(LOCK_SIZE, LOCK_SIZE)
				local tex = frame:CreateTexture(nil, "OVERLAY")
				tex:SetAllPoints()
				SetLockTexture(tex)
				return frame
			end,
			{ corner = "bottom_left", priority = 99 }, true)

		-- Scroll on items your current quests need. First in the top right corner.
		ns.Try(api.RegisterCornerWidget, "PredUI: quest item", "predui_quest",
			function(_, details)
				if not (M.enabled and details.itemLink) or IsIgnored(details.itemLink) then return false end
				if not C_Item.GetItemInfo(details.itemLink) then return nil end   -- retried later
				local loc = details.itemLocation
				return IsQuestNeeded(details.itemLink, loc and loc.bagID, loc and loc.slotIndex)
			end,
			function(itemButton)
				local frame = CreateFrame("Frame", nil, itemButton)
				frame:SetSize(QUEST_SIZE, QUEST_SIZE)
				frame.padding = 0
				local tex = frame:CreateTexture(nil, "OVERLAY")
				tex:SetAllPoints()
				SetQuestTexture(tex)
				return frame
			end,
			{ corner = "top_right", priority = 1 })
	end

	if api.Skins then
		if api.Skins.RegisterListener then api.Skins.RegisterListener(OnBaganatorFrame) end
		for _, details in ipairs(ns.Try(api.Skins.GetAllFrames) or {}) do
			OnBaganatorFrame(details)
		end
	end
end

--------------------------------------------------------------------------------
-- Tooltip: "AH vs vendor +X%" right under Auctionator's own price lines
--------------------------------------------------------------------------------

-- Auctionator adds its lines in ShowTipWithPricingDBKey (for bags, bank,
-- merchant, guild bank...), so hooking it puts ours right after them and only
-- where Auctionator shows prices.
local function SetupTooltip()
	local tip = Auctionator and Auctionator.Tooltip
	if not (tip and type(tip.ShowTipWithPricingDBKey) == "function") then return end
	hooksecurefunc(tip, "ShowTipWithPricingDBKey", function(tooltip, _, link)
		if not (M.enabled and db.tooltipPercent and tooltip and tooltip.AddDoubleLine and ns.PublicString(link)) then return end
		if IsIgnored(link) then
			tooltip:AddLine("Bank Alt: ignored (" .. IGNORE_HINT .. ")", 0.6, 0.6, 0.6)
			return
		end
		local ah = AuctionPrice(link)
		local sell = ns.PublicNumber(select(11, C_Item.GetItemInfo(link)))
		if not (ah and ah > 0 and ah >= MinPrice() and sell and sell > 0) then return end

		local percent = (ah - sell) / sell * 100
		local text, r, g, b
		if percent < 0 then
			text, r, g, b = ("%d%% (vendor it)"):format(percent), 1, 0.35, 0.35
		else
			text = ("+%d%%"):format(percent)
			local tier = percent >= (tonumber(db.minPercent) or 0) and Tier(percent)
			if tier then
				r, g, b = tier.r, tier.g, tier.b
			else
				r, g, b = 0.6, 0.6, 0.6       -- under your "valuable" threshold
			end
		end
		tooltip:AddDoubleLine("AH vs vendor", text, 1, 1, 1, r, g, b)
	end)
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

-- Default bags only: Baganator redraws its own buttons on bag changes, and our
-- hook follows it.
local function RefreshDefault()
	ForEachContainerFrame(UpdateContainerFrame)
	UpdateBank()
end

-- Everything, after a setting or the prices changed.
local function RefreshAll()
	RefreshDefault()
	RefreshBaganator()
end

local function Debounced(fn)
	local pending = false
	return function()
		if pending then return end
		pending = true
		C_Timer.After(0.1, function()
			pending = false
			fn()
		end)
	end
end

local QueueRefresh = Debounced(RefreshDefault)
local QueueRefreshAll = Debounced(RefreshAll)
OnIgnoreChanged = QueueRefreshAll

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local function Money(copper)
	return C_CurrencyInfo.GetCoinTextureString(math.floor(copper))
end

-- Prints what in your bags is worth sending, with the total.
local function ListItems()
	local found, total, waiting = 0, 0, 0
	for bag = 0, NUM_BAG_SLOTS do
		for slot = 1, C_Container.GetContainerNumSlots(bag) do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.hyperlink and not IsIgnored(info.hyperlink) then
				local boe, valuable, value, percent = Classify(info.hyperlink, info.isBound, info.stackCount, info.hasNoValue)
				if boe == nil then
					waiting = waiting + 1
				elseif (db.boe and boe) or (db.valuable and valuable) then
					found = found + 1
					total = total + (value or 0)
					local tags = {}
					if boe then tags[#tags + 1] = "BoE" end
					if valuable then
						local tier = Tier(percent)
						local color = tier and ("|cff%02x%02x%02x"):format(tier.r * 255, tier.g * 255, tier.b * 255) or S.GOLD
						tags[#tags + 1] = color .. (percent and ("+%d%% over vendor"):format(percent) or "AH only") .. "|r"
					end
					local count = (info.stackCount or 1) > 1 and (" x" .. info.stackCount) or ""
					print(("  %s%s - %s%s"):format(info.hyperlink, count, table.concat(tags, ", "),
						value and ("  " .. Money(value) .. " AH") or ""))
				end
			end
		end
	end
	if found == 0 then
		M.Say("nothing to send in your bags.")
	else
		M.Say(("%d to send, about %s at AH prices."):format(found, Money(total)))
	end
	if waiting > 0 then
		M.Say(waiting .. " items are still loading; try again in a moment.")
	end
end

-- For Mail Ledger's "Worth sending" list (MailSendList.lua): stack AH value
-- and % over vendor when an item can go to the bank alt (not bound, ignored or
-- needed for a quest, and has an AH price above Min AH price), else nil.
function M.SendCandidate(link, isBound, count, hasNoValue, bag, slot)
	if not db or IsIgnored(link) or IsQuestNeeded(link, bag, slot) then return nil end
	local boe, _, value, percent = Classify(link, isBound, count, hasNoValue)
	if boe == nil or not value or value <= 0 then return nil end
	return value, percent
end

local function ListIgnored()
	local ids = {}
	for id in pairs(db.ignored) do ids[#ids + 1] = id end
	if #ids == 0 then
		M.Say("no ignored items. " .. IGNORE_HINT .. " an item in your bags to ignore it.")
		return
	end
	table.sort(ids)
	M.Say(#ids .. " ignored (" .. IGNORE_HINT .. " one in your bags to undo, or /bankalt unignore all):")
	for _, id in ipairs(ids) do
		local link = select(2, C_Item.GetItemInfo(id))
		print("  " .. (ns.PublicString(link) or ("item " .. id)))
	end
end

local function OnSlash(msg)
	local cmd, arg = msg:lower():match("^%s*(%S*)%s*(.-)%s*$")
	if cmd == "list" then
		ListItems()
	elseif cmd == "ignored" then
		ListIgnored()
	elseif cmd == "unignore" then
		if arg == "all" then
			wipe(db.ignored)
			RefreshAll()
			M.Say("no items are ignored any more.")
		else
			M.Say("usage: /bankalt unignore all  (or " .. IGNORE_HINT .. " a single item in your bags)")
		end
	elseif cmd == "percent" then
		local n = tonumber((arg:gsub("%%", "")))
		if n and n >= 0 then
			db.minPercent = n
			RefreshAll()
			M.Say("valuable when the AH price is " .. n .. "% or more above the vendor price.")
		else
			M.Say("usage: /bankalt percent N, currently " .. tostring(db.minPercent) .. "%")
		end
	elseif cmd == "trash" then
		local n = tonumber((arg:gsub("%%", "")))
		if n then
			db.trashPercent = n
			RefreshAll()
			M.Say("trash can when the AH price is less than " .. n .. "% above the vendor price.")
		else
			M.Say("usage: /bankalt trash N, currently " .. tostring(db.trashPercent) .. "%")
		end
	elseif cmd == "minprice" then
		local copper = ParseMoney(arg)
		if copper then
			db.minPrice = copper
			RefreshAll()
			M.Say("no coin or tooltip line below an AH price of " .. ShortMoney(copper) .. ".")
		else
			M.Say("usage: /bankalt minprice 10c (or 5s, 1g50s), currently " .. ShortMoney(MinPrice()))
		end
	elseif cmd == "test" then
		testMode = not testMode
		RefreshAll()
		M.Say("test " .. (testMode and "on: every item is marked." or "off."))
	elseif cmd == "reset" then
		for key in pairs(M.defaults) do db[key] = nil end   -- back to the defaults
		testMode = false
		RefreshAll()
		M.Say("settings reset.")
	elseif cmd == "" or cmd == "options" then
		ns.OpenSettings(M)
	else
		M.Say("Commands:")
		print("  /bankalt - options")
		print("  /bankalt list - list what in your bags is worth sending")
		print("  " .. IGNORE_HINT .. " an item in your bags - ignore it (no marks), again to undo")
		print("  /bankalt ignored - list ignored items; /bankalt unignore all - clear them")
		print("  /bankalt percent N - valuable when the AH price is N% above vendor")
		print("  /bankalt trash N - trash can when the AH price is under N% above vendor")
		print("  /bankalt minprice 10c - ignore items cheaper than this on the AH")
		print("  /bankalt test - mark every item, to see the look")
		print("  Coin colours: " .. TIER_LEGEND)
		print("  /bankalt reset - default settings")
	end
end

local function Changed() RefreshAll() end

M.options = {
	{ type = "header", label = "Bind on Equip" },
	{ type = "checkbox", key = "boe", label = "Glow BoE items", tooltip = "A glow on Bind on Equip items that aren't soulbound yet.", onChange = Changed },
	{ type = "checkbox", key = "bou", label = "Also Bind on Use", tooltip = "Also glow Bind on Use items that aren't soulbound yet.", onChange = Changed },
	{ type = "dropdown", key = "boeColor", label = "Glow colour", tooltip = "Colour of the BoE glow.", onChange = Changed,
		values = function()
			local list = {}
			for _, key in ipairs(COLOR_ORDER) do list[#list + 1] = { key, COLORS[key][1] } end
			return list
		end },
	{ type = "header", label = "Valuable items" },
	{ type = "checkbox", key = "valuable", label = "Mark valuable items", tooltip = "Mark items that aren't soulbound and sell on the AH for clearly more than at a vendor.", onChange = Changed },
	{ type = "dropdown", key = "valueStyle", label = "Mark with", tooltip = "Coin icon in the corner, a coloured glow over the bottom of the icon (coloured by how far the AH price is above vendor), both, or a gold glow all round. In Baganator the coin is a corner widget you can move in its Icons settings.", onChange = Changed,
		values = function()
			return {
				{ "icon", "Coin icon" },
				{ "bottom", "Bottom glow" },
				{ "iconbottom", "Coin + bottom glow" },
				{ "glow", "Gold glow" },
				{ "both", "Coin + gold glow" },
			}
		end },
	{ type = "slider", key = "minPercent", label = "AH over vendor", min = 0, max = MAX_SLIDER_PERCENT, step = 10, tooltip = "How much more the Auctionator price must be than the vendor price. 100% = at least double. Items with an AH price but no vendor price always count. Any amount: /bankalt percent N.", onChange = Changed,
		format = function(v) return "+" .. math.floor(v + 0.5) .. "%" end },
	{ type = "slider", key = "minPrice", label = "Min AH price", min = 1, max = #PRICE_STEPS, step = 1,
		tooltip = "Items cheaper than this on the AH (for one item) get no coin and no \"AH vs vendor\" tooltip line. Any amount: /bankalt minprice 10c.",
		get = function()
			-- Nearest step at or below the saved amount.
			local value, index = MinPrice(), 1
			for i, step in ipairs(PRICE_STEPS) do
				if step <= value then index = i end
			end
			return index
		end,
		set = function(index)
			index = math.max(1, math.min(#PRICE_STEPS, math.floor(index + 0.5)))
			db.minPrice = PRICE_STEPS[index]
		end,
		default = 4,
		format = function(index)
			index = math.max(1, math.min(#PRICE_STEPS, math.floor(index + 0.5)))
			return ShortMoney(PRICE_STEPS[index])
		end,
		onChange = Changed },
	{ type = "checkbox", key = "tierColors", label = "Colour by profit", tooltip = "Colour the coin and the bottom glow by how far the AH price is above the vendor price: " .. TIER_LEGEND .. ".", onChange = Changed },
	{ type = "header", label = "Not worth the AH" },
	{ type = "checkbox", key = "trash", label = "Trash can icon", tooltip = "A red trash can on items whose AH price is barely above (or below) the vendor price: just sell them to a vendor. Uses the same corner as the coin; in Baganator they share the \"PredUI: value (coin / trash)\" corner icon.", onChange = Changed },
	{ type = "slider", key = "trashPercent", label = "Trash below", min = 0, max = 200, step = 5, tooltip = "Items whose AH price is less than this % above the vendor price get the trash can. Any amount: /bankalt trash N.", onChange = Changed,
		format = function(v) return "+" .. math.floor(v + 0.5) .. "%" end },
	{ type = "header", label = "Other" },
	{ type = "checkbox", key = "questMark", label = "Scroll on quest items", tooltip = "A yellow scroll on items your current quests need, including ones you've already collected enough of (you still need them to hand in). In Baganator it's the \"PredUI: quest item\" corner icon.", onChange = Changed },
	{ type = "checkbox", key = "lockBound", label = "Padlock on soulbound items", tooltip = "A small padlock on soulbound items, so you can see what can't go to an alt. In Baganator it's the \"PredUI: soulbound\" corner icon.", onChange = Changed },
	{ type = "checkbox", key = "tooltipPercent", label = "AH vs vendor in tooltips", tooltip = "Adds how much more (or less) the AH price is than the vendor price, under Auctionator's price lines.", },
	{ type = "button", label = "Items to send", button = "List", tooltip = "Lists what in your bags is worth sending to your bank alt. Also /bankalt list.", func = ListItems },
	{ type = "button", label = "Ignored items", button = "List", tooltip = IGNORE_HINT .. " an item in your bags to ignore it: no marks on it at all. Do it again to undo. This lists them; /bankalt unignore all clears the list.", func = ListIgnored },
}

--------------------------------------------------------------------------------
-- Start-up
--------------------------------------------------------------------------------

function M:Enable()
	db = self.db
	if type(db.ignored) ~= "table" then db.ignored = {} end

	ForEachContainerFrame(function(frame)
		frame:HookScript("OnShow", QueueRefresh)
		if frame.UpdateItems then hooksecurefunc(frame, "UpdateItems", QueueRefresh) end
	end)
	if BankFrame then BankFrame:HookScript("OnShow", QueueRefresh) end
	if BankPanel and BankPanel.GenerateItemSlotsForSelectedTab then
		hooksecurefunc(BankPanel, "GenerateItemSlotsForSelectedTab", QueueRefresh)
	end

	SetupBaganator()
	SetupTooltip()
	ScanQuestLog()

	-- The quest log changes often; re-read it shortly after, and redraw only
	-- when the list of needed items actually changed.
	local questEvents = CreateFrame("Frame")
	questEvents:RegisterEvent("QUEST_LOG_UPDATE")
	questEvents:RegisterEvent("PLAYER_ENTERING_WORLD")
	local questPending = false
	questEvents:SetScript("OnEvent", function()
		if questPending then return end
		questPending = true
		C_Timer.After(0.5, function()
			questPending = false
			if ScanQuestLog() then QueueRefreshAll() end
		end)
	end)

	local auctionator = Auctionator and Auctionator.API and Auctionator.API.v1
	if auctionator and auctionator.RegisterForDBUpdate then
		ns.Try(auctionator.RegisterForDBUpdate, CALLER_ID, QueueRefreshAll)
	end

	local events = CreateFrame("Frame")
	events:RegisterEvent("BAG_UPDATE_DELAYED")
	events:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
	events:RegisterEvent("BANKFRAME_OPENED")
	events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
	events:SetScript("OnEvent", QueueRefresh)
end

SLASH_PREDUIBANKALT1 = "/bankalt"
SlashCmdList.PREDUIBANKALT = ns.SlashHandler(M, OnSlash)
