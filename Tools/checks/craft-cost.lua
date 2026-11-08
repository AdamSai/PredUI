--------------------------------------------------------------------------------
-- AddonCheck scenario for Craft Cost (Modules/CraftCost.lua) and the shopping
-- list in Modules/Notes.lua.
-- node "D:/Games/World of Warcraft/AddonCheck/check.js" PredUI --scenario PredUI/Tools/checks/craft-cost.lua
--
-- Stub recipes for Bronze Bar (2 per craft) from bars from ore, a recipe loop
-- and one with an unpriced reagent, then reads the options the panel offers.
--------------------------------------------------------------------------------

local ORE_C, ORE_T, BAR_C, BAR_T, BRONZE = 2770, 2771, 2840, 3576, 2841
local LOOP_A, LOOP_B, NOPRICE, NEEDS = 100, 101, 102, 103
local NAMES = {
	[ORE_C] = "Copper Ore", [ORE_T] = "Tin Ore", [BAR_C] = "Copper Bar", [BAR_T] = "Tin Bar", [BRONZE] = "Bronze Bar",
	[LOOP_A] = "Loop A", [LOOP_B] = "Loop B", [NOPRICE] = "Unpriced", [NEEDS] = "Needs Unpriced",
}
local PRICES = {
	[ORE_C] = 100, [ORE_T] = 300, [BAR_C] = 500, [BAR_T] = 250, [BRONZE] = 1000,
	[LOOP_A] = 400, [LOOP_B] = 700, [NEEDS] = 900,
}

local function Slot(id, qty)
	return { required = true, quantityRequired = qty, reagents = { { itemID = id } } }
end
local function Recipe(out, low, high, ...)
	return { outputItemID = out, quantityMin = low, quantityMax = high, reagentSlotSchematics = { ... } }
end
local RECIPES = {
	[1] = Recipe(BRONZE, 2, 2, Slot(BAR_C, 1), Slot(BAR_T, 1)),
	[2] = Recipe(BAR_C, 1, 1, Slot(ORE_C, 1)),
	[3] = Recipe(BAR_T, 1, 1, Slot(ORE_T, 1)),
	[4] = Recipe(LOOP_A, 1, 1, Slot(LOOP_B, 1)),
	[5] = Recipe(LOOP_B, 1, 1, Slot(LOOP_A, 1)),
	[6] = Recipe(NEEDS, 1, 1, Slot(NOPRICE, 1)),
}

rawset(G, "Auctionator", { API = { v1 = {
	GetAuctionPriceByItemID = function(_, id) return PRICES[id] end,
	GetAuctionAgeByItemID = function() return 0 end,
	GetAuctionPriceByItemLink = function() return nil end,
} } })
rawset(G.C_Item, "GetItemNameByID", function(id) return NAMES[id] end)
rawset(G.C_Item, "GetItemCount", function() return 0 end)   -- empty bags until the bag tests
rawset(G.C_CurrencyInfo, "GetCoinTextureString", function(c) return c .. "c" end)
rawset(G.C_TradeSkillUI, "GetAllRecipeIDs", function() return { 1, 2, 3, 4, 5, 6 } end)
rawset(G.C_TradeSkillUI, "GetRecipeInfo", function() return { learned = true } end)
rawset(G.C_TradeSkillUI, "GetRecipeSchematic", function(id) return RECIPES[id] end)
rawset(G.C_TradeSkillUI, "GetBaseProfessionInfo", function() return { professionName = "Mining" } end)
rawset(G.C_TradeSkillUI, "IsTradeSkillLinked", function() return false end)
rawset(G.C_TradeSkillUI, "IsTradeSkillGuild", function() return false end)
rawset(G.C_TradeSkillUI, "IsNPCCrafting", function() return false end)

Fire("TRADE_SKILL_SHOW")
Tick(0.5)
expect(G.PredUICharDB.craftcost.recipes[1] ~= nil, "recipes saved for this character")

local panel = G.PredUICraftCostPanel
expect(panel ~= nil, "panel exists")

local function Find(routes, mode)
	for _, r in ipairs(routes or {}) do
		if r.mode == mode then return r end
	end
end

-- Per bar: buy 1000. Direct: (500 + 250) / 2 = 375. Raw: (100 + 300) / 2 = 200.
-- Best mix: Copper from ore (100), Tin Bar bought (250): 175.
panel.ShowRecipe(1)
local routes = panel.routes
for _, r in ipairs(routes or {}) do note(r.mode .. " " .. tostring(r.cost) .. " " .. r.sig) end
expect(#routes == 4, "four options, got " .. #routes)
expect(Find(routes, "buy").cost == 1000, "buy price")
expect(Find(routes, "direct").cost == 375, "from bars, 2 per craft")
expect(Find(routes, "raw").cost == 200, "from ore")
expect(Find(routes, "best").cost == 175, "mixed best: copper ore + tin bar")
expect(Find(routes, "best").cheapest, "the mix is marked cheapest")
expect(not Find(routes, "buy").cheapest, "buy isn't marked")

-- A loop must finish and not make anything free.
panel.ShowRecipe(4)
expect(panel.routes and #panel.routes >= 1, "loop recipe finishes")
for _, r in ipairs(panel.routes) do
	expect(r.cost and r.cost > 0, "loop route has a real cost, mode " .. r.mode)
end

-- A material with no price leaves the option unknown, not free.
panel.ShowRecipe(6)
local direct = Find(panel.routes, "direct")
expect(direct and direct.cost == nil and direct.missing == NOPRICE, "unpriced reagent means unknown cost")

-- Shopping list: 3 Bronze Bars from bars rounds up to 2 crafts (2 Copper, 2 Tin).
panel.ShowRecipe(1)
local index
for i, r in ipairs(panel.routes) do
	if r.mode == "direct" then index = i end
end
panel.AddRoute(index, 3)
local noteID = G.PredUICharDB.craftcost.shoppingNote
expect(noteID ~= nil, "shopping note remembered")
local list = G.PredUIDB.notes.list[noteID]
local function Lines()
	local t = {}
	for _, item in ipairs(list.items) do t[#t + 1] = item.text end
	table.sort(t)
	return table.concat(t, " / ")
end
note(list.title .. ": " .. Lines())
expect(Lines() == "2 x #[Copper Bar] / 2 x #[Tin Bar]", "rounded up to whole crafts -> " .. Lines())
expect(list.tags["i:Tin Bar"] == BAR_T, "item tag saved")
expect(list.pinned, "note is pinned")
expect(list.title:find("15s", 1, true), "title has the total -> " .. list.title)

-- Adding again merges, and unticks.
list.items[1].done = true
panel.AddRoute(index, 2)
expect(#list.items == 2, "no duplicate lines")
expect(Lines() == "3 x #[Copper Bar] / 3 x #[Tin Bar]", "quantities raised -> " .. Lines())
expect(not list.items[1].done, "merged line is unticked")
expect(G.PredUICharDB.craftcost.shoppingNote == noteID, "same note used")

-- The note was deleted: a new one is made.
G.PredUIDB.notes.list[noteID] = nil
panel.AddRoute(index, 2)
expect(G.PredUICharDB.craftcost.shoppingNote ~= noteID, "new note after the old one is deleted")

-- Following the bags. 4 Bronze Bars from bars = 2 crafts: 2 Copper Bar, 2 Tin Bar on a fresh list.
local BAGS = { [BAR_C] = 5, [BAR_T] = 0 }
rawset(G.C_Item, "GetItemCount", function(id) return BAGS[id] or 0 end)
G.PredUIDB.craftcost.useBags = false           -- these amounts ignore bags; tested after
local cursor = nil
rawset(G, "GetCursorInfo", function() return cursor end)
Tick(4)                                        -- past the settling time after login
G.PredUIDB.notes.list[G.PredUICharDB.craftcost.shoppingNote] = nil
panel.AddRoute(index, 8)                       -- 4 crafts: 4 Copper Bar, 4 Tin Bar
list = G.PredUIDB.notes.list[G.PredUICharDB.craftcost.shoppingNote]
Fire("BAG_UPDATE_DELAYED")
expect(Lines() == "4 x #[Copper Bar] / 4 x #[Tin Bar]", "what you hold isn't deducted -> " .. Lines())

BAGS[BAR_C] = 6
Fire("BAG_UPDATE_DELAYED")
expect(Lines() == "3 x #[Copper Bar] / 4 x #[Tin Bar]", "a gain comes off the line -> " .. Lines())

BAGS[BAR_C] = 2
Fire("BAG_UPDATE_DELAYED")
expect(Lines() == "3 x #[Copper Bar] / 4 x #[Tin Bar]", "using materials doesn't add back -> " .. Lines())

BAGS[BAR_C] = 3
Fire("BANKFRAME_OPENED")
Fire("BAG_UPDATE_DELAYED")
Fire("BANKFRAME_CLOSED")
expect(Lines() == "3 x #[Copper Bar] / 4 x #[Tin Bar]", "no deduction while the bank is open -> " .. Lines())

cursor = "item"
BAGS[BAR_C] = 4
Fire("BAG_UPDATE_DELAYED")
expect(Lines() == "3 x #[Copper Bar] / 4 x #[Tin Bar]", "waits while an item is on the cursor -> " .. Lines())
BAGS[BAR_C] = 3                                -- put back where it was
cursor = nil
Fire("BAG_UPDATE_DELAYED")
expect(Lines() == "3 x #[Copper Bar] / 4 x #[Tin Bar]", "dropping the stack isn't a gain -> " .. Lines())

Fire("PLAYER_ENTERING_WORLD", false, true)     -- a reload: bags still filling
BAGS[BAR_C] = 9
Fire("BAG_UPDATE_DELAYED")
expect(Lines() == "3 x #[Copper Bar] / 4 x #[Tin Bar]", "no deduction just after a reload -> " .. Lines())
Tick(4)

BAGS[BAR_T] = 10
Fire("BAG_UPDATE_DELAYED")
local tin
for _, item in ipairs(list.items) do
	if item.text:find("Tin Bar", 1, true) then tin = item end
end
expect(tin.done and tin.bought, "line is ticked when all bought")

BAGS[BAR_T] = 12
Fire("BAG_UPDATE_DELAYED")
expect(tin.text == "4 x #[Tin Bar]", "a finished line is left alone -> " .. tin.text)

panel.AddRoute(index, 2)                       -- 1 craft: 1 of each
expect(tin.text == "1 x #[Tin Bar]" and not tin.done, "a bought line restarts when added again -> " .. tin.text)

-- Using what's in the bags. 4 Bronze Bars = 2 crafts: 2 Copper Bar, 2 Tin Bar.
G.PredUIDB.craftcost.useBags = true
BAGS[BAR_C], BAGS[BAR_T], BAGS[ORE_T] = 2, 0, 0
panel.amount = 4
panel.ShowRecipe(1)
expect(Find(panel.routes, "buy").cost == 4000, "the item itself is still bought in full")
expect(Find(panel.routes, "direct").cost == 500, "owned Copper Bars cost nothing -> " .. tostring(Find(panel.routes, "direct").cost))
expect(Find(panel.routes, "raw").cost == 600, "owned bars are used before any ore -> " .. tostring(Find(panel.routes, "raw").cost))
expect(#panel.routes == 4, "holding items doesn't merge the options")

G.PredUIDB.notes.list[G.PredUICharDB.craftcost.shoppingNote] = nil
for i, r in ipairs(panel.routes) do
	if r.mode == "direct" then index = i end
end
panel.AddRoute(index, 4)
list = G.PredUIDB.notes.list[G.PredUICharDB.craftcost.shoppingNote]
expect(Lines() == "2 x #[Tin Bar]", "the list only has what's still needed -> " .. Lines())

BAGS[BAR_T] = 2
panel.ShowRecipe(1)
expect(Find(panel.routes, "direct").cost == 0, "all in bags costs nothing")
local before = #list.items
local noteBefore = G.PredUICharDB.craftcost.shoppingNote
panel.AddRoute(index, 4)
expect(#list.items == before and G.PredUICharDB.craftcost.shoppingNote == noteBefore, "nothing added when bags have it all")

G.PredUIDB.craftcost.useBags = false
panel.ShowRecipe(1)
expect(Find(panel.routes, "direct").cost == 1500, "setting off: market price for all -> " .. tostring(Find(panel.routes, "direct").cost))
panel.amount = 1
G.PredUIDB.craftcost.useBags = true

-- The Auction House window arrives later (load on demand).
local ah = G.CreateFrame("Frame", "AuctionHouseFrame", G.UIParent)
rawset(G, "AuctionHouseFrame", ah)
Fire("ADDON_LOADED", "Blizzard_AuctionHouseUI")
local ahPanel = G.PredUIShoppingPanel
expect(ahPanel ~= nil, "shopping panel built over the AH")
expect(G.PredUIShoppingTab ~= nil, "shopping tab exists")

-- Finding tabs other addons made, which aren't children of the window.
local hooks = {}
local function FakeButton(label, x, y, extra)
	local b = {
		GetObjectType = function() return "Button" end,
		IsVisible = function() return true end,
		GetCenter = function() return x, y end,
		GetLeft = function() return x - 30 end,
		GetRight = function() return x + 30 end,
		GetText = function() return label end,
		GetParent = function() return nil end,
		IsEnabled = function() return true end,
		IsForbidden = function() return false end,
		HookScript = function(self, _, fn) hooks[label] = fn end,
	}
	for k, v in pairs(extra or {}) do b[k] = v end
	return b
end
local ACTIVE = { IsShown = function() return true end }
local INACTIVE = { IsShown = function() return false end }
local buyTab = FakeButton("Buy", 100, 50, { LeftActive = INACTIVE })
rawset(ah, "BuyTab", buyTab)
local others = {
	buyTab,
	FakeButton("Shopping", 300, 50, { LeftActive = INACTIVE }),
	FakeButton("Cancelling", 500, 52, { LeftActive = ACTIVE }),
	FakeButton("Attack", 400, 20, { LeftActive = INACTIVE }),   -- an action bar button, lower down
	FakeButton("Far away", 600, 50),                            -- level with the tabs, but not a tab
	FakeButton("Secret aura", 350, 50, { LeftActive = INACTIVE, IsVisible = function() return Secret() end }),
	FakeButton("Forbidden", 360, 50, { LeftActive = INACTIVE, IsForbidden = function() error("forbidden") end }),
	FakeButton("Late tab", 700, 50, { LeftActive = INACTIVE }),  -- must still be found after the two above
}
rawset(G, "EnumerateFrames", function(current)
	if current == nil then return others[1] end
	for i, f in ipairs(others) do
		if f == current then return others[i + 1] end
	end
end)
local row = ahPanel.TabRow()
local names = {}
for _, t in ipairs(row) do names[#names + 1] = t:GetText() end
table.sort(names)
expect(table.concat(names, ",") == "Buy,Cancelling,Late tab,Shopping", "finds other addons' tabs, skips secret and forbidden frames -> " .. table.concat(names, ","))
ahPanel.PlaceTab()
expect(hooks.Cancelling ~= nil, "another addon's tab closes our panel too")

ahPanel.OpenTab()
ahPanel:Show()

-- Searching from the panel. Commodities for Tin Bar, single auctions for Copper Ore.
local ready, sent = true, {}
local COMMODITY = { [BAR_T] = { { unitPrice = 300, quantity = 5 }, { unitPrice = 100, quantity = 1 } } }
local AUCTIONS = { [ORE_C] = { { buyoutAmount = 700, quantity = 1 }, { quantity = 1 }, { buyoutAmount = 500, quantity = 2 } } }
local AH = G.C_AuctionHouse
rawset(AH, "IsThrottledMessageSystemReady", function() return ready end)
rawset(AH, "MakeItemKey", function(id) return { itemID = id } end)
rawset(AH, "GetItemKeyInfo", function() return { isEquipment = false } end)
rawset(AH, "SendSearchQuery", function(key) sent[#sent + 1] = key.itemID end)
rawset(AH, "GetNumCommoditySearchResults", function(id) return COMMODITY[id] and #COMMODITY[id] or 0 end)
rawset(AH, "GetCommoditySearchResultInfo", function(id, i) return COMMODITY[id][i] end)
rawset(AH, "GetNumItemSearchResults", function(key) return AUCTIONS[key.itemID] and #AUCTIONS[key.itemID] or 0 end)
rawset(AH, "GetItemSearchResultInfo", function(key, i) return AUCTIONS[key.itemID][i] end)
rawset(AH, "HasFullCommoditySearchResults", function() return true end)
rawset(AH, "HasFullItemSearchResults", function() return true end)

ahPanel.Select({ id = BAR_T, name = "Tin Bar", qty = 2, done = false })
expect(sent[#sent] == BAR_T, "clicking an item searches for it")
Fire("COMMODITY_SEARCH_RESULTS_UPDATED", ORE_C)
expect(#ahPanel.results == 0, "another item's results are ignored")
Fire("COMMODITY_SEARCH_RESULTS_UPDATED", BAR_T)
expect(#ahPanel.results == 2 and ahPanel.results[1].price == 100, "commodity results shown, cheapest first")
expect(ahPanel.summaryText:find("Cheapest 2: ~400c", 1, true), "cheapest cost walks up the prices -> " .. ahPanel.summaryText)

ahPanel.Select({ id = ORE_C, name = "Copper Ore", qty = 9, done = false })
expect(#ahPanel.results == 0, "old results are cleared on a new search")
Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = ORE_C })
expect(#ahPanel.results == 2 and ahPanel.results[1].price == 500, "single auctions shown, ones with no buyout left out")
expect(ahPanel.summaryText:find("Only 3 on sale", 1, true), "says when there aren't enough -> " .. ahPanel.summaryText)

ready = false
local before2 = #sent
ahPanel.Select({ id = BAR_T, name = "Tin Bar", qty = 2, done = false })
expect(#sent == before2, "waits while the AH is throttled")
ready = true
Fire("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
expect(#sent == before2 + 1, "searches once the AH is ready")

ahPanel.Select({ id = 999, name = "Nothing", qty = 1, done = false })
Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 999 })
expect(#ahPanel.results == 0, "no auctions found")

-- Buying.
local calls = {}
local function Record(name)
	return function(...) calls[#calls + 1] = { name, ... } end
end
local function Last() return calls[#calls] or {} end
local money = 100000
rawset(G, "GetMoney", function() return money end)
rawset(AH, "StartCommoditiesPurchase", Record("start"))
rawset(AH, "ConfirmCommoditiesPurchase", Record("confirm"))
rawset(AH, "CancelCommoditiesPurchase", Record("cancel"))
rawset(AH, "PlaceBid", Record("bid"))
rawset(AH, "GetQuoteDurationRemaining", function() return 30 end)

COMMODITY[BAR_T] = { { unitPrice = 100, quantity = 1 }, { unitPrice = 300, quantity = 5, numOwnerItems = 2 } }
ahPanel.Select({ id = BAR_T, name = "Tin Bar", qty = 2, done = false })
Fire("COMMODITY_SEARCH_RESULTS_UPDATED", BAR_T)
expect(ahPanel.results[2].qty == 3, "your own stacks aren't counted as available")

ahPanel.StartCommodityBuy()
expect(Last()[1] == "start" and Last()[2] == BAR_T and Last()[3] == 2, "asks the game for a price")
ahPanel.ConfirmBuy()
expect(Last()[1] == "start", "can't confirm before there's a price")
Fire("COMMODITY_PRICE_UPDATED", 200, 450)
expect(ahPanel.GetBuy().total == 450, "the box uses the game's price, not the list's")
expect(Last()[1] == "start", "nothing bought until confirmed")
ahPanel.ConfirmBuy()
expect(Last()[1] == "confirm" and Last()[3] == 2, "confirming buys it")
local searchesBefore = #sent
local callsBefore = #calls
Fire("COMMODITY_PURCHASE_SUCCEEDED")
expect(ahPanel.GetBuy() == nil, "box closes after buying")
expect(#calls == callsBefore, "nothing to cancel after a purchase went through")
expect(#sent == searchesBefore, "the refresh waits for the purchase to settle")
Tick(1.5)
expect(#sent == searchesBefore + 1, "results refresh after buying")

-- More pages only when asked for, never by themselves.
local more = 0
rawset(AH, "HasFullCommoditySearchResults", function() return false end)
rawset(AH, "RequestMoreCommoditySearchResults", function() more = more + 1 end)
Fire("COMMODITY_SEARCH_RESULTS_UPDATED", BAR_T)
expect(more == 0, "reading results doesn't ask for another page")
ahPanel.RequestMore()
ahPanel.RequestMore()
expect(more == 1, "one page at a time")
rawset(AH, "HasFullCommoditySearchResults", function() return true end)
Fire("COMMODITY_SEARCH_RESULTS_UPDATED", BAR_T)

-- Commodity searches send no sort order, like Blizzard's.
local lastSorts
rawset(AH, "SendSearchQuery", function(key, sorts) sent[#sent + 1] = key.itemID; lastSorts = sorts end)
rawset(AH, "GetItemKeyInfo", function() return { isCommodity = true } end)
ahPanel.Select({ id = BAR_T, name = "Tin Bar", qty = 2, done = false })
expect(lastSorts and #lastSorts == 0, "commodity search has no sorts")
rawset(AH, "GetItemKeyInfo", function() return { isCommodity = false } end)
ahPanel.Select({ id = BAR_T, name = "Tin Bar", qty = 2, done = false })
expect(lastSorts and #lastSorts == 2, "single-auction search is sorted by buyout")
Fire("COMMODITY_SEARCH_RESULTS_UPDATED", BAR_T)

ahPanel.StartCommodityBuy()
Fire("COMMODITY_PRICE_UPDATED", 200, 450)
ahPanel.CancelBuy()
expect(Last()[1] == "cancel" and ahPanel.GetBuy() == nil, "cancel tells the game")

ahPanel.StartCommodityBuy()
money = 100
Fire("COMMODITY_PRICE_UPDATED", 200, 450)
local before3 = #calls
money = 100000
Fire("COMMODITY_PRICE_UNAVAILABLE")
expect(ahPanel.GetBuy() == nil and #calls == before3 + 1 and Last()[1] == "cancel", "an unavailable price closes the box")

-- Choosing how many. On sale: 1 + 3 of yours left out = 4; the list needs 2.
ahPanel.SetBuyAmount(3)
ahPanel.StartCommodityBuy()
expect(Last()[1] == "start" and Last()[3] == 3, "buys the amount typed")
ahPanel.CancelBuy()
ahPanel.SetBuyAmount(50)
expect(ahPanel.summaryText:find("Only 4 on sale", 1, true), "says when there aren't that many -> " .. ahPanel.summaryText)
ahPanel.StartCommodityBuy()
expect(Last()[1] == "start" and Last()[3] == 4, "capped at what's on sale")
ahPanel.CancelBuy()
ahPanel.SetBuyAmount(nil)
ahPanel.StartCommodityBuy()
expect(Last()[1] == "start" and Last()[3] == 2, "empty box follows the list")
ahPanel.CancelBuy()

ahPanel.StartItemBuy({ auctionID = 77, buyout = 1234, qty = 1, name = "Ring", own = true })
expect(ahPanel.GetBuy() == nil, "can't buy your own auction")
ahPanel.StartItemBuy({ auctionID = 77, buyout = 1234, qty = 1, name = "Ring" })
expect(ahPanel.GetBuy().total == 1234 and Last()[1] ~= "bid", "single auction waits for confirmation")
ahPanel.ConfirmBuy()
expect(Last()[1] == "bid" and Last()[2] == 77 and Last()[3] == 1234, "bids the exact buyout")
Fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 5)
expect(ahPanel.GetBuy() ~= nil, "another auction's purchase is ignored")
Fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 77)
expect(ahPanel.GetBuy() == nil, "finishes on its own auction")

ahPanel.StartItemBuy({ auctionID = 78, buyout = 500, qty = 1, name = "Ring" })
ahPanel.ConfirmBuy()
Fire("AUCTION_HOUSE_SHOW_ERROR", 1)
expect(ahPanel.GetBuy() == nil, "an error closes the box")

-- The Flipping window. BAGS still holds items: costs must ignore them.
RECIPES[7] = Recipe(BAR_C, 1, 1, Slot(ORE_T, 10))   -- a much dearer second recipe for Copper Bar
rawset(G.C_TradeSkillUI, "GetAllRecipeIDs", function() return { 1, 2, 3, 4, 5, 6, 7 } end)
Fire("TRADE_SKILL_SHOW")
Tick(0.5)

local flip = G.PredUIFlipWindow
expect(flip ~= nil, "flipping window exists")
local function Row(id)
	for _, d in ipairs(flip.data) do
		if d.id == id then return d end
	end
end
flip.SetSort("profit")
flip.SetLosses(false)
for _, d in ipairs(flip.data) do note(d.name .. " cost " .. d.cost .. " sell " .. d.sell .. " profit " .. d.profit) end

-- Bronze: Copper Bar crafted from ore (100), Tin Bar bought (250), 2 per craft = 175.
-- Sells 1000, 950 after a 5% cut, 775 profit.
local bronze = Row(BRONZE)
expect(bronze and bronze.cost == 175, "cost uses crafted reagents, ignoring bags -> " .. tostring(bronze and bronze.cost))
expect(bronze and bronze.profit == 775, "profit is after the AH cut -> " .. tostring(bronze and bronze.profit))
expect(flip.data[1].id == BRONZE, "biggest profit first")
expect(Row(BAR_C) and Row(BAR_C).cost == 100, "the cheapest of two recipes is used")
expect(Row(BAR_T) == nil, "losses are hidden")
expect(Row(NEEDS) == nil, "an item with an unpriced material is left out")
expect(flip.footerText:find("1 can't be priced", 1, true), "and counted -> " .. flip.footerText)

flip.SetLosses(true)
expect(Row(BAR_T) and Row(BAR_T).profit < 0, "losses show when asked")
flip.SetSort("percent")
expect(flip.data[1].percent >= flip.data[#flip.data].percent, "sorts by percent")
flip.SetLosses(false)
flip.SetSort("profit")

-- Showing and hiding the panel.
local wasShown = G.PredUIDB.craftcost.showPanel
G.SlashCmdList.PREDUICRAFTCOST("toggle")
expect(G.PredUIDB.craftcost.showPanel == not wasShown, "toggle flips the setting")
G.SlashCmdList.PREDUICRAFTCOST("toggle")
expect(G.PredUIDB.craftcost.showPanel == wasShown, "toggle flips it back")

G.SlashCmdList.PREDUICRAFTCOST("test")
expect(panel.routes and #panel.routes >= 2, "preview works")
