--------------------------------------------------------------------------------
-- AddonCheck scenario for Crate Prices (Modules/CratePrices.lua).
-- node "D:/Games/World of Warcraft/AddonCheck/check.js" PredUI --scenario PredUI/Tools/checks/crate-prices.lua
--
-- A fake Auctionator price DB and item cache, then "/crates test", which
-- builds the sample Waylaid Crate tooltip on GameTooltip. Checks the bundles
-- are found, names resolved through the Auctionator index, owned items taken
-- off, and the cheapest bundle listed first.
--------------------------------------------------------------------------------

local NAMES = { [11083] = "Soul Dust", [11082] = "Greater Astral Essence", [11138] = "Small Glowing Shard", [11139] = "Large Glowing Shard" }
local PRICES = { [11083] = 500, [11082] = 1500, [11138] = 900, [11139] = 4000 }   -- copper each
local CACHED = { [11083] = true, [11082] = true, [11138] = true }   -- Large Glowing isn't: its name must be asked for
local requested = {}
local OWNED = { [11138] = 2 }

local dbTable = { ["g:1234:5"] = { m = 1 } }
for id in pairs(NAMES) do dbTable[tostring(id)] = { m = PRICES[id] } end

rawset(G, "Auctionator", {
	Database = { db = dbTable },
	API = { v1 = {
		GetAuctionPriceByItemID = function(_, id) return PRICES[id] end,
		GetAuctionAgeByItemID = function(_, id) return id == 11082 and 5 or 0 end,
		GetAuctionPriceByItemLink = function() return nil end,
	} },
})
rawset(G.C_Item, "IsItemDataCachedByID", function(id) return CACHED[id] == true end)
rawset(G.C_Item, "GetItemNameByID", function(id) return CACHED[id] and NAMES[id] or nil end)
rawset(G.C_Item, "RequestLoadItemDataByID", function(id) requested[id] = true end)
rawset(G.C_Item, "GetItemInfo", function() return nil end)
rawset(G.C_Item, "GetItemCount", function(id) return OWNED[id] or 0 end)
rawset(G.C_CurrencyInfo, "GetCoinTextureString", function(c) return tostring(c) .. "c" end)

local rows = {}
local tip = G.GameTooltip
rawset(tip, "AddDoubleLine", function(_, l, r) rows[#rows + 1] = { l, r } end)

local refreshed = 0
rawset(tip, "IsShown", function() return true end)
rawset(tip, "RefreshData", function() refreshed = refreshed + 1 end)

G.SlashCmdList.PREDUICRATES("test")

local function Row(i) return rows[i] and (rows[i][1] .. " | " .. rows[i][2]) or "nil" end
for i = 1, #rows do note(Row(i)) end

expect(#rows == 4, "four bundles listed, got " .. #rows)
-- Costs: Soul Dust 20*500 = 10000, Astral 4*1500 = 6000, Small Glowing (6-2)*900 = 3600
expect(rows[1] and rows[1][1]:find("Small Glowing Shard") and rows[1][2] == "3600c", "cheapest first: Small Glowing, owned taken off -> " .. Row(1))
expect(rows[2] and rows[2][1]:find("Greater Astral") and rows[2][2]:find("5d old") and rows[2][2]:find("6000c"), "Astral second, marked old -> " .. Row(2))
expect(rows[3] and rows[3][1]:find("Soul Dust") and rows[3][2] == "10000c", "Soul Dust third -> " .. Row(3))
expect(rows[4] and rows[4][1]:find("Large Glowing") and rows[4][2] == "looking up...", "uncached item is being looked up -> " .. Row(4))
expect(G.PredUIDB.crates.ids["soul dust"] == 11083, "name learned and saved")

-- The server answers: the name arrives, the tooltip is redrawn, the price shows.
Tick(0.5)
expect(requested[11139], "Large Glowing Shard's name was asked for")
CACHED[11139] = true
Fire("GET_ITEM_INFO_RECEIVED", 11139, true)
Tick(0.5)
expect(refreshed > 0, "tooltip redrawn after the name arrived")
expect(G.PredUIDB.crates.ids["large glowing shard"] == 11139, "looked-up name saved")
rows = {}
G.SlashCmdList.PREDUICRATES("test")
for i = 1, #rows do note("after: " .. Row(i)) end
expect(rows[3] and rows[3][1]:find("Large Glowing") and rows[3][2] == "8000c", "looked-up item now priced, third -> " .. Row(3))
