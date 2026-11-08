-- AddonCheck scenario for Mail Ledger's sold-auction tracking (MailLedgerAH.lua).
-- node "D:/Games/World of Warcraft/AddonCheck/check.js" PredUI --scenario PredUI/Tools/checks/auction-sales.lua

local AH = G.C_AuctionHouse
local owned, queried = {}, 0
rawset(AH, "GetOwnedAuctions", function() return owned end)
rawset(AH, "HasFullOwnedAuctionResults", function() return true end)
rawset(AH, "IsThrottledMessageSystemReady", function() return true end)
rawset(AH, "QueryOwnedAuctions", function() queried = queried + 1 end)

local function Char()
	for _, char in pairs(G.PredUIDB.mail.chars) do return char end
end
local function Count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
local function Mail(arg) G.SlashCmdList.PREDUIMAIL(arg) end

-- Opening the AH asks for your auctions.
Fire("AUCTION_HOUSE_SHOW")
Tick(3)
expect(queried == 1, "opening the AH should query owned auctions once, got " .. queried)

owned = {
	{ auctionID = 101, itemLink = "|cffffffff|Hitem:2840::::::::60:::::|h[Copper Bar]|h|r", quantity = 5,
		buyoutAmount = 2000, timeLeftSeconds = 7200, status = 0, itemKey = { itemID = 2840 } },
	{ auctionID = 102, itemKey = { itemID = 2589 }, quantity = 20, buyoutAmount = 50, timeLeft = 3, status = 0 },
	{ auctionID = 103, itemLink = "|cffffffff|Hitem:2592::::::::60:::::|h[Wool Cloth]|h|r", quantity = 1,
		buyoutAmount = 900, timeLeftSeconds = 600, status = 0 },
}
Fire("OWNED_AUCTIONS_UPDATED")
local char = Char()
expect(Count(char.listings) == 3, "3 listings expected, got " .. Count(char.listings))
expect(char.listings[101].price == 10000, "stack price should be unit x count (10000), got " .. tostring(char.listings[101].price))
expect(char.listings[101].name == "Copper Bar", "name from link, got " .. tostring(char.listings[101].name))

-- Live sale without an auction ID: matched by name.
Fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", 4, "Copper Bar", nil)
expect(#char.incoming == 1 and char.incoming[1].price == 10000, "sale with price 10000 expected")
expect(char.listings[101] == nil, "sold listing should be dropped")
-- A repeat of the same sale (sold row on the tab) isn't counted twice.
owned[1].status = 1
Fire("OWNED_AUCTIONS_UPDATED")
expect(#char.incoming == 1, "sold row must not add the sale again, got " .. #char.incoming)

-- Cancelled listings aren't sales; expired ones neither.
Fire("AUCTION_CANCELED", 103)
owned = {}
char.listings[102].minExpires = os.time() + 3600   -- still had time: sold while away
char.listings[104] = { name = "Old", count = 1, price = 5, minExpires = os.time() - 10 } -- ran out
Fire("OWNED_AUCTIONS_UPDATED")
expect(#char.incoming == 2, "one away sale expected (2 total), got " .. #char.incoming)
local away = char.incoming[2]
expect(away and away.away and away.price == 1000, "away sale with price 1000 expected")
expect(Count(char.listings) == 0, "all listings should be cleared")

-- Unknown listing, link as text, and a secret payload.
Fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", 4, "|cffffffff|Hitem:1::::::::60:::::|h[Mystery]|h|r", 999)
expect(#char.incoming == 3 and char.incoming[3].name == "Mystery" and not char.incoming[3].price, "unknown sale without price expected")
Fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", Secret(), Secret(), Secret())
Fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", 5, "Expired thing", nil)
expect(#char.incoming == 3, "secret or non-sale notifications must be ignored")

-- Panel, tooltip lines and commands.
Mail("")
Tick(31)
Mail("sales")
Mail("testsale")
Mail("salechat")
Mail("salechat")
expect(#char.incoming == 4, "testsale should add one")

-- After an hour the mail is in, so an inbox scan clears it.
char.incoming[1].soldAt = os.time() - 4000
Fire("MAIL_INBOX_UPDATE")
Tick(0.5)
expect(#char.incoming == 3, "arrived sale should be cleared on inbox scan, got " .. #char.incoming)

Mail("clearsales")
expect(#char.incoming == 0, "clearsales should empty the list")

-- An alt's sales show on this character, tagged with the alt's name; travelling
-- mail comes before mail that has already arrived; other realms stay out.
local printed = {}
rawset(G, "print", function(line) printed[#printed + 1] = tostring(line) end)
local chars = G.PredUIDB.mail.chars
chars["Bankalt-" .. char.realm] = { name = "Bankalt", realm = char.realm, gold = 0, days = {}, log = {}, incoming = {
	{ item = "Arrived thing", count = 1, price = 1000, soldAt = os.time() - 4000, seen = os.time() },
	{ item = "Coming thing", count = 1, price = 1000, soldAt = os.time() - 60, seen = os.time() },
} }
chars["Other-Elsewhere"] = { name = "Other", realm = "Elsewhere", gold = 0, days = {}, log = {}, incoming = {
	{ item = "Foreign thing", count = 1, price = 1000, soldAt = os.time() - 60, seen = os.time() },
} }
Mail("")
Mail("")
Tick(0.5)
Mail("sales")
local dump = table.concat(printed, "\n")
local coming, arrived = dump:find("Bankalt Coming thing", 1, true), dump:find("Bankalt Arrived thing", 1, true)
expect(coming and arrived and coming < arrived, "alt rows should be tagged, travelling first: " .. dump)
expect(not dump:find("Foreign thing", 1, true), "other realms must stay out: " .. dump)
chars["Bankalt-" .. char.realm], chars["Other-Elsewhere"] = nil, nil
if failures() == 0 then note("sale, away sale, cancel, expiry, secret payload and commands all behaved") end
