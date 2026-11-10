--------------------------------------------------------------------------------
-- AddonCheck scenario for Cast Bars (Modules/CastBars.lua).
-- node "D:/Games/World of Warcraft/AddonCheck/check.js" PredUI --scenario PredUI/Tools/checks/cast-bars.lua

local casting
rawset(G, "UnitCastingInfo", function(unit)
	if casting and casting.unit == unit then
		return casting.name, casting.name, 136243, casting.startMS, casting.endMS, false, casting.id, casting.notInt, 116
	end
end)
rawset(G, "UnitChannelInfo", function() end)

local bar = G.PredUICastBarPlayer
expect(bar ~= nil, "player cast bar should exist")
if not bar then return end

local now = G.GetTime() * 1000
casting = { unit = "player", name = "Frostbolt", startMS = now, endMS = now + 2000, id = "A" }
Fire("UNIT_SPELLCAST_START", "player", "A", 116)
Tick(0.1)
expect(bar:IsShown(), "bar should show on cast start")
expect(bar.title:GetText() == "Frostbolt", "title should be the spell, got " .. tostring(bar.title:GetText()))

-- A failed spam press for another spell mustn't touch the running cast.
Fire("UNIT_SPELLCAST_FAILED", "player", "B", 133)
Tick(0.1)
expect(bar.title:GetText() == "Frostbolt", "another cast's failure should be ignored, got " .. tostring(bar.title:GetText()))

-- An interrupt arriving after the stop still shows.
casting = nil
Fire("UNIT_SPELLCAST_STOP", "player", "A", 116)
Fire("UNIT_SPELLCAST_INTERRUPTED", "player", "A", 116, "X")
Tick(0.1)
expect(bar.title:GetText() == (G.INTERRUPTED or "Interrupted"), "should say interrupted, got " .. tostring(bar.title:GetText()))
Tick(2)
expect(not bar:IsShown(), "bar should fade out")

-- Target casts arrive secret: nothing may error, and the bar must end by itself.
local target = G.PredUICastBarTarget
expect(target ~= nil, "target cast bar should exist")
if not target then return end
rawset(G, "UnitCastingInfo", function(unit)
	if unit == "target" and casting then
		return Secret("Fireball"), Secret("Fireball"), Secret(135812), Secret(1000), Secret(4000), Secret(false), Secret("C"), Secret(false), Secret(133)
	end
end)
casting = true
Fire("UNIT_SPELLCAST_START", Secret("target"), Secret("C"), Secret(133))
Tick(0.1)
expect(target:IsShown(), "target bar should show a secret cast")
casting = nil
Tick(1)
Tick(1)
expect(not target:IsShown(), "target bar should end when the cast is gone, even without a stop event")
