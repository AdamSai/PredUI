--------------------------------------------------------------------------------
-- Bag Value: the vendor sell value of each item, on its icon in the default
-- bag and bank frames, plus the total for your bags under the backpack.
--
--   * The bag frames redraw on open and whenever their contents change, so the
--     overlays are re-applied from hooks on those redraws, debounced.
--   * Item prices come from the item cache; GET_ITEM_INFO_RECEIVED refreshes
--     items that weren't cached yet.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.Style

local M = ns.NewModule("bag", {
	title = "Bag Value",
	notes = "Shows the vendor sell value of each item right on its icon in your bags and bank.",
	defaults = {
		enabled = true,
		stackTotal = true,   -- price x stack count, instead of the unit price
		merchantOnly = false, -- only show values while a vendor window is open
		showTotal = true,    -- total value of all bags at the bottom of the backpack
		fontSize = 14,
	},
})

local MIN_FONT_SIZE, MAX_FONT_SIZE = 6, 20

local GOLD_COLOR   = "|cffffd100"
local SILVER_COLOR = "|cffc7c7cf"
local COPPER_COLOR = "|cffeda55f"

local db
local merchantOpen = false

local function FontSize()
	local n = tonumber(db.fontSize) or M.defaults.fontSize
	return math.max(MIN_FONT_SIZE, math.min(MAX_FONT_SIZE, math.floor(n)))
end

-- Short label that fits on an icon: highest coin denomination only,
-- with one decimal for small gold amounts ("1.5g", "12g", "35s", "8c").
local function FormatValue(copper)
	if copper >= 10000 then
		local gold = copper / 10000
		if gold < 10 then
			local text = string.format("%.1f", math.floor(gold * 10) / 10):gsub("%.0$", "")
			return GOLD_COLOR .. text .. "g|r"
		end
		return GOLD_COLOR .. math.floor(gold) .. "g|r"
	elseif copper >= 100 then
		return SILVER_COLOR .. math.floor(copper / 100) .. "s|r"
	end
	return COPPER_COLOR .. copper .. "c|r"
end

--------------------------------------------------------------------------------
-- Button overlays
--------------------------------------------------------------------------------

local function GetOverlay(button)
	local overlay = button.PredUIBagValue
	if not overlay then
		-- Child frame so the text draws above the icon border and other overlays.
		overlay = CreateFrame("Frame", nil, button)
		overlay:SetAllPoints()
		overlay:SetFrameLevel(button:GetFrameLevel() + 5)
		overlay.text = overlay:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
		-- Anchored at one point so large sizes overflow the icon instead of truncating.
		overlay.text:SetPoint("TOP", 0, -2)
		overlay.text:SetJustifyH("CENTER")
		overlay.text:SetWordWrap(false)
		overlay.fontFile = overlay.text:GetFont()
		button.PredUIBagValue = overlay
	end
	local size = FontSize()
	if overlay.fontSize ~= size and overlay.fontFile then
		overlay.text:SetFont(overlay.fontFile, size, "OUTLINE")
		overlay.fontSize = size
	end
	return overlay
end

local function ClearButton(button)
	if button.PredUIBagValue then
		button.PredUIBagValue.text:SetText("")
	end
end

local function IsActive()
	return db.enabled and (merchantOpen or not db.merchantOnly)
end

-- Unit sell price and stack count of a bag slot, or nil when it has no
-- value or its item data isn't cached yet (GET_ITEM_INFO_RECEIVED refreshes).
local function GetSlotValue(bag, slot)
	local info = C_Container.GetContainerItemInfo(bag, slot)
	if not (info and info.itemID) or info.hasNoValue then return end
	local sellPrice = select(11, C_Item.GetItemInfo(info.itemID))
	if not sellPrice or sellPrice <= 0 then return end
	return sellPrice, info.stackCount or 1
end

local function UpdateButton(button, bag, slot)
	local sellPrice, count
	if IsActive() then
		sellPrice, count = GetSlotValue(bag, slot)
	end
	if not sellPrice then
		ClearButton(button)
		return
	end
	local value = sellPrice
	if db.stackTotal then
		value = value * count
	end
	GetOverlay(button).text:SetText(FormatValue(value))
end

--------------------------------------------------------------------------------
-- Bag total (bottom left of the backpack / combined bags frame)
--------------------------------------------------------------------------------

local function GetBagsTotal()
	local total = 0
	for bag = 0, NUM_BAG_SLOTS do
		for slot = 1, C_Container.GetContainerNumSlots(bag) do
			local sellPrice, count = GetSlotValue(bag, slot)
			if sellPrice then
				total = total + sellPrice * count
			end
		end
	end
	return total
end

local function FormatCoins(copper)
	return C_CurrencyInfo.GetCoinTextureString(copper)
end

local function GetMoneyFrame(frame)
	return frame.MoneyFrame or _G[(frame:GetName() or "") .. "MoneyFrame"]
end

local totalText

-- Frame showing the player's money: the combined bags frame when it's in
-- use, otherwise the backpack's own frame.
local function GetTotalHost()
	if ContainerFrameCombinedBags and ContainerFrameCombinedBags:IsShown() then
		return ContainerFrameCombinedBags
	end
	for i = 1, NUM_CONTAINER_FRAMES or 13 do
		local frame = _G["ContainerFrame" .. i]
		if frame and frame:IsShown() and frame:GetID() == 0 then
			return frame
		end
	end
end

local function UpdateTotal()
	local host = GetTotalHost()
	if not (host and IsActive() and db.showTotal) then
		if totalText then totalText:Hide() end
		return
	end

	-- Own frame, raised above the bottom money bar's art, which would
	-- otherwise cover text drawn on the bag frame itself.
	if not totalText then
		totalText = CreateFrame("Frame", "PredUIBagValueTotal", host)
		totalText:SetSize(1, 1)
		totalText.text = totalText:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		totalText.text:SetPoint("LEFT")
		totalText.text:SetJustifyH("LEFT")
	end
	local money = GetMoneyFrame(host)
	totalText:SetParent(host)
	totalText:SetFrameStrata(host:GetFrameStrata())
	totalText:SetFrameLevel(math.max(host:GetFrameLevel(), money and money:GetFrameLevel() or 0) + 10)

	-- Line up vertically with the money display in the bottom bar.
	local y = 14
	if money and money:GetBottom() and host:GetBottom() then
		y = money:GetBottom() - host:GetBottom() + money:GetHeight() / 2
	end
	totalText:ClearAllPoints()
	totalText:SetPoint("LEFT", host, "BOTTOMLEFT", 14, y)

	totalText.text:SetText(S.GOLD .. "Sell:|r " .. FormatCoins(GetBagsTotal()))
	totalText:Show()
end

-- Bag ID for a container item button: newer templates expose GetBagID(),
-- older ones keep it as the parent container frame's ID.
local function GetButtonBag(button)
	if button.GetBagID then
		return button:GetBagID()
	end
	return button:GetParent():GetID()
end

local function UpdateContainerFrame(frame)
	if not frame:IsShown() then return end
	if frame.EnumerateValidItems then
		for _, button in frame:EnumerateValidItems() do
			UpdateButton(button, GetButtonBag(button), button:GetID())
		end
	else
		local name = frame:GetName()
		local bag = frame:GetID()
		for i = 1, frame.size or 0 do
			local button = _G[name .. "Item" .. i]
			if button then
				UpdateButton(button, bag, button:GetID())
			end
		end
	end
end

local function ForEachContainerFrame(fn)
	for i = 1, NUM_CONTAINER_FRAMES or 13 do
		local frame = _G["ContainerFrame" .. i]
		if frame then fn(frame) end
	end
	if ContainerFrameCombinedBags then
		fn(ContainerFrameCombinedBags)
	end
end

local function UpdateBank()
	-- Forever's bank shows one tab at a time in BankPanel; each button knows its
	-- bank tab (a bag ID) and slot.
	local panel = BankPanel
	if not (panel and panel:IsShown() and panel.EnumerateValidItems) then return end
	for button in panel:EnumerateValidItems() do
		local bag, slot = button:GetBankTabID(), button:GetContainerSlotID()
		if bag and slot then UpdateButton(button, bag, slot) end
	end
end

local function RefreshAll()
	ForEachContainerFrame(UpdateContainerFrame)
	UpdateBank()
	UpdateTotal()
end

-- Debounce bursts of bag/item events into one refresh.
local refreshPending = false
local function QueueRefresh()
	if refreshPending then return end
	refreshPending = true
	C_Timer.After(0.05, function()
		refreshPending = false
		RefreshAll()
	end)
end

--------------------------------------------------------------------------------
-- Commands (slash and settings menu)
--------------------------------------------------------------------------------

local function Toggle(key, label)
	db[key] = not db[key]
	RefreshAll()
	M.Say(label .. ": " .. (db[key] and "on" or "off"))
end

local function OnSlash(msg)
	local cmd, arg = msg:lower():match("^%s*(%S*)%s*(.-)%s*$")
	if cmd == "size" then
		local n = tonumber(arg)
		if n then
			db.fontSize = math.max(MIN_FONT_SIZE, math.min(MAX_FONT_SIZE, math.floor(n)))
			RefreshAll()
			M.Say("font size: " .. FontSize())
		else
			M.Say("usage: /bagvalue size N  (" .. MIN_FONT_SIZE .. "-" .. MAX_FONT_SIZE .. "), currently " .. FontSize())
		end
	elseif cmd == "toggle" then
		Toggle("enabled", "Sell values")
	elseif cmd == "stack" then
		Toggle("stackTotal", "Stack total")
	elseif cmd == "vendor" then
		Toggle("merchantOnly", "Only at vendors")
	elseif cmd == "total" then
		Toggle("showTotal", "Bag total")
	elseif cmd == "" or cmd == "options" then
		ns.OpenSettings(M)
	else
		M.Say("/bagvalue - options, /bagvalue toggle, /bagvalue stack, /bagvalue vendor, /bagvalue total, /bagvalue size N")
	end
end

local function Changed() RefreshAll() end

M.options = {
	{ type = "checkbox", key = "enabled", label = "Show sell values", tooltip = "Show the vendor sell value on item icons in your bags and bank.", onChange = Changed },
	{ type = "checkbox", key = "stackTotal", label = "Use stack total", tooltip = "Show the value of the whole stack (price x count) instead of the price of one item.", onChange = Changed },
	{ type = "checkbox", key = "merchantOnly", label = "Only at vendors", tooltip = "Only show values while a vendor window is open.", onChange = Changed },
	{ type = "checkbox", key = "showTotal", label = "Show bag total", tooltip = "Show the total sell value of everything in your bags at the bottom left of the backpack.", onChange = Changed },
	{ type = "slider", key = "fontSize", label = "Font size", min = MIN_FONT_SIZE, max = MAX_FONT_SIZE, step = 1, tooltip = "Size of the sell value text on item icons.", onChange = Changed },
}

--------------------------------------------------------------------------------
-- Start-up
--------------------------------------------------------------------------------

function M:Enable()
	db = self.db

	-- Re-apply after the default UI redraws a bag, which happens on open and
	-- whenever its contents change.
	ForEachContainerFrame(function(frame)
		frame:HookScript("OnShow", QueueRefresh)
		if frame.UpdateItems then
			hooksecurefunc(frame, "UpdateItems", QueueRefresh)
		end
	end)
	if BankFrame then
		BankFrame:HookScript("OnShow", QueueRefresh)
	end
	if BankPanel and BankPanel.GenerateItemSlotsForSelectedTab then
		-- Runs when the bank opens and on every tab switch.
		hooksecurefunc(BankPanel, "GenerateItemSlotsForSelectedTab", QueueRefresh)
	end

	local events = CreateFrame("Frame")
	events:RegisterEvent("BAG_UPDATE_DELAYED")
	events:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
	events:RegisterEvent("BANKFRAME_OPENED")
	events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
	events:RegisterEvent("MERCHANT_SHOW")
	events:RegisterEvent("MERCHANT_CLOSED")
	events:SetScript("OnEvent", function(_, event)
		if event == "MERCHANT_SHOW" then
			merchantOpen = true
		elseif event == "MERCHANT_CLOSED" then
			merchantOpen = false
		end
		QueueRefresh()
	end)
end

SLASH_PREDUIBAG1, SLASH_PREDUIBAG2 = "/bagvalue", "/bv"
SlashCmdList.PREDUIBAG = ns.SlashHandler(M, OnSlash)
