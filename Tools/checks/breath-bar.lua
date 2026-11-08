--------------------------------------------------------------------------------
-- AddonCheck scenario for Breath Bar (Modules/BreathBar.lua).
-- node "D:/Games/World of Warcraft/AddonCheck/check.js" PredUI --scenario PredUI/Tools/checks/breath-bar.lua

local progress = 30000
rawset(G, "GetMirrorTimerProgress", function() return progress end)

Fire("MIRROR_TIMER_START", "BREATH", 30000, 60000, -1, 0, "Breath")
local bar = G.PredUIBreathBarBREATH
expect(bar ~= nil, "breath bar should be created on MIRROR_TIMER_START")
if not bar then return end
Tick(0.2)
expect(bar:IsShown(), "breath bar should show")
expect(bar.title:GetText() == "Breath", "title should be the timer label, got " .. tostring(bar.title:GetText()))
expect(bar.time:GetText() == "0:30 / 1:00", "time should be 0:30 / 1:00, got " .. tostring(bar.time:GetText()))

progress = 5000
Tick(0.2)
expect(bar.statusText:GetText() == "Get to the surface", "under 10s should warn, got " .. tostring(bar.statusText:GetText()))

progress = 0
Tick(0.2)
expect(bar.statusText:GetText() == "Drowning!", "at 0 should say drowning, got " .. tostring(bar.statusText:GetText()))

Fire("MIRROR_TIMER_PAUSE", "BREATH", 1)
Tick(0.2)
expect(bar.statusText:GetText() == "Paused", "pause should show, got " .. tostring(bar.statusText:GetText()))

Fire("MIRROR_TIMER_START", "BREATH", 20000, 60000, 10, 0, "Breath")
progress = 60000
Tick(0.2)
expect(bar.statusText:GetText() == "Catching your breath", "refilling should show, got " .. tostring(bar.statusText:GetText()))

Fire("MIRROR_TIMER_STOP", "BREATH")
Tick(3)
expect(not bar:IsShown(), "bar should fade out after MIRROR_TIMER_STOP")

-- Blizzard's own bar is faded while it has a timer.
local blizz = G.MirrorTimerContainer and G.MirrorTimerContainer.mirrorTimers and G.MirrorTimerContainer.mirrorTimers[1]
if blizz and blizz.Setup then
	blizz:Setup("BREATH", 30000, 60000, 0, "Breath")
	expect(blizz:GetAlpha() == 0, "Blizzard's breath bar should be faded, alpha " .. tostring(blizz:GetAlpha()))
	blizz:Clear()
	expect(blizz:GetAlpha() == 1, "Blizzard's bar should come back after its timer ends")
else
	note("MirrorTimerContainer not loaded in the test; Blizzard fade not checked")
end
