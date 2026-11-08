--------------------------------------------------------------------------------
-- AddonCheck scenario for Swing Timer (Modules/SwingTimer.lua).
-- node "D:/Games/World of Warcraft/AddonCheck/check.js" PredUI --scenario PredUI/Tools/checks/swing-timer.lua

local MAIN, OFF, RANGED = 0, 1, 2
local inCombat = true
local inRange = true
local main, off = 2.0, 1.5

rawset(G, "InCombatLockdown", function() return inCombat end)
rawset(G, "UnitAttackSpeed", function() return main, off, 3 end)
rawset(G.C_SwingTimer, "IsTargetWithinSwingRange", function() return inRange end)

Fire("PLAYER_SWING", 2.0, MAIN)
local bar = G.PredUISwingBarMainHand
expect(bar ~= nil, "main hand bar should be created on PLAYER_SWING")
if not bar then return end
Tick(0.2)
expect(bar:IsShown(), "main hand bar should show")
expect(bar.title:GetText() == "Main Hand", "title should be Main Hand, got " .. tostring(bar.title:GetText()))
expect(bar.time:GetText() == "1.8", "time should be 1.8, got " .. tostring(bar.time:GetText()))
expect(rawget(G, "PredUISwingBarOffHand") == nil,"off hand bar shouldn't exist before an off hand swing")

-- Waits full in combat, and says when the target is out of reach.
Tick(2)
expect(bar:IsShown(), "bar should wait in combat")
expect(bar.time:GetText() == "0.0", "a waiting bar should read 0.0, got " .. tostring(bar.time:GetText()))
inRange = false
Tick(0.3)
expect(bar.time:GetText() == "Out of range", "should say out of range, got " .. tostring(bar.time:GetText()))
inRange = nil
Tick(0.3)
expect(bar.time:GetText() == "0.0", "nil range isn't out of range, got " .. tostring(bar.time:GetText()))
inRange = true

-- A new swing restarts it. A secret payload is ignored.
Fire("PLAYER_SWING", 2.0, MAIN)
Tick(0.5)
expect(bar.time:GetText() == "1.5", "new swing should restart, got " .. tostring(bar.time:GetText()))
Fire("PLAYER_SWING", Secret(), MAIN)
Fire("PLAYER_SWING", 2.0, Secret())
Tick(0.1)
expect(bar.time:GetText() == "1.4", "secret swing should change nothing, got " .. tostring(bar.time:GetText()))

-- Changing weapons restarts at the new speed; a secret speed keeps the old one.
main = 3.0
Fire("WEAPON_SLOT_CHANGED")
Tick(0.1)
expect(bar.time:GetText() == "2.9", "weapon change should use the new speed, got " .. tostring(bar.time:GetText()))
main = Secret()
Fire("WEAPON_SLOT_CHANGED")
Tick(0.1)
expect(bar.time:GetText() == "2.9", "secret speed should keep the old length, got " .. tostring(bar.time:GetText()))
main = 2.0

-- Off hand removed: its bar goes.
Fire("PLAYER_SWING", 1.5, OFF)
local offBar = G.PredUISwingBarOffHand
expect(offBar and offBar:IsShown(), "off hand bar should show")
off = nil
Fire("WEAPON_SLOT_CHANGED")
expect(offBar and not offBar:IsShown(), "off hand bar should go when the weapon does")

-- Fades after combat.
inCombat = false
Tick(3.5)
Tick(3)
expect(not bar:IsShown(), "bar should fade out after combat")

-- A bar that's turned off ignores swings.
Fire("PLAYER_SWING", 3.0, RANGED)
local rangedBar = G.PredUISwingBarRanged
expect(rangedBar and rangedBar:IsShown(), "ranged bar should show")
Fire("PLAYER_DEAD")
expect(rangedBar and not rangedBar:IsShown(), "dying should clear the bars")
G.PredUIDB.swing.showRanged = false
Fire("PLAYER_SWING", 3.0, RANGED)
expect(rangedBar and not rangedBar:IsShown(), "a bar that's off should ignore swings")
G.PredUIDB.swing.showRanged = nil

-- Blizzard's own bar is faded, except in Edit Mode.
local blizz = rawget(G, "SwingTimerMainHandFrame")
if blizz and blizz.UpdateShownState then
	-- It's a stand-in here, whose GetAlpha always says 1, so record what's set.
	local alpha
	rawset(blizz, "SetAlpha", function(_, a) alpha = a end)
	rawset(blizz, "isInEditMode", false)
	blizz:UpdateShownState()
	expect(alpha == 0, "Blizzard's bar should be faded, alpha " .. tostring(alpha))
	rawset(blizz, "isInEditMode", true)
	blizz:UpdateShownState()
	expect(alpha == 1, "Blizzard's bar should show in Edit Mode, alpha " .. tostring(alpha))
	rawset(blizz, "isInEditMode", false)
else
	note("SwingTimerMainHandFrame not loaded in the test; Blizzard fade not checked")
end

-- Edit Mode: every bar shows as a still sample, drags snap and save.
local manager, magnetism = G.EditModeManagerFrame, G.EditModeMagnetismManager
local snapped, registered = 0, {}
-- Frames have no screen position in the test.
rawset(G.UIParent, "GetCenter", function() return 960, 540 end)
rawset(bar, "GetCenter", function() return 960, 300 end)
rawset(manager, "IsSnapEnabled", function() return true end)
rawset(magnetism, "ApplyMagnetism", function(_, frame) snapped = snapped + 1; expect(frame == bar, "should snap the dragged bar") end)
rawset(magnetism, "RegisterFrame", function(_, frame) registered[frame] = true end)
rawset(magnetism, "UnregisterFrame", function(_, frame) registered[frame] = nil end)

manager:EnterEditMode()
Tick(0.1)
expect(bar:IsShown() and rangedBar:IsShown(), "Edit Mode should show the bars")
expect(bar.time:GetText() == "2.6", "Edit Mode should show the sample time, got " .. tostring(bar.time:GetText()))
Fire("PLAYER_SWING", 2.0, MAIN)
Tick(0.2)
expect(bar.time:GetText() == "2.6", "swings should be ignored in Edit Mode, got " .. tostring(bar.time:GetText()))

local selection = bar.Selection
expect(selection ~= nil, "the bar should have a selection box")
if selection then
	G.PredUIDB.swing.pointMainHand = nil
	selection:GetScript("OnDragStart")(selection)
	expect(registered[rangedBar], "our other bars should be magnetic during a drag")
	selection:GetScript("OnDragStop")(selection)
	expect(snapped == 1, "dropping a bar should snap it, snapped " .. snapped)
	expect(next(registered) == nil, "our bars shouldn't stay magnetic after a drop")
	expect(type(G.PredUIDB.swing.pointMainHand) == "table", "dropping a bar should save it")
end

manager:ExitEditMode()
expect(not bar:IsShown() and not rangedBar:IsShown(), "closing Edit Mode should hide the bars")
Fire("PLAYER_SWING", 2.0, MAIN)
expect(bar:IsShown(), "swings should work again after Edit Mode")
Fire("PLAYER_DEAD")

-- The preview shows every bar, runs its rounds and fades.
G.SlashCmdList.PREDUISWING("test")
Tick(0.1)
expect(bar:IsShown() and rangedBar:IsShown(), "preview should show the bars")
G.SlashCmdList.PREDUISWING("")
Tick(20)
Tick(3)
expect(not bar:IsShown(), "preview should end and fade")
