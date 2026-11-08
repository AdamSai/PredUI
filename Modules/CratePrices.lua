--------------------------------------------------------------------------------
-- Crate Prices: on Waylaid Crates and other items that take "any bundle from
-- the following list", adds what each bundle would cost on the AH, cheapest
-- first, so you know which one to buy.
--
--   * Hooks item tooltips (TooltipDataProcessor post-call) and reads the
--     tooltip's own lines. Bundle lines look like "- 20 Soul Dust"; a tooltip
--     needs two of them (or one plus "bundle"/"list" in the text) to count.
--   * The tooltip only names the items, and the game has no name -> item ID
--     lookup. We try, in order: names matched before (saved), the game's
--     GetItemInfo(name) (items in your bags or the client's cache), and an
--     index of Auctionator's price list. Auctionator stores prices by item ID
--     only, so the names come from the client: the ones it already has right
--     away, the rest asked from the server in small batches (40 every 0.1 s)
--     only while a crate item is still missing. The tooltip says "looking
--     up..." meanwhile and redraws when the name arrives (GET_ITEM_INFO_RECEIVED).
--     Item tooltips you look at are learned as well.
--   * Prices are Auctionator's (last scan), times the bundle size. With "count
--     what you own" on, items in your bags and bank are taken off the cost.
--   * Without Auctionator the lines still show, with "no AH price".
--------------------------------------------------------------------------------

local _, ns = ...
local PublicNumber, PublicString, Try = ns.PublicNumber, ns.PublicString, ns.Try

local M = ns.NewModule("crates", {
	title = "Crate Prices",
	notes = "On Waylaid Crates and similar, shows what each bundle costs on the AH, cheapest first. Needs Auctionator.",
	defaults = {
		countOwned = true,     -- take items you already have off the cost
		showAge = true,        -- mark prices older than OLD_DAYS
	},
})

local CALLER_ID = "PredUI"
local OLD_DAYS = 3             -- an Auctionator price this many days old gets its age shown
local INDEX_EVERY = 30         -- seconds between rebuilds of the Auctionator name index

local LOAD_BATCH = 40          -- item names asked from the server per step
local LOAD_STEP = 0.1          -- seconds between those steps

local db
local index = {}               -- [lowercase item name] = itemID, this session only
local indexed = {}             -- [itemID] = true once its name is in the index
local indexTime
local queue, queuePos          -- Auctionator item IDs whose names the client doesn't have yet
local loading                  -- ticker while names are being asked for
local searched = false         -- every Auctionator item has been asked for
local asked = {}               -- [itemID] = true while its name is on the way
local wanted = {}              -- [lowercase name] = true: crate items not matched yet
local refreshPending

--------------------------------------------------------------------------------
-- Item names -> IDs
--------------------------------------------------------------------------------

local function Learn(name, id)
	name = PublicString(name)
	id = PublicNumber(id)
	if name and id then index[name:lower()] = id end
end

-- Puts an item's name in the index if the client has it. True when it was
-- a crate item we were looking for.
local function IndexID(id)
	local name = PublicString(Try(C_Item.GetItemNameByID, id))
	if not name then return end
	local key = name:lower()
	index[key] = id
	indexed[id] = true
	if wanted[key] then
		wanted[key] = nil
		db.ids[key] = id
		return true
	end
end

-- Auctionator keeps its prices by item ID, without names; plain IDs are mats
-- and other stackables (gear has "g:" keys). Names the client already has go
-- straight into the index; the rest are queued to be asked for.
local function BuildIndex()
	if indexTime and GetTime() - indexTime < INDEX_EVERY then return end
	indexTime = GetTime()
	local adb = Auctionator and Auctionator.Database and Auctionator.Database.db
	if type(adb) ~= "table" then return end
	queue, queuePos = {}, 1
	pcall(function()
		for key in pairs(adb) do
			local id = type(key) == "string" and tonumber(key:match("^(%d+)$"))
			if id and not indexed[id] then
				if C_Item.IsItemDataCachedByID(id) then IndexID(id) end
				if not indexed[id] then queue[#queue + 1] = id end
			end
		end
	end)
	searched = #queue == 0
end

-- Redraw the tooltip once names came in, so "looking up" turns into prices.
local function QueueRefresh()
	if refreshPending then return end
	refreshPending = true
	C_Timer.After(0.2, function()
		refreshPending = false
		if GameTooltip:IsShown() then
			Try(GameTooltip.RefreshData or GameTooltip.RebuildFromTooltipInfo, GameTooltip)
		end
	end)
end

local function StopLoading()
	if loading then loading:Cancel() end
	loading = nil
end

-- Asks the server for the names of Auctionator's items, a batch at a time,
-- until every crate item is found (or the list runs out). The answers come
-- as GET_ITEM_INFO_RECEIVED.
local function LoadStep()
	if not next(wanted) then
		StopLoading()
		return
	end
	if not queue or queuePos > #queue then
		StopLoading()
		searched = true
		QueueRefresh()
		return
	end
	for _ = 1, LOAD_BATCH do
		local id = queue[queuePos]
		if not id then break end
		queuePos = queuePos + 1
		if not indexed[id] then
			asked[id] = true
			Try(C_Item.RequestLoadItemDataByID, id)
		end
	end
end

local function StartLoading()
	if loading or not next(wanted) then return end
	if not queue or queuePos > #queue then
		BuildIndex()
		if not queue or queuePos > #queue then return end
	end
	searched = false
	loading = C_Timer.NewTicker(LOAD_STEP, LoadStep)
end

local function OnItemInfo(id, success)
	id = PublicNumber(id)
	if not (id and asked[id]) then return end
	asked[id] = nil
	if success and IndexID(id) then QueueRefresh() end
end

local function IDFromLink(link)
	link = PublicString(link)
	return link and tonumber(link:match("item:(%d+)"))
end

local function ItemID(name)
	local key = name:lower()
	local id = db.ids[key] or index[key]
	if not id then
		id = IDFromLink(select(2, Try(C_Item.GetItemInfo, name)))
	end
	if not id then
		BuildIndex()
		id = index[key]
	end
	if id then
		db.ids[key] = id
		wanted[key] = nil
	else
		wanted[key] = true
		StartLoading()
	end
	return id
end

--------------------------------------------------------------------------------
-- Prices
--------------------------------------------------------------------------------

local function Auctionator1()
	return Auctionator and Auctionator.API and Auctionator.API.v1
end

local function PriceOf(id)
	local api = Auctionator1()
	if not (api and api.GetAuctionPriceByItemID) then return end
	return PublicNumber(Try(api.GetAuctionPriceByItemID, CALLER_ID, id))
end

local function AgeOf(id)
	local api = Auctionator1()
	if not (api and api.GetAuctionAgeByItemID) then return end
	return PublicNumber(Try(api.GetAuctionAgeByItemID, CALLER_ID, id))
end

local function Owned(id)
	return PublicNumber(Try(C_Item.GetItemCount, id, true, false, true, true)) or 0
end

local function Coins(copper)
	return C_CurrencyInfo.GetCoinTextureString(math.floor(copper + 0.5), 12)
end

--------------------------------------------------------------------------------
-- Reading the tooltip
--------------------------------------------------------------------------------

-- "- 20 Soul Dust", "- 20x Soul Dust", "- Soul Dust x20", "- Soul Dust (20)"
local function ParseBundle(text)
	local rest = text:match("^%s*%-%s*(.-)%s*$")
	if not rest or rest == "" then return end
	local count, name = rest:match("^(%d+)%s*[xX]?%s+(.+)$")
	if not count then name, count = rest:match("^(.-)%s*[xX(]%s*(%d+)%)?$") end
	count = tonumber(count)
	if count and count > 0 and name and name ~= "" then
		name = name:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
		return count, name
	end
end

-- Bundles from a list of tooltip line texts (lines can hold several "\n" rows).
local function FindBundles(texts)
	local bundles, hint = {}, false
	for _, text in ipairs(texts) do
		for row in text:gmatch("[^\n]+") do
			local count, name = ParseBundle(row)
			if count then
				bundles[#bundles + 1] = { count = count, name = name }
			elseif row:lower():find("bundle") or row:lower():find("following list") then
				hint = true
			end
		end
	end
	if #bundles >= 2 or (#bundles == 1 and hint) then return bundles end
end

--------------------------------------------------------------------------------
-- Adding the costs
--------------------------------------------------------------------------------

local function Cost(bundle)
	bundle.id = ItemID(bundle.name)
	if not bundle.id then return end
	bundle.have = db.countOwned and Owned(bundle.id) or 0
	local need = math.max(0, bundle.count - bundle.have)
	bundle.price = PriceOf(bundle.id)
	if need == 0 then
		bundle.cost = 0
	elseif bundle.price then
		bundle.cost = need * bundle.price
		bundle.age = AgeOf(bundle.id)
	end
end

local function AddCosts(tooltip, bundles)
	for _, b in ipairs(bundles) do Cost(b) end
	table.sort(bundles, function(a, b)
		if (a.cost ~= nil) ~= (b.cost ~= nil) then return a.cost ~= nil end
		if a.cost and a.cost ~= b.cost then return a.cost < b.cost end
		return a.name < b.name
	end)

	tooltip:AddLine(" ")
	tooltip:AddLine("Bundle cost on the AH:", 1, 0.82, 0)
	local cheapest = bundles[1].cost
	for _, b in ipairs(bundles) do
		local left = b.count .. " " .. b.name
		if b.have and b.have > 0 then
			left = left .. (" |cff999999(have %d)|r"):format(b.have)
		end
		local right, r, g, bl
		if not b.id then
			if loading then
				right = "looking up..."
			elseif searched then
				right = "not in Auctionator yet"
			else
				right = "unknown item"
			end
			r, g, bl = 0.6, 0.6, 0.6
		elseif b.cost == 0 then
			right, r, g, bl = "you have them", 0.3, 1, 0.3
		elseif not b.cost then
			right, r, g, bl = "no AH price", 0.6, 0.6, 0.6
		else
			right = Coins(b.cost)
			if db.showAge and b.age and b.age >= OLD_DAYS then
				right = ("|cff999999(%dd old)|r "):format(b.age) .. right
			end
			if b.cost == cheapest then
				r, g, bl = 0.3, 1, 0.3
			else
				r, g, bl = 1, 1, 1
			end
		end
		local lr, lg, lb = 1, 1, 1
		if b.cost and b.cost == cheapest then lr, lg, lb = 0.3, 1, 0.3 end
		tooltip:AddDoubleLine(left, right, lr, lg, lb, r, g, bl)
	end
end

local function OnItemTooltip(tooltip, data)
	if not (M.enabled and tooltip and tooltip.AddDoubleLine and type(data) == "table") then return end
	-- Learn this item's name, so crates can find it later.
	local id = PublicNumber(data.id)
	if id then Learn(Try(C_Item.GetItemNameByID, id), id) end

	local lines = type(data.lines) == "table" and data.lines
	if not lines then return end
	local texts = {}
	for i, line in ipairs(lines) do
		texts[i] = type(line) == "table" and PublicString(line.leftText) or ""
	end
	local bundles = FindBundles(texts)
	if bundles then AddCosts(tooltip, bundles) end
end

--------------------------------------------------------------------------------
-- Slash command and options
--------------------------------------------------------------------------------

local TEST_LINES = {
	"Waylaid Crate: Journeyman Curiosities",
	"Use: Fill the crate with any bundle from the following list:",
	"- 20 Soul Dust\n- 4 Greater Astral Essence\n- 6 Small Glowing Shard\n- 2 Large Glowing Shard",
}

local function Test()
	GameTooltip:SetOwner(UIParent, "ANCHOR_CURSOR")
	GameTooltip:ClearLines()
	for i, text in ipairs(TEST_LINES) do
		if i == 1 then
			GameTooltip:AddLine(text, 1, 1, 1)
		else
			GameTooltip:AddLine(text, 0.1, 1, 0.1, true)
		end
	end
	AddCosts(GameTooltip, FindBundles(TEST_LINES))
	GameTooltip:Show()
	C_Timer.After(8, function()
		if GameTooltip:GetOwner() == UIParent then GameTooltip:Hide() end
	end)
end

local function ListKnown()
	local names = {}
	for name, id in pairs(db.ids) do names[#names + 1] = ("%s = %d"):format(name, id) end
	table.sort(names)
	if #names == 0 then
		M.Say("no items learned yet.")
		return
	end
	M.Say(#names .. " items learned:")
	for _, line in ipairs(names) do print("  " .. line) end
end

local function Forget()
	wipe(db.ids)
	M.Say("learned item names cleared.")
end

local function OnSlash(msg)
	local cmd = msg:lower():match("^%s*(%S*)")
	if cmd == "test" then
		Test()
	elseif cmd == "items" then
		ListKnown()
	elseif cmd == "reset" then
		Forget()
		db.countOwned = nil
		db.showAge = nil
		M.Say("settings reset.")
	elseif cmd == "options" then
		ns.OpenSettings(M)
	else
		M.Say("commands for /crates:")
		print("  test - show a sample Waylaid Crate tooltip with costs")
		print("  items - list the item names it has learned")
		print("  reset - forget learned names, default settings")
		print("  options - open the settings")
		if not ns.HasAuctionator() then print("  Auctionator isn't loaded, so there are no AH prices.") end
	end
end

M.options = {
	{ type = "checkbox", key = "countOwned", label = "Count what you own", tooltip = "Take the items already in your bags and bank off a bundle's cost." },
	{ type = "checkbox", key = "showAge", label = "Show old prices", tooltip = "Mark Auctionator prices that are " .. OLD_DAYS .. " or more days old." },
	{ type = "button", label = "Sample tooltip", button = "Show", tooltip = "Show a Waylaid Crate tooltip with the costs.", func = Test },
	{ type = "button", label = "Learned items", button = "Forget", tooltip = "Clear the item names it has learned (if one was matched wrong).", func = Forget },
}

--------------------------------------------------------------------------------
-- Start-up
--------------------------------------------------------------------------------

function M:Enable()
	db = self.db
	if type(rawget(db, "ids")) ~= "table" then db.ids = {} end
	if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
		TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)
	end
	local api = Auctionator1()
	if api and api.RegisterForDBUpdate then
		-- A new scan can add items: list them again next time one is missing.
		Try(api.RegisterForDBUpdate, CALLER_ID, function()
			indexTime, queue, searched = nil, nil, false
		end)
	end
	local events = CreateFrame("Frame")
	events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
	events:SetScript("OnEvent", function(_, _, id, success) OnItemInfo(id, success) end)
end

SLASH_PREDUICRATES1 = "/crates"
SlashCmdList.PREDUICRATES = ns.SlashHandler(M, OnSlash)
