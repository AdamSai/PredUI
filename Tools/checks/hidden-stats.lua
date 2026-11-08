--------------------------------------------------------------------------------
-- AddonCheck scenario for Hidden Stats (Modules/HiddenStats.lua).
-- node "D:/Games/World of Warcraft/AddonCheck/check.js" PredUI --scenario PredUI/Tools/checks/hidden-stats.lua

local speed = { 7, 7, 7, 4.72 }
local swimming, mounted, taxi = false, false, false
rawset(G, "GetUnitSpeed", function() return speed[1], speed[2], speed[3], speed[4] end)
rawset(G, "IsSwimming", function() return swimming end)
rawset(G, "IsMounted", function() return mounted end)
rawset(G, "UnitOnTaxi", function() return taxi end)
rawset(G, "IsFlying", function() return false end)
rawset(G, "IsFalling", function() return false end)
rawset(G, "UnitIsDeadOrGhost", function() return false end)
rawset(G, "UnitPowerMax", function() return 1000 end)
rawset(G, "GetManaRegen", function() return 9.6, 2.4 end)
rawset(G, "UnitAttackSpeed", function() return 2.6, nil end)
rawset(G, "UnitRangedDamage", function() return 0 end)
rawset(G, "GetAverageItemLevel", function() return 52.4, 54.1, 54.1 end)
local dura = { [1] = { 60, 60 }, [5] = { 0, 100 }, [16] = { 60, 75 } }
rawset(G, "GetInventoryItemDurability", function(slot) local d = dura[slot] if d then return d[1], d[2] end end)
rawset(G, "GetInventoryItemLink", function(_, slot) return "item" .. slot end)

local panel = G.PredUIHiddenStats
expect(panel ~= nil, "panel PredUIHiddenStats should exist")
if not panel then return end
panel:Show()
G.PaperDollFrame:Show()
G.CharacterFrame:Show()

local speedRow = panel.rows[1]
local function Check(label, value, what)
	Tick(0.3)
	local l, v = speedRow.label:GetText(), speedRow.value:GetText()
	expect(l == label and v == value, what .. ": expected " .. label .. " " .. value .. ", got " .. tostring(l) .. " " .. tostring(v))
end

Check("Run speed", "100%", "running")
swimming = true
Check("Swim speed", "67%", "swimming")
swimming, mounted, speed = false, true, { 0, 11.2, 11.2, 4.72 }
Check("Mounted speed", "160%", "mounted")
mounted, taxi, speed = false, true, { 28, 7, 7, 4.72 }
Check("Flight path", "400%", "flight path")
taxi = false

-- Combat: values secret -> "-" and no errors.
rawset(G, "GetUnitSpeed", function() return Secret(), Secret(), Secret(), Secret() end)
rawset(G, "GetManaRegen", function() return Secret(), Secret() end)
Check("Run speed", "-", "secret speed")
speedRow:GetScript("OnEnter")(speedRow)
expect(panel.rows[2].value:GetText() == "-", "secret regen should show -, got " .. tostring(panel.rows[2].value:GetText()))

-- No mana and no energy: regen row hidden.
rawset(G, "UnitPowerMax", function() return 0 end)
rawset(G, "UnitPowerType", function() return 1, "RAGE" end)
Tick(0.3)
expect(not panel.rows[2]:IsShown(), "regen row should hide for rage users")

-- Durability: 120/235 = 51%, a broken chest makes it red.
local duraRow = panel.rows[5]
expect(duraRow and duraRow:IsShown(), "durability row should show")
local dv = duraRow and duraRow.value:GetText() or ""
expect(dv:find("51%%") and dv:find("ff4040"), "durability should read 51% in red, got " .. dv)
duraRow:GetScript("OnEnter")(duraRow)
dura = {}
Tick(0.3)
expect(not duraRow:IsShown(), "durability row should hide with nothing that wears down")
G.SlashCmdList.PREDUIHSTATS("test")
Tick(0.3)
expect(speedRow.label:GetText() == "Mounted speed", "test mode should show sample values")
G.SlashCmdList.PREDUIHSTATS("test")
