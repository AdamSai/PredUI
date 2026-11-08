--------------------------------------------------------------------------------
-- Craft Cost, part 2: the shopping list in the Auction House, and keeping the
-- list up to date as items reach your bags. The list itself is the post-it
-- note made by Notes.lua, so both views always agree.
--
--   * The "Shopping List" tab looks and acts like the AH's own: your list on the
--     left, live results for the clicked item on the right, the other tabs
--     unselected and the title changed while it's open. It's our own panel over
--     the AH, kept out of AuctionHouseFrame.Tabs and its display modes, and it
--     never calls SetDisplayMode: addon code writing there would taint the
--     buying code. The tab's template adds it to its parent's Tabs list, so its
--     parent is a holder frame of ours. Selecting a tab only changes widgets.
--   * Results come straight from C_AuctionHouse.SendSearchQuery, which addons
--     may call freely. It's throttled, so a search waits its turn if needed.
--   * Buying follows Blizzard's own steps, always from a click and always after
--     a confirm box. Commodities: StartCommoditiesPurchase gets a quote
--     (COMMODITY_PRICE_UPDATED), which the box shows, then
--     ConfirmCommoditiesPurchase. The game picks the cheapest stacks itself, so
--     there's one "Buy" for the amount still needed. Single auctions: PlaceBid
--     with the exact buyout, each from its own row.
--   * "Open in Buy tab" fills in Blizzard's search box, if you'd rather buy there.
--   * Bags: any rise in an item's bag count comes off its line. Using materials
--     lowers the count and never adds back to the list. Counts aren't saved,
--     because anything that arrives while you're offline comes through the
--     mailbox while you're online anyway.
--   * AH buys arrive by mail, so they count when the mail is collected.
--   * While the bank is open, or an item is on the cursor, a rise is only
--     moved items, so nothing is taken off.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.Style
local M = ns.byKey.craftcost
local Public, PublicNumber, Try = ns.Public, ns.PublicNumber, ns.Try

local NUM_ROWS, ROW_H = 14, 28
local HEADER_H, COLUMN_H = 40, 20
local LIST_W = 290
local PRICE_W, AVAILABLE_W = 130, 70
local BUY_W = 40               -- the Buy button on a single auction's row
local QUOTE_WAIT = 8           -- seconds to wait for the game's price before giving up
local TAB_TITLE = "Shopping List"
local TAB_ROW_TOLERANCE = 6    -- how far off Buy's height a tab can sit (a selected tab shifts a little)
local MAX_FRAMES_SCANNED = 50000
local LATE_TAB_DELAY = 0.5     -- seconds; other addons may add tabs as the window opens
local RESEARCH_DELAY = 1       -- seconds after a purchase before refreshing the results
local LOGIN_SETTLE = 3         -- seconds after login before bag rises count
local NO_RESULT_WAIT = 6       -- seconds before a silent search counts as "none found"
local MAX_RESULTS = 200        -- stop asking for more pages after this many

local charDB
local panel, shopTab
local tabOpen = false
local previousTab, clickedTab  -- the tab selected before ours, and the one clicked to leave
local savedTitle
local hookedTabs = {}
local moreAsked = false        -- a request for the next page of results is in flight
local listOffset, resultOffset = 0, 0
local counts = {}              -- [itemID] = last bag count seen this session
local ready = false            -- false just after login, while bags are still filling
local bankOpen = false

local selected                 -- the list line being searched: { id, name, qty, done }
local selectedKey              -- its ItemKey
local results = {}             -- { price, qty, name, commodity, auctionID, buyout, own }, cheapest first
local searching, waiting = false, false
local searchToken = 0
local customAmount             -- what you typed in the amount box, or nil to follow the list
local buy                      -- the purchase in the confirm box, or nil
local buyToken = 0

local function Lines()
	return ns.GetShoppingList and ns.GetShoppingList(charDB.shoppingNote) or nil
end

--------------------------------------------------------------------------------
-- Results pane
--------------------------------------------------------------------------------

-- How many to buy: the number you typed, or else what the list still needs.
local function WantedAmount()
	if customAmount then return customAmount end
	if selected and not selected.done then return selected.qty end
end

-- "Cheapest 4: ~1g", walking up the price list until the need is met.
local function Summary()
	local wanted = WantedAmount()
	if not wanted or #results == 0 then return "" end
	local need, cost = wanted, 0
	for _, r in ipairs(results) do
		if not r.own then
			local take = math.min(need, r.qty)
			cost = cost + take * r.price
			need = need - take
			if need <= 0 then break end
		end
	end
	if need > 0 then
		return S.WARN .. "Only " .. (wanted - need) .. " on sale|r  ~" .. M.Coins(cost)
	end
	return "Cheapest " .. wanted .. ": ~" .. M.Coins(cost)
end

-- How many commodities to buy, and what that should cost going by the list.
local function CommodityPlan()
	local want, cost, got = WantedAmount(), 0, 0
	if not want then return end
	for _, r in ipairs(results) do
		if r.commodity then
			local take = math.min(want - got, r.qty)
			cost = cost + take * r.price
			got = got + take
			if got >= want then break end
		end
	end
	if got > 0 then return got, cost end
end

local function DrawResults()
	if not panel then return end
	local maxOffset = math.max(0, #results - NUM_ROWS)
	resultOffset = math.min(resultOffset, maxOffset)
	panel.resultScroll:SetMinMaxValues(0, maxOffset)
	panel.resultScroll:SetShown(maxOffset > 0)

	-- Stacked items have no per-row Buy, so Available moves over into that space.
	local hasBuy = false
	for _, r in ipairs(results) do
		if not r.commodity and not r.own then hasBuy = true break end
	end
	panel.availableHeader:ClearAllPoints()
	panel.availableHeader:SetPoint("TOPRIGHT", hasBuy and (-16 - BUY_W - 8) or -16, -3)

	for i = 1, NUM_ROWS do
		local row, r = panel.resultRows[i], results[i + resultOffset]
		row.result = r
		row.available:ClearAllPoints()
		if hasBuy then
			row.available:SetPoint("RIGHT", row.buy, "LEFT", -6, 0)
		else
			row.available:SetPoint("RIGHT", -4, 0)
		end
		if r then
			row.price:SetText(M.Coins(r.price))
			row.name:SetText(r.own and (r.name .. S.DIM .. " (yours)|r") or r.name)
			row.available:SetText(r.qty)
			row.buy:SetShown(not r.commodity and not r.own)
			row:Show()
		else
			row:Hide()
		end
	end

	local status = ""
	if not selected then
		status = "Click an item on the left to search for it."
	elseif waiting or searching then
		status = "Searching..."
	elseif #results == 0 then
		status = "No auctions found."
	end
	panel.status:SetText(S.DIM .. status .. "|r")
	panel.status:SetShown(status ~= "")
	panel.summaryText = Summary()
	panel.summary:SetText(panel.summaryText)
	panel.openBuy:SetShown(selected ~= nil)
	local amount = CommodityPlan()
	panel.buyAll:SetShown(amount ~= nil)
	if amount then panel.buyAll.label:SetText("Buy " .. amount) end

	-- The box is there for any stacked item, even one already done on the list.
	local hasCommodity = false
	for _, r in ipairs(results) do
		if r.commodity then hasCommodity = true break end
	end
	panel.amountBox:SetShown(hasCommodity)
	if hasCommodity and not panel.amountBox:HasFocus() then
		local wanted = WantedAmount()
		panel.amountBox:SetText(wanted and tostring(wanted) or "")
	end
	panel.results = results
end

local function AddResult(price, qty, name, extra)
	price, qty = PublicNumber(price), PublicNumber(qty)
	if price and qty and qty > 0 then
		extra.price, extra.qty, extra.name = price, qty, name
		results[#results + 1] = extra
	end
end

-- Reads whichever kind of result this item has: commodities or single auctions.
local function ReadResults()
	if not selected then return end
	wipe(results)
	local id, key = selected.id, selectedKey
	for i = 1, PublicNumber(Try(C_AuctionHouse.GetNumCommoditySearchResults, id)) or 0 do
		local r = Try(C_AuctionHouse.GetCommoditySearchResultInfo, id, i)
		if Public(r) and type(r) == "table" then
			-- Your own stacks can't be bought back.
			local mine = PublicNumber(r.numOwnerItems) or 0
			local total = PublicNumber(r.quantity)
			AddResult(r.unitPrice, total and total - mine, selected.name, { commodity = true })
		end
	end
	for i = 1, PublicNumber(Try(C_AuctionHouse.GetNumItemSearchResults, key)) or 0 do
		local r = Try(C_AuctionHouse.GetItemSearchResultInfo, key, i)
		if Public(r) and type(r) == "table" and r.buyoutAmount then
			AddResult(r.buyoutAmount, r.quantity, selected.name, {
				auctionID = PublicNumber(r.auctionID),
				buyout = PublicNumber(r.buyoutAmount),
				own = Public(r.containsOwnerItem) and r.containsOwnerItem or nil,
			})
		end
	end
	table.sort(results, function(a, b) return a.price < b.price end)
end

-- The next page, only when you scroll to the bottom (as Blizzard's lists do).
local function RequestMore()
	if not selected or buy or moreAsked or #results == 0 or #results >= MAX_RESULTS then return end
	if Try(C_AuctionHouse.IsThrottledMessageSystemReady) == false then return end
	if Try(C_AuctionHouse.HasFullCommoditySearchResults, selected.id) == false then
		moreAsked = true
		Try(C_AuctionHouse.RequestMoreCommoditySearchResults, selected.id)
	elseif Try(C_AuctionHouse.HasFullItemSearchResults, selectedKey) == false then
		moreAsked = true
		Try(C_AuctionHouse.RequestMoreItemSearchResults, selectedKey)
	end
end

local ITEM_SORTS
local NO_SORTS = {}            -- Blizzard sends commodity searches with no sort order

local function SendSearch()
	if not selected then return end
	if Try(C_AuctionHouse.IsThrottledMessageSystemReady) == false then
		waiting = true                               -- AUCTION_HOUSE_THROTTLED_SYSTEM_READY retries
		return
	end
	waiting, searching, moreAsked = false, true, false
	ITEM_SORTS = ITEM_SORTS or {
		{ sortOrder = Enum.AuctionHouseSortOrder.Buyout, reverseSort = false },
		{ sortOrder = Enum.AuctionHouseSortOrder.Bid, reverseSort = false },
	}
	local info = Try(C_AuctionHouse.GetItemKeyInfo, selectedKey)
	local known = Public(info) and type(info) == "table"
	if known and info.isEquipment then
		Try(C_AuctionHouse.SendSellSearchQuery, selectedKey, ITEM_SORTS, false)  -- every item level
	else
		local singles = known and info.isCommodity == false
		Try(C_AuctionHouse.SendSearchQuery, selectedKey, singles and ITEM_SORTS or NO_SORTS, false)
	end
	searchToken = searchToken + 1
	local token = searchToken
	C_Timer.After(NO_RESULT_WAIT, function()
		if token == searchToken and searching then
			searching = false
			DrawResults()
		end
	end)
end

--------------------------------------------------------------------------------
-- Buying
--------------------------------------------------------------------------------

-- finished: the purchase went through, so there's no quote left to cancel.
local function CloseBuy(finished)
	if not buy then return end
	local wasCommodity = buy.commodity
	buy = nil
	buyToken = buyToken + 1
	panel.confirm:SetScript("OnUpdate", nil)
	panel.confirm:Hide()
	if wasCommodity and finished ~= true then Try(C_AuctionHouse.CancelCommoditiesPurchase) end
end

local function ShowConfirm(text, canBuy)
	panel.confirm.text:SetText(text)
	panel.confirm.yes:SetEnabled(canBuy)
	panel.confirm:Show()
end

local function OfferPrice(total, note)
	buy.total = total
	local afford = total <= (PublicNumber(GetMoney()) or 0)
	ShowConfirm(("Buy %d %s for %s?"):format(buy.qty, buy.name, M.Coins(total))
		.. (note and ("\n" .. note) or "")
		.. (afford and "" or ("\n" .. S.BAD .. "You don't have enough gold.|r")), afford)
end

-- Ends a purchase that went through or fell over. The results refresh a moment
-- later, so the search doesn't land on top of the purchase being processed.
local function FinishBuy(message, finished)
	CloseBuy(finished)
	if finished then customAmount = nil end
	if message then M.Say(message) end
	local item = selected
	C_Timer.After(RESEARCH_DELAY, function()
		if item and selected == item and not buy then
			SendSearch()
			DrawResults()
		end
	end)
end

local function StartCommodityBuy()
	local amount, preview = CommodityPlan()
	if not amount or buy then return end
	buy = { commodity = true, id = selected.id, name = selected.name, qty = amount, preview = preview }
	ShowConfirm(("Getting the price for %d %s..."):format(amount, selected.name), false)
	C_AuctionHouse.StartCommoditiesPurchase(buy.id, amount)
	buyToken = buyToken + 1
	local token = buyToken
	C_Timer.After(QUOTE_WAIT, function()
		if token == buyToken and buy and not buy.total then
			FinishBuy("the game didn't give a price. Try again, or use the Buy tab.")
		end
	end)
end

local function StartItemBuy(result)
	if buy or result.own or not (result.auctionID and result.buyout) then return end
	buy = { auctionID = result.auctionID, name = result.name, qty = result.qty }
	OfferPrice(result.buyout)
end

local function ConfirmBuy()
	if not (buy and buy.total) or buy.purchasing then return end
	buy.purchasing = true
	panel.confirm:SetScript("OnUpdate", nil)
	ShowConfirm(("Buying %d %s..."):format(buy.qty, buy.name), false)
	if buy.commodity then
		C_AuctionHouse.ConfirmCommoditiesPurchase(buy.id, buy.qty)
	else
		C_AuctionHouse.PlaceBid(buy.auctionID, buy.total)
	end
end

local function OnBuyEvent(event, a1, a2)
	if not buy then return end
	if event == "AUCTION_HOUSE_SHOW_ERROR" then
		FinishBuy("that purchase didn't go through.")
	elseif event == "AUCTION_HOUSE_PURCHASE_COMPLETED" then
		if not buy.commodity and PublicNumber(a1) == buy.auctionID then
			FinishBuy(("bought %d %s. It comes by mail."):format(buy.qty, buy.name), true)
		end
	elseif not buy.commodity then
		return
	elseif event == "COMMODITY_PRICE_UPDATED" then
		local total = PublicNumber(a2)
		if not total or buy.purchasing then return end
		OfferPrice(total, total > buy.preview and (S.WARN .. "The price went up since the search.|r") or nil)
		-- The game's quote runs out; don't leave a dead offer on screen.
		panel.confirm:SetScript("OnUpdate", function()
			if PublicNumber(Try(C_AuctionHouse.GetQuoteDurationRemaining)) == 0 then
				FinishBuy("the price quote ran out. Click Buy again.")
			end
		end)
	elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
		FinishBuy(("bought %d %s. It comes by mail."):format(buy.qty, buy.name), true)
	else                                         -- COMMODITY_PRICE_UNAVAILABLE or COMMODITY_PURCHASE_FAILED
		FinishBuy("those are no longer available at that price. Results refreshed.")
	end
end

--------------------------------------------------------------------------------
-- List pane
--------------------------------------------------------------------------------

local function Refresh()
	if not (panel and panel:IsShown()) then return end
	local lines = Lines() or {}
	table.sort(lines, function(a, b)
		if a.done ~= b.done then return b.done end
		return a.name < b.name
	end)

	local total = 0
	for _, line in ipairs(lines) do
		local price = not line.done and M.BuyPrice(line.id)
		if price then total = total + price * line.qty end
		if selected and line.id == selected.id then selected = line end   -- newest amounts
	end
	panel.total:SetText(total > 0 and ("Left to buy: ~" .. M.Coins(total)) or "")
	panel.empty:SetShown(#lines == 0)

	local maxOffset = math.max(0, #lines - NUM_ROWS)
	listOffset = math.min(listOffset, maxOffset)
	panel.listScroll:SetMinMaxValues(0, maxOffset)
	panel.listScroll:SetShown(maxOffset > 0)

	for i = 1, NUM_ROWS do
		local row, line = panel.rows[i], lines[i + listOffset]
		row.line = line
		if line then
			row.icon:SetTexture(Try(C_Item.GetItemIconByID, line.id))
			row.icon:SetDesaturated(line.done)
			row.name:SetText((line.done and S.DIM or "|cffffffff") .. line.name .. "|r")
			row.left:SetText(line.done and (S.GOOD .. "Done|r") or (line.qty .. " left"))
			row.selection:SetShown(selected ~= nil and selected.id == line.id)
			row:Show()
		else
			row:Hide()
		end
	end
	DrawResults()
end

local function Select(line)
	CloseBuy()
	customAmount = nil
	selected = line
	selectedKey = C_AuctionHouse.MakeItemKey(line.id)
	wipe(results)
	resultOffset = 0
	panel.resultScroll:SetValue(0)
	SendSearch()
	Refresh()
	DrawResults()
end

-- Fills in the AH search box; Enter then runs Blizzard's own search.
local function OpenInBuyTab()
	if not selected then return end
	local bar = AuctionHouseFrame and AuctionHouseFrame.SearchBar
	panel:Hide()
	if not (bar and bar.SearchBox and bar:IsShown()) then
		M.Say("open the Buy tab first, then try again.")
		return
	end
	bar.SearchBox:SetText(selected.name)
	bar.SearchBox:SetFocus()
	bar.SearchBox:HighlightText()
end

--------------------------------------------------------------------------------
-- Building the panel
--------------------------------------------------------------------------------

local function CreateListRow(i)
	local row = CreateFrame("Button", nil, panel.listPane)
	row:SetHeight(ROW_H)
	row:SetPoint("TOPLEFT", 0, -COLUMN_H - (i - 1) * ROW_H)
	row:SetPoint("TOPRIGHT", -12, -COLUMN_H - (i - 1) * ROW_H)
	S.RowHighlight(row)
	row.selection = S.Texture(row, "BACKGROUND", 0)
	row.selection:SetVertexColor(S.ACCENT[1], S.ACCENT[2], S.ACCENT[3], 0.22)
	row.selection:SetAllPoints()
	row.selection:Hide()
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(22, 22)
	row.icon:SetPoint("LEFT", 2, 0)
	row.left = S.Text(row, 12)
	row.left:SetPoint("RIGHT", -4, 0)
	row.left:SetJustifyH("RIGHT")
	row.name = S.Text(row, 12)
	row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
	row.name:SetPoint("RIGHT", row.left, "LEFT", -6, 0)
	row.name:SetJustifyH("LEFT")
	row:SetScript("OnClick", function(self)
		if self.line then Select(self.line) end
	end)
	row:SetScript("OnEnter", function(self)
		if not self.line then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetItemByID(self.line.id)
		GameTooltip:AddLine("Click to see what's on sale.", 0.5, 0.5, 0.5)
		GameTooltip:Show()
	end)
	row:SetScript("OnLeave", function() GameTooltip_Hide() end)
	return row
end

local function CreateResultRow(i)
	local row = CreateFrame("Frame", nil, panel.resultPane)
	row:SetHeight(ROW_H)
	row:SetPoint("TOPLEFT", 0, -COLUMN_H - (i - 1) * ROW_H)
	row:SetPoint("TOPRIGHT", -12, -COLUMN_H - (i - 1) * ROW_H)
	row.price = S.Text(row, 12)
	row.price:SetPoint("LEFT", 4, 0)
	row.price:SetWidth(PRICE_W - 8)
	row.price:SetJustifyH("LEFT")
	row.buy = S.Button(row, "Buy", BUY_W, 22)
	row.buy:SetPoint("RIGHT", -2, 0)
	row.buy.tooltip = "Buy this auction. You'll be asked to confirm."
	row.buy:SetScript("OnClick", function()
		if row.result then StartItemBuy(row.result) end
	end)
	row.available = S.Text(row, 12)
	row.available:SetPoint("RIGHT", row.buy, "LEFT", -6, 0)
	row.available:SetWidth(AVAILABLE_W - 8)
	row.available:SetJustifyH("RIGHT")
	row.name = S.Text(row, 12)
	row.name:SetPoint("LEFT", row.price, "RIGHT", 8, 0)
	row.name:SetPoint("RIGHT", row.available, "LEFT", -8, 0)
	row.name:SetJustifyH("LEFT")
	return row
end

local function Column(parent, text, x, right)
	local label = S.Text(parent, 11)
	label:SetPoint(right and "TOPRIGHT" or "TOPLEFT", x, -3)
	label:SetText(S.GOLD .. text .. "|r")
	return label
end

local function CreatePane(point, relativePoint, x)
	local pane = CreateFrame("Frame", nil, panel)
	pane:SetPoint(point, panel, relativePoint, x, -HEADER_H)
	pane:SetHeight(COLUMN_H + NUM_ROWS * ROW_H)
	pane:EnableMouseWheel(true)
	return pane
end

local function CreatePanel()
	panel = CreateFrame("Frame", "PredUIShoppingPanel", AuctionHouseFrame)
	panel:SetPoint("TOPLEFT", 8, -26)
	panel:SetPoint("BOTTOMRIGHT", -8, 28)
	panel:SetFrameLevel(AuctionHouseFrame:GetFrameLevel() + 60)
	panel:EnableMouse(true)                     -- clicks stay off the AH beneath
	S.Body(panel, { 0.055, 0.06, 0.075, 1 })
	panel:Hide()

	-- Starts clear of the window's portrait; the title bar names the tab.
	panel.total = S.Text(panel, 12)
	panel.total:SetPoint("TOPLEFT", 66, -12)

	panel.openBuy = S.Button(panel, "Open in Buy tab", 112, 22)
	panel.openBuy:SetPoint("TOPRIGHT", -S.PAD, -8)
	panel.openBuy.tooltip = "Puts this item in the Buy tab's search box. Press Enter to search."
	panel.openBuy:SetScript("OnClick", OpenInBuyTab)
	panel.openBuy:Hide()
	panel.buyAll = S.Button(panel, "Buy", 76, 22)
	panel.buyAll:SetPoint("RIGHT", panel.openBuy, "LEFT", -6, 0)
	panel.buyAll.tooltip = "Buy what you still need, cheapest first. You'll be asked to confirm the final price."
	panel.buyAll:SetScript("OnClick", StartCommodityBuy)
	panel.buyAll:Hide()
	panel.amountBox = S.EditBox(panel, 46, 22)
	panel.amountBox:SetPoint("RIGHT", panel.buyAll, "LEFT", -6, 0)
	panel.amountBox:SetNumeric(true)
	panel.amountBox:SetMaxLetters(4)
	panel.amountBox:SetJustifyH("CENTER")
	panel.amountBox:SetScript("OnTextChanged", function(self, userInput)
		if not userInput then return end
		local n = tonumber(self:GetText())
		customAmount = n and n > 0 and n or nil
		DrawResults()
	end)
	panel.amountBox:SetScript("OnEnterPressed", panel.amountBox.ClearFocus)
	panel.amountBox:Hide()
	panel.summary = S.Text(panel, 12)
	panel.summary:SetPoint("RIGHT", panel.amountBox, "LEFT", -10, 0)
	panel.summaryText = ""

	-- Left: the list.
	panel.listPane = CreatePane("TOPLEFT", "TOPLEFT", S.PAD)
	panel.listPane:SetWidth(LIST_W)
	Column(panel.listPane, "Item", 32)
	Column(panel.listPane, "To buy", -16, true)
	panel.empty = S.Text(panel.listPane, 12)
	panel.empty:SetPoint("TOP", 0, -COLUMN_H - 20)
	panel.empty:SetWidth(LIST_W - 20)
	panel.empty:SetWordWrap(true)
	panel.empty:SetText(S.DIM .. "Nothing on your list. Use Add beside the Professions window.|r")
	panel.rows = {}
	for i = 1, NUM_ROWS do panel.rows[i] = CreateListRow(i) end
	panel.listScroll = S.ScrollBar(panel.listPane, function(value)
		listOffset = value
		Refresh()
	end)
	panel.listScroll:SetPoint("TOPRIGHT", 0, -COLUMN_H)
	panel.listScroll:SetHeight(NUM_ROWS * ROW_H)
	panel.listPane:SetScript("OnMouseWheel", function(_, delta)
		panel.listScroll:SetValue(panel.listScroll:GetValue() - delta)
	end)

	local divider = S.Texture(panel, "ARTWORK", 0)
	divider:SetVertexColor(1, 1, 1, 0.08)
	divider:SetWidth(1)
	divider:SetPoint("TOPLEFT", S.PAD + LIST_W + 8, -HEADER_H)
	divider:SetPoint("BOTTOMLEFT", S.PAD + LIST_W + 8, 10)

	-- Right: what's on sale.
	panel.resultPane = CreatePane("TOPLEFT", "TOPLEFT", S.PAD + LIST_W + 16)
	panel.resultPane:SetPoint("RIGHT", panel, "RIGHT", -S.PAD, 0)
	Column(panel.resultPane, "Price", 4)
	Column(panel.resultPane, "Name", PRICE_W + 4)
	panel.availableHeader = Column(panel.resultPane, "Available", -16, true)
	panel.resultRows = {}
	for i = 1, NUM_ROWS do panel.resultRows[i] = CreateResultRow(i) end
	panel.status = S.Text(panel.resultPane, 12)
	panel.status:SetPoint("TOP", 0, -COLUMN_H - 20)
	panel.resultScroll = S.ScrollBar(panel.resultPane, function(value)
		resultOffset = value
		DrawResults()
		if value >= #results - NUM_ROWS then RequestMore() end
	end)
	panel.resultScroll:SetPoint("TOPRIGHT", 0, -COLUMN_H)
	panel.resultScroll:SetHeight(NUM_ROWS * ROW_H)
	panel.resultPane:SetScript("OnMouseWheel", function(_, delta)
		panel.resultScroll:SetValue(panel.resultScroll:GetValue() - delta)
	end)

	panel:SetScript("OnShow", function()
		SendSearch()                            -- prices may have moved since last time
		Refresh()
	end)
	panel:SetScript("OnHide", function()
		GameTooltip_Hide()
		CloseBuy()
		M.OnShoppingTabClosed()
	end)

	local confirm = CreateFrame("Frame", nil, panel)
	confirm:SetSize(380, 112)
	confirm:SetPoint("CENTER")
	confirm:SetFrameLevel(panel:GetFrameLevel() + 30)
	confirm:EnableMouse(true)
	S.Body(confirm, { 0.08, 0.09, 0.11, 1 }, S.ACCENT)
	confirm:Hide()
	confirm.text = S.Text(confirm, 13)
	confirm.text:SetPoint("TOPLEFT", S.PAD, -S.PAD)
	confirm.text:SetPoint("TOPRIGHT", -S.PAD, -S.PAD)
	confirm.text:SetWordWrap(true)
	confirm.yes = S.Button(confirm, "Buy now", 100, 24)
	confirm.yes:SetPoint("BOTTOMRIGHT", confirm, "BOTTOM", -6, 12)
	confirm.yes:SetScript("OnClick", ConfirmBuy)
	confirm.no = S.Button(confirm, "Cancel", 100, 24)
	confirm.no:SetPoint("BOTTOMLEFT", confirm, "BOTTOM", 6, 12)
	confirm.no:SetScript("OnClick", function() CloseBuy() end)
	panel.confirm = confirm

	panel.results = results
	-- For the scenario test.
	panel.Select = Select
	panel.StartCommodityBuy = StartCommodityBuy
	panel.StartItemBuy = StartItemBuy
	panel.ConfirmBuy = ConfirmBuy
	panel.CancelBuy = CloseBuy
	panel.RequestMore = RequestMore
	panel.SetBuyAmount = function(n)
		customAmount = n
		DrawResults()
	end
	panel.GetBuy = function() return buy end
end

local function IsInAuctionHouse(frame)
	local parent = frame:GetParent()
	for _ = 1, 12 do                            -- far deeper than any tab
		if not parent then return false end
		if parent == AuctionHouseFrame then return true end
		parent = parent:GetParent()
	end
	return false
end

-- Is this one frame a tab in the row? The scan meets every frame in the game, and
-- some answer with secret values or refuse (auras, forbidden frames), so it's run
-- through Try and every answer is checked before use.
local function IsTabInRow(frame, buyLeft, buyY)
	if frame == shopTab or frame:IsForbidden() then return false end
	local kind = frame:GetObjectType()
	if not Public(kind) or kind ~= "Button" then return false end
	local visible = frame:IsVisible()
	if not Public(visible) or not visible then return false end
	local x, y = frame:GetCenter()
	x, y = PublicNumber(x), PublicNumber(y)
	if not (x and y) or math.abs(y - buyY) > TAB_ROW_TOLERANCE or x < buyLeft then return false end
	if not (frame.LeftActive or IsInAuctionHouse(frame)) then return false end
	return ns.PublicString(frame:GetText()) ~= nil
end

-- Every tab along the bottom, whoever made it. Other addons' tabs aren't always
-- children of the window, so tabs are found by where they sit: a visible, labelled
-- button level with Buy, to its right. Read only.
local function TabRow()
	local row = {}
	local buyTab = AuctionHouseFrame.BuyTab
	local buyLeft = buyTab and PublicNumber(buyTab:GetLeft())
	local _, buyY
	if buyTab then _, buyY = buyTab:GetCenter() end
	buyY = PublicNumber(buyY)
	if not (buyLeft and buyY) then return row end

	local frame, count = EnumerateFrames(), 0
	while frame and count < MAX_FRAMES_SCANNED do
		count = count + 1
		if Try(IsTabInRow, frame, buyLeft, buyY) then row[#row + 1] = frame end
		frame = EnumerateFrames(frame)
	end
	return row
end

-- A selected tab is drawn active and can't be clicked.
local function SelectedTab(row)
	for _, tab in ipairs(row) do
		if tab.LeftActive and tab.LeftActive:IsShown() then return tab end
		if not tab.LeftActive and not tab:IsEnabled() then return tab end
	end
end

-- Goes after the last tab, and makes sure each one closes our panel when clicked.
local function PlaceTab()
	if not shopTab then return end
	local tabs = TabRow()
	table.sort(tabs, function(a, b)
		return (PublicNumber(a:GetRight()) or 0) < (PublicNumber(b:GetRight()) or 0)
	end)
	local last, before = tabs[#tabs], tabs[#tabs - 1]
	for _, tab in ipairs(tabs) do
		if not hookedTabs[tab] then
			hookedTabs[tab] = true
			tab:HookScript("OnClick", function(self)
				if tabOpen then
					clickedTab = self
					panel:Hide()
				end
			end)
		end
	end
	shopTab:ClearAllPoints()
	if last then
		-- The same gap as the last two tabs have, since addons space theirs differently.
		local gap = -15
		local left, right = before and PublicNumber(last:GetLeft()), before and PublicNumber(before:GetRight())
		if left and right then gap = math.max(-20, math.min(12, left - right)) end
		shopTab:SetPoint("LEFT", last, "RIGHT", gap, 0)
	else
		shopTab:SetPoint("BOTTOMLEFT", AuctionHouseFrame, "BOTTOMLEFT", 20, -28)
	end
end

local function OpenTab()
	if tabOpen then return end
	PlaceTab()
	previousTab = SelectedTab(TabRow())
	if previousTab then Try(PanelTemplates_DeselectTab, previousTab) end
	Try(PanelTemplates_SelectTab, shopTab)
	local title = Try(AuctionHouseFrame.GetTitleText, AuctionHouseFrame)
	if title then
		savedTitle = title:GetText()
		title:SetText(TAB_TITLE)
	end
	tabOpen = true
	panel:Show()
end

-- Hands the selected look back: to the tab you clicked, or the one you came from.
function M.OnShoppingTabClosed()
	if not tabOpen then return end
	tabOpen = false
	Try(PanelTemplates_DeselectTab, shopTab)
	local back = clickedTab or previousTab
	if back then Try(PanelTemplates_SelectTab, back) end
	local title = Try(AuctionHouseFrame.GetTitleText, AuctionHouseFrame)
	if title and savedTitle and title:GetText() == TAB_TITLE then title:SetText(savedTitle) end
	clickedTab, previousTab, savedTitle = nil, nil, nil
end

function M.SetUpAuctionHouse()
	if panel or not charDB or not AuctionHouseFrame then return end
	CreatePanel()

	local holder = CreateFrame("Frame", nil, AuctionHouseFrame)
	holder:SetAllPoints()
	shopTab = CreateFrame("Button", "PredUIShoppingTab", holder, "AuctionHouseFrameTabTemplate")
	shopTab:SetText(TAB_TITLE)
	shopTab:SetScript("OnClick", OpenTab)
	Try(PanelTemplates_DeselectTab, shopTab)
	PlaceTab()

	-- Other addons may add their tabs when the window first opens.
	AuctionHouseFrame:HookScript("OnShow", function()
		PlaceTab()
		C_Timer.After(LATE_TAB_DELAY, PlaceTab)
	end)
	AuctionHouseFrame:HookScript("OnHide", function() panel:Hide() end)
	-- For the scenario test.
	panel.OpenTab = OpenTab
	panel.TabRow = TabRow
	panel.PlaceTab = PlaceTab
end

--------------------------------------------------------------------------------
-- Following the bags
--------------------------------------------------------------------------------

local function BagCount(id)
	return PublicNumber(Try(C_Item.GetItemCount, id))
end

-- Notes today's counts without taking anything off, so that new lines don't
-- count what you already hold.
function M.OnListChanged()
	for _, line in ipairs(Lines() or {}) do
		counts[line.id] = BagCount(line.id) or counts[line.id]
	end
	Refresh()
end

local function CheckBags()
	local lines = Lines()
	if not lines then return end
	local cursor = Try(GetCursorInfo)
	if Public(cursor) and cursor then return end     -- a dropped stack brings another update
	local changed = false
	for _, line in ipairs(lines) do
		local count = BagCount(line.id)
		if count then
			local last = counts[line.id]
			if last and count > last and ready and not bankOpen and not line.done then
				ns.ReduceShoppingLine(charDB.shoppingNote, line.id, count - last, M.BuyPrice)
				changed = true
			end
			counts[line.id] = count
		end
	end
	if changed then Refresh() end
end

local function OnSearchResults(event, arg)
	if not selected or not Public(arg) then return end
	local id = type(arg) == "table" and arg.itemID or arg
	if PublicNumber(id) ~= selected.id then return end
	moreAsked = false
	ReadResults()
	if #results > 0 or event == "COMMODITY_SEARCH_RESULTS_UPDATED" or event == "ITEM_SEARCH_RESULTS_UPDATED" then
		searching = false
	end
	DrawResults()
end

function M.EnableList()
	charDB = M.charDB
	M.SetUpAuctionHouse()

	local events = CreateFrame("Frame")
	events:RegisterEvent("PLAYER_ENTERING_WORLD")
	events:RegisterEvent("BAG_UPDATE_DELAYED")
	events:RegisterEvent("BANKFRAME_OPENED")
	events:RegisterEvent("BANKFRAME_CLOSED")
	events:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
	events:RegisterEvent("COMMODITY_SEARCH_RESULTS_ADDED")
	events:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
	events:RegisterEvent("ITEM_SEARCH_RESULTS_ADDED")
	events:RegisterEvent("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
	events:RegisterEvent("COMMODITY_PRICE_UPDATED")
	events:RegisterEvent("COMMODITY_PRICE_UNAVAILABLE")
	events:RegisterEvent("COMMODITY_PURCHASE_SUCCEEDED")
	events:RegisterEvent("COMMODITY_PURCHASE_FAILED")
	events:RegisterEvent("AUCTION_HOUSE_PURCHASE_COMPLETED")
	events:RegisterEvent("AUCTION_HOUSE_SHOW_ERROR")
	events:SetScript("OnEvent", function(_, event, a1, a2)
		if event == "PLAYER_ENTERING_WORLD" then
			if a1 or a2 or not ready then                -- login, reload, or not settled yet
				ready = false
				C_Timer.After(LOGIN_SETTLE, function() ready = true end)
			end
		elseif event == "BANKFRAME_OPENED" then
			bankOpen = true
		elseif event == "BANKFRAME_CLOSED" then
			bankOpen = false
		elseif event == "BAG_UPDATE_DELAYED" then
			CheckBags()
		elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
			if waiting then
				SendSearch()
				DrawResults()
			end
		elseif event:find("SEARCH_RESULTS", 1, true) then
			OnSearchResults(event, a1)
		else
			OnBuyEvent(event, a1, a2)
		end
	end)
end
