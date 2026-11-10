--------------------------------------------------------------------------------
-- AddonCheck scenario for Loot Room (Modules/LootRoom.lua): deleting an item
-- with the loot window open loots into the freed slot.
-- node "D:/Games/World of Warcraft/AddonCheck/check.js" PredUI --scenario PredUI/Tools/checks/loot-room.lua

-- Bag 0 has two slots: a cheap item (10c) and a dear one (900c).
local bag = {
	[1] = { itemID = 101, stackCount = 1, hyperlink = "item:101", iconFileID = 1 },
	[2] = { itemID = 102, stackCount = 1, hyperlink = "item:102", iconFileID = 1 },
}
local prices = { [101] = 10, [102] = 900, [201] = 5, [202] = 500, [203] = 1000, [204] = 50 }
local maxStacks = { [204] = 20 }

-- Loot: 201 cheap, 202 worth more than the deleted item, 203 dearer but being
-- rolled on, 204 cheap but stacks onto a partial stack... none in the bags, so
-- it needs a slot like the rest.
local loot = {
	{ id = 201 }, { id = 202 }, { id = 203, locked = true }, { id = 204 },
}

local function FreeCount()
	local n = 0
	for i = 1, 2 do if not bag[i] then n = n + 1 end end
	return n
end

rawset(G.C_Container, "GetContainerNumSlots", function(b) return b == 0 and 2 or 0 end)
rawset(G.C_Container, "GetContainerNumFreeSlots", function(b) return b == 0 and FreeCount() or 0, 0 end)
rawset(G.C_Container, "GetContainerItemInfo", function(b, s) return b == 0 and bag[s] or nil end)
rawset(G.C_Container, "GetContainerItemQuestInfo", function() return {} end)
rawset(G.C_Container, "PickupContainerItem", function(b, s) G.__cursor = s end)
rawset(G.C_Item, "GetItemInfo", function(id)
	id = tonumber(id)
	if not prices[id] then return end
	return "Item " .. id, nil, nil, nil, nil, nil, nil, maxStacks[id] or 1, nil, nil, prices[id], 7, nil, 0
end)
rawset(G.C_Item, "GetItemInfoInstant", function(link) return tonumber(tostring(link):match("%d+")) end)
rawset(G.C_QuestLog, "GetNumQuestLogEntries", function() return 0 end)
rawset(G, "GetNumLootItems", function() return #loot end)
rawset(G, "GetLootSlotType", function() return 1 end)
rawset(G, "GetLootSlotInfo", function(i) return 1, "Item", 1, nil, 1, loot[i].locked or false, false end)
rawset(G, "GetLootSlotLink", function(i) return "item:" .. loot[i].id end)
rawset(G, "InCombatLockdown", function() return false end)
rawset(G, "ClearCursor", function() end)
rawset(G, "CursorHasItem", function() return G.__cursor ~= nil end)
rawset(G, "DeleteCursorItem", function() G.__deleted = G.__cursor; G.__cursor = nil end)
rawset(G.C_CurrencyInfo, "GetCoinTextureString", function(v) return tostring(v) .. "c" end)
local looted = {}
rawset(G, "LootSlot", function(i) looted[#looted + 1] = i end)

Fire("LOOT_OPENED")
Tick(0.2)

local dialog = G.StaticPopupDialogs and G.StaticPopupDialogs.PREDUI_LOOTROOM_DELETE
expect(dialog ~= nil, "delete dialog should exist")
if not dialog then return end

-- Delete the cheap item (value 10).
dialog.OnAccept({}, { bag = 0, slot = 1, itemID = 101, count = 1, value = 10 })
expect(G.__deleted == 1, "slot 1 should have been deleted")

-- An update before the delete reaches the bags must not loot anything yet.
Fire("BAG_UPDATE_DELAYED")
expect(#looted == 0, "nothing should be looted while no slot is free, got " .. #looted)

bag[1] = nil
Fire("BAG_UPDATE_DELAYED")
expect(#looted == 1, "one item should be looted into the one free slot, got " .. #looted)
expect(looted[1] == 2, "the 500c loot (slot 2) should be taken, not the rolled one, got " .. tostring(looted[1]))

-- Once used, later bag updates don't loot again.
Fire("BAG_UPDATE_DELAYED")
expect(#looted == 1, "should loot only once per delete, got " .. #looted)

-- With the setting off, a delete loots nothing.
bag[1] = { itemID = 101, stackCount = 1, hyperlink = "item:101", iconFileID = 1 }
G.PredUIDB.loot.lootAfterDelete = false
dialog.OnAccept({}, { bag = 0, slot = 1, itemID = 101, count = 1, value = 10 })
bag[1] = nil
Fire("BAG_UPDATE_DELAYED")
expect(#looted == 1, "with the setting off nothing more should be looted, got " .. #looted)
G.PredUIDB.loot.lootAfterDelete = true
