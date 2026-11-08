--------------------------------------------------------------------------------
-- Craft Cost: is it cheaper to buy something, or to buy the materials and make
-- it yourself? Shown beside the Professions window for the selected recipe,
-- with a button to put any option on a Notes shopping list.
--
--   * Recipes can only be read while a profession window is open, so each one
--     is saved for this character when its profession is opened. Mining's
--     Smelt Bronze can then be used from any other profession.
--   * Prices are Auctionator's last scan. Vendors give no price list either,
--     so prices are noted down (account-wide) whenever a vendor window opens.
--     Only vendors with unlimited stock and plain gold prices count.
--   * Materials in your bags are used first, at every step (Copper Bars you
--     hold before any ore), so the cost is what you still have to pay for the
--     Amount. The item being made isn't taken from bags: Amount means how many
--     more you want. "Use items in my bags" off counts everything at market price.
--   * Best prices are found by going over every recipe repeatedly until
--     nothing gets cheaper, which also copes with loops such as transmutes.
--   * Options listed: buy it, make it from bought direct reagents, make it all
--     the way from raw materials, and the cheapest mix if that's different.
--   * A material with no price leaves that option unknown, never free.
--   * Costs are per item. Random-yield recipes use their average.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.Style
local Public, PublicNumber, PublicString, Try = ns.Public, ns.PublicNumber, ns.PublicString, ns.Try

local M = ns.NewModule("craftcost", {
	title = "Craft Cost",
	notes = "Shows whether buying an item or crafting it from materials is cheaper beside the Professions window, and builds a shopping list.",
	-- panelX/Y: the panel's top left, measured from the Professions window's top
	-- right. The default clears the profession tabs down that side.
	defaults = { showPanel = true, useBags = true, panelX = 58, panelY = 0 },
})

local CALLER_ID = "PredUI"
local PANEL_W = 340
local ROW_H, HEADER_H, FOOTER_H = 24, 40, 34
local MAX_ROWS = 4
local MAX_PASSES = 12          -- longest crafting chain followed when finding best prices
local STALE_DAYS = 3           -- an AH price older than this gets flagged
local MAX_AMOUNT = 9999

local db, charDB
local panel, page
local best                     -- [itemID] = { cost, recipe } (recipe nil: buy it), nil when out of date
local byOutput                 -- [itemID] = list of recipes making it
local currentRecipeID
local fake                     -- /craftcost test data, or nil

--------------------------------------------------------------------------------
-- Prices
--------------------------------------------------------------------------------

local function Auctionator1()
	return Auctionator and Auctionator.API and Auctionator.API.v1
end

local function AuctionPrice(id)
	if fake then return fake.prices[id] end
	local api = Auctionator1()
	if not (api and api.GetAuctionPriceByItemID) then return end
	return PublicNumber(Try(api.GetAuctionPriceByItemID, CALLER_ID, id))
end

local function AuctionAge(id)
	if fake then return fake.ages[id] end
	local api = Auctionator1()
	if not (api and api.GetAuctionAgeByItemID) then return end
	return PublicNumber(Try(api.GetAuctionAgeByItemID, CALLER_ID, id))
end

local function VendorPrice(id)
	if fake then return nil end
	return db.vendor[id]
end

-- Price of one, and whether that's the vendor's price.
local function BuyPrice(id)
	local ah, vendor = AuctionPrice(id), VendorPrice(id)
	if vendor and (not ah or vendor <= ah) then return vendor, true end
	return ah, false
end

local function Coins(copper)
	return C_CurrencyInfo.GetCoinTextureString(math.floor(copper + 0.5), 12)
end

local function ItemName(id)
	if fake then return fake.names[id] end
	local name = PublicString(Try(C_Item.GetItemNameByID, id))
	if not name then Try(C_Item.RequestLoadItemDataByID, id) end
	return name
end

--------------------------------------------------------------------------------
-- Recipes
--------------------------------------------------------------------------------

local function Recipes()
	return fake and fake.recipes or charDB.recipes
end

-- What we need from a recipe: { out, yield, reagents = { { id, qty }... } }.
-- nil for recipes that don't make an item or cost something other than items.
local function ReadRecipe(recipeID)
	local s = Try(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
	if not (Public(s) and type(s) == "table") then return end
	local out = PublicNumber(s.outputItemID)
	if not (out and type(s.reagentSlotSchematics) == "table") then return end
	local low, high = PublicNumber(s.quantityMin) or 1, PublicNumber(s.quantityMax) or 1
	local recipe = { out = out, yield = math.max((low + high) / 2, 1), reagents = {} }
	for _, slot in ipairs(s.reagentSlotSchematics) do
		if slot.required then
			local first = slot.reagents and slot.reagents[1]
			local id = first and PublicNumber(first.itemID)
			local qty = PublicNumber(slot.quantityRequired)
			if not (id and qty) then return end     -- costs a currency: can't be priced
			recipe.reagents[#recipe.reagents + 1] = { id = id, qty = qty }
		end
	end
	if #recipe.reagents == 0 then return end
	return recipe
end

local function Invalidate()
	best, byOutput = nil, nil
end

local function ScanProfession()
	if Try(C_TradeSkillUI.IsTradeSkillLinked) or Try(C_TradeSkillUI.IsTradeSkillGuild) or Try(C_TradeSkillUI.IsNPCCrafting) then
		return                                      -- someone else's recipes
	end
	local ids = Try(C_TradeSkillUI.GetAllRecipeIDs) or Try(C_TradeSkillUI.GetFilteredRecipeIDs)
	if not (Public(ids) and type(ids) == "table") then return end
	local changed = false
	for _, id in ipairs(ids) do
		id = PublicNumber(id)
		if id and not charDB.recipes[id] then
			local info = Try(C_TradeSkillUI.GetRecipeInfo, id)
			if Public(info) and type(info) == "table" and info.learned then
				local recipe = ReadRecipe(id)
				if recipe then
					charDB.recipes[id] = recipe
					changed = true
				end
			end
		end
	end
	local prof = Try(C_TradeSkillUI.GetBaseProfessionInfo)
	local name = Public(prof) and type(prof) == "table" and PublicString(prof.professionName)
	if name and not charDB.professions[name] then
		charDB.professions[name] = true
		changed = true
	end
	if changed then Invalidate() end
	return changed
end

local function Rebuild()
	byOutput, best = {}, {}
	local recipes = Recipes()
	local function Seed(id)
		if best[id] == nil then
			local price = BuyPrice(id)
			best[id] = price and { cost = price } or false
		end
	end
	for _, recipe in pairs(recipes) do
		byOutput[recipe.out] = byOutput[recipe.out] or {}
		table.insert(byOutput[recipe.out], recipe)
		Seed(recipe.out)
		for _, r in ipairs(recipe.reagents) do Seed(r.id) end
	end
	for _ = 1, MAX_PASSES do
		local changed = false
		for _, recipe in pairs(recipes) do
			local total = 0
			for _, r in ipairs(recipe.reagents) do
				local b = best[r.id]
				if not b then total = nil break end
				total = total + b.cost * r.qty
			end
			if total then
				local unit, current = total / recipe.yield, best[recipe.out]
				if not current or unit < current.cost - 0.001 then
					best[recipe.out] = { cost = unit, recipe = recipe }
					changed = true
				end
			end
		end
		if not changed then break end
	end
end

local function EnsureBest()
	if not best then Rebuild() end
end

-- Which recipe to use for a reagent, or nil to buy it.
local function ChooseRecipe(id, mode)
	if mode == "direct" then return end
	local b = best[id]
	if b and b.recipe then return b.recipe end
	if mode == "raw" then return byOutput[id] and byOutput[id][1] end
end

-- What the bags can still supply during one calculation.
local function NewPool()
	if not db.useBags then return end
	return { left = {}, used = {} }
end

-- Takes what it can of `need` from the pool; returns what's still needed.
local function TakeFromPool(pool, id, need)
	if not pool then return need end
	local have = pool.left[id]
	if not have then
		have = fake and fake.bags[id] or PublicNumber(Try(C_Item.GetItemCount, id)) or 0
	end
	local taken = math.min(have, need)
	pool.left[id] = have - taken
	if taken > 0 then pool.used[id] = (pool.used[id] or 0) + taken end
	return need - taken
end

-- Adds up the bought materials for `wanted` of what `recipe` makes.
local function Collect(recipe, wanted, mode, whole, mats, path, pool)
	local crafts = wanted / recipe.yield
	if whole then crafts = math.ceil(crafts - 0.000001) end
	for _, r in ipairs(recipe.reagents) do
		local need = TakeFromPool(pool, r.id, r.qty * crafts)
		if need > 0.000001 then
			local sub = not path[r.id] and ChooseRecipe(r.id, mode)
			if sub then
				path[r.id] = true
				Collect(sub, need, mode, whole, mats, path, pool)
				path[r.id] = nil
			else
				mats[r.id] = (mats[r.id] or 0) + need
			end
		end
	end
end

local function RouteMats(route, amount, whole, pool)
	if route.mode == "buy" then return { [route.recipe.out] = amount } end
	local mats = {}
	Collect(route.recipe, amount, route.mode, whole, mats, { [route.recipe.out] = true }, pool)
	return mats
end

local function MatIDs(mats)
	local ids = {}
	for id in pairs(mats) do ids[#ids + 1] = id end
	table.sort(ids)
	return ids
end

local function MakeRoute(recipe, mode)
	local route = { recipe = recipe, mode = mode }
	-- The route's shape ignores bags, so its name and identity don't change
	-- with what you're holding.
	local shape, sig = RouteMats(route, 1, false), {}
	route.shape = MatIDs(shape)
	for _, id in ipairs(route.shape) do
		sig[#sig + 1] = id .. ":" .. shape[id]
	end
	route.sig = table.concat(sig, ",")

	local pool = route.mode ~= "buy" and NewPool() or nil
	route.mats = RouteMats(route, panel.amount, false, pool)
	route.used = pool and pool.used or {}
	route.ids = MatIDs(route.mats)
	local cost = 0
	for _, id in ipairs(route.ids) do
		local price = BuyPrice(id)
		if price then
			if cost then cost = cost + price * route.mats[id] end
		else
			cost = nil
			route.missing = route.missing or id
		end
		if (AuctionAge(id) or 0) > STALE_DAYS then route.stale = true end
	end
	route.cost = cost
	return route
end

-- The options for one recipe: duplicates dropped, the cheapest marked.
local function RoutesFor(recipe)
	EnsureBest()
	local routes, seen = {}, {}
	for _, mode in ipairs({ "buy", "direct", "raw", "best" }) do
		local route = MakeRoute(recipe, mode)
		if not seen[route.sig] then
			seen[route.sig] = true
			routes[#routes + 1] = route
		end
	end
	local cheapest
	for _, route in ipairs(routes) do
		if route.cost and (not cheapest or route.cost < cheapest.cost - 0.001) then cheapest = route end
	end
	if cheapest then cheapest.cheapest = true end
	return routes
end

--------------------------------------------------------------------------------
-- Shopping list
--------------------------------------------------------------------------------

local function PlainPrice(id)
	return (BuyPrice(id))
end

local function AddRoute(route, amount)
	if fake then
		M.Say("this is only a preview, so nothing was added.")
		return
	end
	if not (ns.AddToShoppingList and ns.byKey.notes and ns.byKey.notes.enabled) then
		M.Say("the shopping list needs the Notes module. Turn it on in /predui.")
		return
	end
	local mats = RouteMats(route, amount, true, route.mode ~= "buy" and NewPool() or nil)
	if not next(mats) then
		M.Say("you already have everything for that in your bags.")
		return
	end
	local wanted = {}
	for _, id in ipairs(MatIDs(mats)) do
		local name = ItemName(id)
		if not name then
			M.Say("still loading item names. Try again in a moment.")
			return
		end
		wanted[#wanted + 1] = { id = id, name = name, qty = math.ceil(mats[id] - 0.000001) }
	end
	charDB.shoppingNote = ns.AddToShoppingList(charDB.shoppingNote, wanted, PlainPrice)
	if M.OnListChanged then M.OnListChanged() end
end

M.BuyPrice = PlainPrice
M.Coins = Coins

function M.AddBestRoute(recipe, amount)
	EnsureBest()
	AddRoute({ recipe = recipe, mode = "best" }, amount)
end

-- For the Flipping window: one row per item you can make that has both prices,
-- from its cheapest recipe at market prices. Also returns how many couldn't be priced.
function M.FlipData()
	EnsureBest()
	local mail = ns.byKey.mail
	local cut = mail and PublicNumber(Try(mail.AHCutRate)) or 0.05
	local rows, skipped = {}, 0
	for out, recipes in pairs(byOutput) do
		local sell = AuctionPrice(out)
		local cheapest, cheapestCost, cheapestParts, cheapestStale
		for _, recipe in ipairs(recipes) do
			local total, parts, stale = 0, {}, false
			for _, r in ipairs(recipe.reagents) do
				local b = best[r.id]
				if not b then total = nil break end
				local qty = r.qty / recipe.yield
				total = total + b.cost * qty
				parts[#parts + 1] = { name = ItemName(r.id) or ("Item " .. r.id), qty = qty, cost = b.cost * qty, crafted = b.recipe ~= nil }
				if not b.recipe and (AuctionAge(r.id) or 0) > STALE_DAYS then stale = true end
			end
			if total and (not cheapestCost or total < cheapestCost) then
				cheapest, cheapestCost, cheapestParts, cheapestStale = recipe, total, parts, stale
			end
		end
		if sell and cheapest then
			local net = sell * (1 - cut)
			local profit = net - cheapestCost
			rows[#rows + 1] = {
				id = out, name = ItemName(out) or ("Item " .. out), recipe = cheapest, parts = cheapestParts,
				cost = cheapestCost, sell = sell, net = net, profit = profit,
				percent = cheapestCost > 0 and profit / cheapestCost * 100 or 0,
				stale = cheapestStale or (AuctionAge(out) or 0) > STALE_DAYS,
			}
		else
			skipped = skipped + 1
		end
	end
	return rows, skipped
end

--------------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------------

local function RouteLabel(route)
	if route.mode == "buy" then return "Buy" end
	local names = {}
	for _, id in ipairs(route.shape) do names[#names + 1] = ItemName(id) or ("Item " .. id) end
	return "From " .. table.concat(names, " + ")
end

local function ShowRouteTooltip(row)
	local route = row.route
	if not route then return end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	GameTooltip:SetText(route.mode == "buy" and "Buy it" or "Still to buy")
	if #route.ids == 0 then GameTooltip:AddLine("Nothing: your bags have it all.", 1, 1, 1) end
	for _, id in ipairs(route.ids) do
		local price, vendor = BuyPrice(id)
		local age = AuctionAge(id)
		local right = price and Coins(price * route.mats[id]) or "no price"
		if vendor then
			right = right .. " (vendor)"
		elseif age and age > STALE_DAYS then
			right = right .. (" (%dd old)"):format(age)
		end
		local count = route.mats[id]
		count = count == math.floor(count) and tostring(count) or ("%.2f"):format(count)
		GameTooltip:AddDoubleLine(count .. " x " .. (ItemName(id) or ("Item " .. id)), right, 1, 1, 1, 1, 1, 1)
	end
	for _, id in ipairs(MatIDs(route.used)) do
		local count = route.used[id]
		count = count == math.floor(count) and tostring(count) or ("%.1f"):format(count)
		GameTooltip:AddDoubleLine(count .. " x " .. (ItemName(id) or ("Item " .. id)), "from bags", 0.6, 0.6, 0.6, 0.25, 1, 0.25)
	end
	GameTooltip:Show()
end

local function CreateRow(i)
	local row = CreateFrame("Button", nil, panel)
	row:SetHeight(ROW_H)
	row:SetPoint("TOPLEFT", S.PAD, -HEADER_H - (i - 1) * ROW_H)
	row:SetPoint("TOPRIGHT", -S.PAD, -HEADER_H - (i - 1) * ROW_H)
	S.RowHighlight(row)
	row.add = S.Button(row, "Add", 38, 20)
	row.add:SetPoint("RIGHT")
	row.add.tooltip = "Add this option's materials to your shopping list note, for the amount above."
	row.add:SetScript("OnClick", function()
		if row.route then AddRoute(row.route, panel.amount) end
	end)
	row.cost = S.Text(row, 11)
	row.cost:SetPoint("RIGHT", row.add, "LEFT", -6, 0)
	row.cost:SetJustifyH("RIGHT")
	row.label = S.Text(row, 11)
	row.label:SetPoint("LEFT", 2, 0)
	row.label:SetPoint("RIGHT", row.cost, "LEFT", -6, 0)
	row.label:SetJustifyH("LEFT")
	row:SetScript("OnEnter", ShowRouteTooltip)
	row:SetScript("OnLeave", function() GameTooltip_Hide() end)
	return row
end

local function KnownProfessions()
	local names = {}
	for name in pairs(fake and fake.professions or charDB.professions) do names[#names + 1] = name end
	table.sort(names)
	return table.concat(names, ", ")
end
M.KnownProfessions = KnownProfessions

local function DrawRoutes(recipe)
	local routes = RoutesFor(recipe)
	panel.routes = routes
	panel.title:SetText(S.GOLD .. "Buy or craft|r " .. S.DIM .. "(cost for " .. panel.amount .. ")|r")
	for i = 1, MAX_ROWS do
		local row, route = panel.rows[i], routes[i]
		row.route = route
		if route then
			local color = route.cheapest and S.GOOD or "|cffffffff"
			row.label:SetText(color .. RouteLabel(route) .. "|r")
			if route.cost == 0 then
				row.cost:SetText(S.GOOD .. "in bags|r")
			elseif route.cost then
				row.cost:SetText((route.stale and (S.WARN .. "old|r ") or "") .. "~" .. Coins(route.cost))
			else
				row.cost:SetText(S.DIM .. "no price|r")
			end
			row:Show()
		else
			row:Hide()
		end
	end
	local known = KnownProfessions()
	panel.footer:SetText(S.DIM .. "Using recipes from: " .. (known ~= "" and known or "none yet")
		.. ". Open your other professions to add theirs.|r")
	panel:SetHeight(HEADER_H + #routes * ROW_H + FOOTER_H)
	panel:Show()
end

-- Sets the panel to one recipe; hides it when there's nothing to compare.
function M.ShowRecipe(recipeID)
	if not (panel and db.showPanel and recipeID) then
		if panel then panel:Hide() end
		return
	end
	local recipe = Recipes()[recipeID] or (not fake and ReadRecipe(recipeID)) or nil
	if not recipe then
		panel:Hide()
		return
	end
	DrawRoutes(recipe)
end

local function UpdatePanel()
	if fake or not (panel and page) then return end
	if panel.toggle then panel.toggle.label:SetText(db.showPanel and "Hide costs" or "Show costs") end
	local form = page.SchematicForm
	local info = form and form.GetRecipeInfo and Try(form.GetRecipeInfo, form)
	currentRecipeID = Public(info) and type(info) == "table" and PublicNumber(info.recipeID) or nil
	M.ShowRecipe(currentRecipeID)
end

local refreshPending = false
local function QueueRefresh()
	if refreshPending then return end
	refreshPending = true
	C_Timer.After(0.1, function()
		refreshPending = false
		UpdatePanel()
		if fake and panel:IsShown() then DrawRoutes(fake.recipes[1]) end
	end)
end

-- The title-bar button and /craftcost toggle; the same setting as the options page.
local function TogglePanel()
	db.showPanel = not db.showPanel
	if not db.showPanel then panel:Hide() end
	UpdatePanel()
end

local function Attach()
	panel:SetParent(page)
	panel:ClearAllPoints()
	panel:SetPoint("TOPLEFT", ProfessionsFrame, "TOPRIGHT", db.panelX, db.panelY)
	panel.close:Hide()
end

local function SetUpProfessionsFrame()
	if page or not (panel and ProfessionsFrame and ProfessionsFrame.CraftingPage) then return end
	local candidate = ProfessionsFrame.CraftingPage
	if not candidate.SchematicForm then return end     -- made in the page's OnLoad
	page = candidate
	if not fake then Attach() end
	-- On the page, so it goes away with the panel on the other Professions tabs.
	panel.toggle = S.Button(page, "Hide costs", 76, 18)
	-- Right of the rank bar, in the rank bar's strata: the title bar hid it.
	panel.toggle:SetPoint("TOPRIGHT", ProfessionsFrame, "TOPRIGHT", -12, -44)
	panel.toggle:SetFrameStrata("HIGH")
	panel.toggle.tooltip = "Show or hide the buy or craft panel."
	panel.toggle:SetScript("OnClick", TogglePanel)
	panel.flip = S.Button(page, "Flipping", 62, 18)
	panel.flip:SetPoint("RIGHT", panel.toggle, "LEFT", -4, 0)
	panel.flip:SetFrameStrata("HIGH")
	panel.flip.tooltip = "Open the list of things you can craft and sell at a profit."
	panel.flip:SetScript("OnClick", function() M.ToggleFlip() end)
	-- Runs on recipe selection, bag changes and after each craft starts.
	hooksecurefunc(page, "ValidateControls", UpdatePanel)
	UpdatePanel()
end

local function CreatePanel()
	panel = CreateFrame("Frame", "PredUICraftCostPanel", UIParent)
	panel:SetSize(PANEL_W, HEADER_H + ROW_H + FOOTER_H)
	panel:SetPoint("CENTER")
	panel:Hide()
	S.Body(panel)
	panel.amount = 1
	panel.rows = {}

	-- Dragged by its title or footer (the rows are buttons). The spot is kept
	-- relative to the Professions window, so the panel follows that window.
	panel:SetMovable(true)
	panel:SetClampedToScreen(true)
	panel:EnableMouse(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", function(self)
		if page and not fake then self:StartMoving() end
	end)
	panel:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		if not page or fake then return end
		local left, top, right, frameTop = self:GetLeft(), self:GetTop(), ProfessionsFrame:GetRight(), ProfessionsFrame:GetTop()
		if left and top and right and frameTop then
			db.panelX, db.panelY = math.floor(left - right + 0.5), math.floor(top - frameTop + 0.5)
		end
		Attach()
	end)

	panel.title = S.Text(panel, 12)
	panel.title:SetPoint("TOPLEFT", S.PAD, -10)

	panel.close = S.CloseButton(panel)
	panel.close:SetPoint("TOPRIGHT", -2, -2)
	panel.close:Hide()

	local box = S.EditBox(panel, 52, 20)
	box:SetPoint("TOPRIGHT", -S.PAD - 22, -7)
	box:SetNumeric(true)
	box:SetMaxLetters(4)
	box:SetText("1")
	box:SetJustifyH("CENTER")
	box:SetScript("OnTextChanged", function(self)
		local n = tonumber(self:GetText())
		panel.amount = math.max(1, math.min(MAX_AMOUNT, math.floor(n or 1)))
		if panel:IsShown() then QueueRefresh() end
	end)
	box:SetScript("OnEnterPressed", box.ClearFocus)

	local amount = S.Text(panel, 11)
	amount:SetPoint("RIGHT", box, "LEFT", -6, 0)
	amount:SetText("Amount")

	for i = 1, MAX_ROWS do
		panel.rows[i] = CreateRow(i)
	end

	panel.footer = S.Text(panel, 10)
	panel.footer:SetPoint("BOTTOMLEFT", S.PAD, 7)
	panel.footer:SetPoint("BOTTOMRIGHT", -S.PAD, 7)
	panel.footer:SetJustifyH("LEFT")
	panel.footer:SetWordWrap(true)

	-- For the scenario test: the current options, and what the Add buttons do.
	function panel.AddRoute(i, amt)
		AddRoute(panel.routes[i], amt)
	end
	function panel.ShowRecipe(id)
		M.ShowRecipe(id)
	end

	panel:SetScript("OnHide", function()
		GameTooltip_Hide()
		if fake then
			fake = nil
			Invalidate()
			if page then Attach() end
		end
	end)
end

--------------------------------------------------------------------------------
-- Vendors
--------------------------------------------------------------------------------

local function ScanMerchant()
	local count = PublicNumber(Try(GetMerchantNumItems)) or 0
	local changed = false
	for i = 1, count do
		local info = Try(C_MerchantFrame.GetItemInfo, i)
		local id = PublicNumber(Try(GetMerchantItemID, i))
		if id and Public(info) and type(info) == "table" and not info.hasExtendedCost then
			local price, stack = PublicNumber(info.price), PublicNumber(info.stackCount)
			local available = PublicNumber(info.numAvailable)
			if price and price > 0 and stack and stack > 0 and available and available < 0 then
				local each = price / stack
				if db.vendor[id] ~= each then
					db.vendor[id] = each
					changed = true
				end
			end
		end
	end
	if changed then
		Invalidate()
		QueueRefresh()
	end
end

--------------------------------------------------------------------------------
-- Commands (slash and settings menu)
--------------------------------------------------------------------------------

function M.Test()
	local COPPER_ORE, TIN_ORE, COPPER_BAR, TIN_BAR, BRONZE_BAR = 2770, 2771, 2840, 3576, 2841
	fake = {
		names = { [COPPER_ORE] = "Copper Ore", [TIN_ORE] = "Tin Ore", [COPPER_BAR] = "Copper Bar", [TIN_BAR] = "Tin Bar", [BRONZE_BAR] = "Bronze Bar" },
		prices = { [COPPER_ORE] = 2000, [TIN_ORE] = 6000, [COPPER_BAR] = 3000, [TIN_BAR] = 9000, [BRONZE_BAR] = 12000 },
		ages = { [TIN_BAR] = 5 },
		bags = {},
		professions = { Mining = true },
		recipes = {
			{ out = BRONZE_BAR, yield = 2, reagents = { { id = COPPER_BAR, qty = 1 }, { id = TIN_BAR, qty = 1 } } },
			{ out = COPPER_BAR, yield = 1, reagents = { { id = COPPER_ORE, qty = 1 } } },
			{ out = TIN_BAR, yield = 1, reagents = { { id = TIN_ORE, qty = 1 } } },
		},
	}
	Invalidate()
	panel:SetParent(UIParent)
	panel:ClearAllPoints()
	panel:SetPoint("CENTER")
	panel.close:Show()
	DrawRoutes(fake.recipes[1])
	M.Say("showing made-up Bronze Bar prices. Close it with the x.")
end

function M.ResetPosition()
	db.panelX, db.panelY = nil, nil
	if page and not fake then Attach() end
	M.Say("panel position reset.")
end

function M.Forget()
	ns.Confirm("Forget this character's saved recipes and all noted vendor prices?", function()
		wipe(charDB.recipes)
		wipe(charDB.professions)
		wipe(db.vendor)
		charDB.shoppingNote = nil
		Invalidate()
		UpdatePanel()
		M.Say("forgot saved recipes and vendor prices. Open your professions to read them again.")
	end)
end

local function OnSlash(msg)
	msg = msg:lower():match("^%s*(.-)%s*$")
	if msg == "test" then
		M.Test()
	elseif msg == "reset" then
		M.ResetPosition()
	elseif msg == "forget" then
		M.Forget()
	elseif msg == "toggle" then
		TogglePanel()
		M.Say("panel " .. (db.showPanel and "shown." or "hidden."))
	elseif msg == "options" or msg == "" then
		ns.OpenSettings(M)
	else
		M.Say("Commands:")
		print("  /craftcost - open the settings")
		print("  /craftcost toggle - show or hide the panel")
		print("  /craftcost test - show the panel with made-up prices")
		print("  /craftcost reset - put the panel back in its default place")
		print("  /craftcost forget - forget saved recipes and vendor prices")
	end
end

M.options = {
	{ type = "checkbox", key = "showPanel", label = "Show beside the Professions window", tooltip = "Show the buy or craft comparison for the selected recipe.", onChange = function() UpdatePanel() end },
	{ type = "checkbox", key = "useBags", label = "Use items in my bags", tooltip = "Use materials you're carrying first, so costs and the shopping list only count what you still have to buy. Off: everything counts at market price.", onChange = function() UpdatePanel() end },
	{ type = "button", label = "Preview", button = "Test panel", tooltip = "Show the panel with made-up Bronze Bar prices.", func = function() M.Test() end },
	{ type = "button", label = "Position", button = "Reset", tooltip = "Put the panel back in its default place.", func = function() M.ResetPosition() end },
	{ type = "button", label = "Saved data", button = "Forget", tooltip = "Forget this character's saved recipes and all noted vendor prices.", func = function() M.Forget() end },
}

--------------------------------------------------------------------------------
-- Start-up
--------------------------------------------------------------------------------

function M:OnAddonLoaded()
	SetUpProfessionsFrame()
	if M.SetUpAuctionHouse then M.SetUpAuctionHouse() end
end

function M:Enable()
	db, charDB = self.db, self.charDB
	db.vendor = type(rawget(db, "vendor")) == "table" and db.vendor or {}
	charDB.recipes = type(charDB.recipes) == "table" and charDB.recipes or {}
	charDB.professions = type(charDB.professions) == "table" and charDB.professions or {}

	CreatePanel()
	SetUpProfessionsFrame()
	if M.EnableList then M.EnableList() end
	if M.EnableFlip then M.EnableFlip() end

	local api = Auctionator1()
	if api and api.RegisterForDBUpdate then
		Try(api.RegisterForDBUpdate, CALLER_ID, function()
			Invalidate()
			QueueRefresh()
			if M.RefreshFlip then M.RefreshFlip() end
		end)
	end

	local events = CreateFrame("Frame")
	events:RegisterEvent("TRADE_SKILL_SHOW")
	events:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
	events:RegisterEvent("NEW_RECIPE_LEARNED")
	events:RegisterEvent("MERCHANT_SHOW")
	events:RegisterEvent("MERCHANT_UPDATE")
	events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
	events:RegisterEvent("BAG_UPDATE_DELAYED")
	local scanPending = false
	events:SetScript("OnEvent", function(_, event)
		if event == "MERCHANT_SHOW" or event == "MERCHANT_UPDATE" then
			ScanMerchant()
		elseif event == "GET_ITEM_INFO_RECEIVED" or event == "BAG_UPDATE_DELAYED" then
			if panel:IsShown() then QueueRefresh() end
		elseif not scanPending then
			scanPending = true                      -- these come in bursts
			C_Timer.After(0.2, function()
				scanPending = false
				SetUpProfessionsFrame()
				ScanProfession()
				UpdatePanel()
			end)
		end
	end)
end

SLASH_PREDUICRAFTCOST1 = "/craftcost"
SlashCmdList.PREDUICRAFTCOST = ns.SlashHandler(M, OnSlash)
