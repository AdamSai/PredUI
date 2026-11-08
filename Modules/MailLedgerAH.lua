--------------------------------------------------------------------------------
-- Mail Ledger: sold auctions whose gold hasn't reached the mailbox yet.
--
-- A sold auction leaves the AH's Auctions tab after a few minutes, but its gold
-- only lands in the mailbox an hour after the sale. This file keeps the list
-- in between; MailLedgerUI.lua shows it in the panel and the minimap tooltip.
--
-- How a sale is caught:
-- * Live: AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION (AuctionSold) fires the
--   moment something sells, wherever you are. It only carries the item name
--   (and sometimes the auction ID), so the price comes from our own snapshot
--   of your listings.
-- * Snapshot: whenever the AH sends your owned auctions (OWNED_AUCTIONS_UPDATED;
--   we ask for them when the AH opens and after you post), each listing is
--   saved with its price and how long it had left. Rows marked Sold are sales.
-- * While you were away: the game sends nothing to addons while you're
--   offline. When the AH next shows your auctions, a saved listing that is gone
--   before its time could have run out, and that you didn't cancel, must have
--   sold. When it sold is unknown, but it was before we noticed, so its mail
--   lands by then + 1 hour at the latest.
--
-- Limits: the price is only known for listings PredUI saw at the AH, and the
-- amount shown is after the AH cut (learned from your sale mails, 5% until
-- then) without the deposit you get back. The panel lists every character on
-- the realm, but a character's sales are only caught while it is logged in, so
-- an alt's offline sales appear once that alt next opens the AH.
--------------------------------------------------------------------------------

local _, ns = ...
local L = ns.byKey.mail

local DELIVERY = 3600              -- seconds from sale to mail
local KEEP_ARRIVED = 3 * 86400     -- drop arrived rows nobody collected after this
local DEFAULT_CUT = 0.05
local QUERY_DELAY = 2              -- seconds after opening the AH / posting
local QUERY_TRIES = 4

local SOLD = (Enum.AuctionStatus and Enum.AuctionStatus.Sold) or 1
local NOTIFY_SOLD = (Enum.AuctionHouseNotification and Enum.AuctionHouseNotification.AuctionSold) or 4

-- Shortest time each time-left band can mean (Short, Medium, Long, Very long),
-- for listings that only report a band.
local BAND_MIN = { [0] = 0, [1] = 1800, [2] = 7200, [3] = 43200 }

---------------------------------------------------------------------------
-- Data
---------------------------------------------------------------------------

local function Listings()
	L.char.listings = type(L.char.listings) == "table" and L.char.listings or {}
	return L.char.listings
end

local function Incoming()
	L.char.incoming = type(L.char.incoming) == "table" and L.char.incoming or {}
	return L.char.incoming
end

-- "[Copper Bar]" out of a link, or the text itself.
local function PlainName(text)
	if not text then return nil end
	return text:match("|h%[(.-)%]|h") or text
end

local function ItemName(link, itemKey)
	local name = PlainName(link)
	if name then return name end
	local itemID = type(itemKey) == "table" and ns.PublicNumber(itemKey.itemID)
	if itemID then return ns.PublicString(ns.Try(C_Item.GetItemNameByID, itemID)) end
end

function L.AHCutRate()
	local rate = L.db and tonumber(L.db.ahCutRate)
	if rate and rate >= 0 and rate < 0.5 then return rate end
	return DEFAULT_CUT
end

-- Called by ReadMail for every real sale mail: the invoice has the sale price
-- and the cut, so the rate on this server is learned instead of guessed.
function L.LearnAHCut(price, cut)
	if not (price and cut and price > 0 and cut >= 0) then return end
	local rate = cut / price
	if rate < 0.5 then L.db.ahCutRate = math.floor(rate * 1000 + 0.5) / 1000 end
end

-- When a sale's mail lands. Away sales give the latest it can be.
function L.SaleArrival(sale)
	return (sale.soldAt or sale.seen or time()) + DELIVERY
end

function L.SaleNet(sale)
	if not sale.price then return nil end
	return math.floor(sale.price * (1 - L.AHCutRate()) + 0.5)
end

local function AddSale(id, listing, soldAt, away)
	local incoming = Incoming()
	if id then
		for _, sale in ipairs(incoming) do
			if sale.id == id then return nil end
		end
	end
	local sale = {
		id = id,
		item = listing.link or listing.name or "?",
		name = listing.name,
		count = listing.count,
		price = listing.price,
		soldAt = soldAt,
		seen = time(),
		away = away or nil,
		after = away and listing.checked or nil, -- it sold after this
	}
	incoming[#incoming + 1] = sale
	L.RequestRefresh()
	return sale
end

-- Sorted by arrival. Old arrived rows are dropped here.
function L.IncomingAuctions(char)
	char = char or L.char
	local incoming = type(char and char.incoming) == "table" and char.incoming or {}
	local now, total, list = time(), 0, {}
	for i = #incoming, 1, -1 do
		local sale = incoming[i]
		if L.SaleArrival(sale) + KEEP_ARRIVED < now then
			table.remove(incoming, i)
		else
			list[#list + 1] = sale
			total = total + (L.SaleNet(sale) or 0)
		end
	end
	table.sort(list, function(a, b) return L.SaleArrival(a) < L.SaleArrival(b) end)
	return list, total
end

-- Every character on this realm, as { sale, char } rows. Mail still travelling
-- comes first, soonest on top: an alt's arrived rows stay until that alt opens
-- its mailbox, and shouldn't push the upcoming ones out of the panel's rows.
function L.RealmIncomingAuctions()
	local list, total, now = {}, 0, time()
	for _, char in ipairs(L.RealmCharacters()) do
		local sales, charTotal = L.IncomingAuctions(char)
		total = total + charTotal
		for _, sale in ipairs(sales) do
			list[#list + 1] = { sale = sale, char = char }
		end
	end
	table.sort(list, function(a, b)
		local arrivalA, arrivalB = L.SaleArrival(a.sale), L.SaleArrival(b.sale)
		local arrivedA, arrivedB = arrivalA <= now, arrivalB <= now
		if arrivedA ~= arrivedB then return arrivedB end
		return arrivalA < arrivalB
	end)
	return list, total
end

-- "Name " in class colour for another character's sale, nothing for your own.
function L.SaleOwnerPrefix(row)
	if row.char == L.char then return "" end
	return L.ColoredName(row.char) .. " "
end

-- Called after an inbox scan: sales whose hour is up are in the mailbox now,
-- counted under "Gold to collect".
function L.ClearArrivedSales()
	if not L.char then return end
	local incoming, now, removed = Incoming(), time(), false
	for i = #incoming, 1, -1 do
		if L.SaleArrival(incoming[i]) <= now then
			table.remove(incoming, i)
			removed = true
		end
	end
	if removed then L.RequestRefresh() end
end

---------------------------------------------------------------------------
-- Reading your auctions
---------------------------------------------------------------------------

local function ReadOwnedAuctions()
	if not (L.char and C_AuctionHouse) then return end
	local owned = ns.Try(C_AuctionHouse.GetOwnedAuctions)
	if type(owned) ~= "table" or not ns.Public(owned) then return end
	local listings, now, present = Listings(), time(), {}

	for _, info in ipairs(owned) do
		local id = type(info) == "table" and ns.PublicNumber(info.auctionID)
		if id then
			local listing = listings[id] or {}
			local link = ns.PublicString(info.itemLink)
			local count = ns.PublicNumber(info.quantity) or listing.count or 1
			-- Per unit, like Auctionator reads it.
			local unit = ns.PublicNumber(info.buyoutAmount) or ns.PublicNumber(info.bidAmount)
			listing.link = link or listing.link
			listing.name = ItemName(link, info.itemKey) or listing.name
			listing.count = count
			if unit and unit > 0 then listing.price = unit * count end
			local left = ns.PublicNumber(info.timeLeftSeconds)
			local band = ns.PublicNumber(info.timeLeft)
			if left then
				listing.minExpires = now + left
			elseif band and BAND_MIN[band] then
				listing.minExpires = now + BAND_MIN[band]
			end
			listing.checked = now

			if ns.PublicNumber(info.status) == SOLD then
				-- Sold rows stay on the tab for a few minutes, so "now" is close.
				AddSale(id, listing, now, false)
				listings[id] = nil
			else
				listings[id] = listing
				present[id] = true
			end
		end
	end

	-- Gone without a sale event: sold while you were away, unless its time
	-- could have run out. Only with the full list, or a partial one fakes it.
	if ns.Try(C_AuctionHouse.HasFullOwnedAuctionResults) == false then return end
	for id, listing in pairs(listings) do
		if not present[id] then
			if listing.minExpires and listing.minExpires > now then
				AddSale(id, listing, nil, true)
			end
			listings[id] = nil
		end
	end
	L.RequestRefresh()
end

local queryToken = 0
local function QueryOwned(tries)
	if not (C_AuctionHouse and C_AuctionHouse.QueryOwnedAuctions) then return end
	queryToken = queryToken + 1
	local token = queryToken
	local function Try(left)
		if token ~= queryToken then return end
		if ns.Try(C_AuctionHouse.IsThrottledMessageSystemReady) == false and left > 1 then
			C_Timer.After(QUERY_DELAY, function() Try(left - 1) end)
			return
		end
		ns.Try(C_AuctionHouse.QueryOwnedAuctions, {})
	end
	C_Timer.After(QUERY_DELAY, function() Try(tries or QUERY_TRIES) end)
end

---------------------------------------------------------------------------
-- Events (registered by MailLedger.lua)
---------------------------------------------------------------------------

function L.OnAuctionHouseShow()
	QueryOwned()
end

function L.OnAuctionCreated()
	QueryOwned()
end

function L.OnOwnedAuctionsUpdated()
	ReadOwnedAuctions()
end

function L.OnAuctionCanceled(auctionID)
	local id = ns.PublicNumber(auctionID)
	if id and L.char then Listings()[id] = nil end
end

function L.OnAuctionNotification(notification, text, auctionID)
	if not L.char or ns.PublicNumber(notification) ~= NOTIFY_SOLD then return end
	local listings = Listings()
	local id = ns.PublicNumber(auctionID)
	local name = PlainName(ns.PublicString(text))
	local listing = id and listings[id]
	if not listing and name then
		-- No ID: the listing of that item that runs out first.
		for listingID, candidate in pairs(listings) do
			if candidate.name == name and (not listing or (candidate.minExpires or 0) < (listing.minExpires or 0)) then
				listing, id = candidate, listingID
			end
		end
	end
	listing = listing or { name = name }
	if id then listings[id] = nil end

	local sale = AddSale(id, listing, time(), false)
	if sale and L.Setting("saleChat") then
		local count = (sale.count and sale.count > 1) and (" x" .. sale.count) or ""
		local price = L.SaleNet(sale)
		L.Print(string.format("sold %s%s%s, mail in 60 min.", sale.item, count,
			price and (" for " .. L.Money(price)) or ""))
	end
end

---------------------------------------------------------------------------
-- Commands
---------------------------------------------------------------------------

function L.TestSale()
	if not L.char then return end
	local incoming = Incoming()
	incoming[#incoming + 1] = {
		item = "Test item", name = "Test item", count = 5, price = 125000,
		soldAt = time() - DELIVERY + 60, seen = time(), test = true,
	}
	L.Print("added a test sale, due in 1 min. /mledger clearsales removes it.")
	L.RequestRefresh()
end

function L.ClearSales()
	if not L.char then return end
	L.char.incoming = {}
	L.Print("sold-auction list cleared for " .. L.char.name .. ".")
	L.RequestRefresh()
end

function L.PrintSales()
	local list, total = L.RealmIncomingAuctions()
	if #list == 0 then
		L.Print("no sold auctions on their way.")
		return
	end
	L.Print("sold, mail on its way (" .. L.Money(total) .. "):")
	for _, row in ipairs(list) do
		local sale = row.sale
		local count = (sale.count and sale.count > 1) and (" x" .. sale.count) or ""
		local price = L.SaleNet(sale)
		print(string.format("  %s%s%s: %s, %s", L.SaleOwnerPrefix(row), sale.item, count,
			price and L.Money(price) or "price unknown", L.SaleWhen(sale)))
	end
end

-- "in 42m", "by 14:32" (sold while away), "in the mailbox".
function L.SaleWhen(sale)
	local arrival = L.SaleArrival(sale)
	local remaining = arrival - time()
	if remaining <= 0 then return "in the mailbox" end
	if sale.away then return "by " .. date("%H:%M", arrival) end
	return "in " .. math.max(1, math.ceil(remaining / 60)) .. "m"
end
