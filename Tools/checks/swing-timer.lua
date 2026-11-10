--------------------------------------------------------------------------------
-- AddonCheck scenario for Swing Timer (Modules/SwingTimer.lua).
-- node "D:/Games/World of Warcraft/AddonCheck/check.js" PredUI --scenario PredUI/Tools/checks/swing-timer.lua

local MAIN, OFF, RANGED = 0, 1, 2
local inCombat = true
local inRange = true
local main, off = 2.0, 1.5

rawset(G, "InCombatLockdown", function() return inCombat end)
local ranged = 3
rawset(G, "UnitAttackSpeed", function() return main, off, ranged end)
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

-- Ranged wind-up: the last half second says to stand still.
inCombat = true
inRange = true
Fire("PLAYER_SWING", 3.0, RANGED)
Tick(2)
expect(rangedBar.title:GetText() == "Ranged", "no cue before the wind-up, got " .. tostring(rangedBar.title:GetText()))
Tick(0.7)
expect(rangedBar.title:GetText() == "Stand still", "wind-up should say stand still, got " .. tostring(rangedBar.title:GetText()))
Tick(0.5)
expect(rangedBar.title:GetText() == "Stand still", "a waiting shot still needs you still, got " .. tostring(rangedBar.title:GetText()))
inRange = false
Tick(0.3)
expect(rangedBar.title:GetText() == "Ranged" and rangedBar.time:GetText() == "Out of range", "out of range isn't a wind-up, got " .. tostring(rangedBar.title:GetText()))
inRange = true
Fire("PLAYER_SWING", 3.0, RANGED)
Fire("STOP_AUTOREPEAT_SPELL")
Tick(2.8)
expect(rangedBar.title:GetText() == "Ranged", "no cue once auto shot is off, got " .. tostring(rangedBar.title:GetText()))
Fire("PLAYER_DEAD")

-- Melee swings never get the cue.
Fire("START_AUTOREPEAT_SPELL")
Fire("PLAYER_SWING", 2.0, MAIN)
Tick(1.8)
expect(bar.title:GetText() == "Main Hand", "melee has no wind-up, got " .. tostring(bar.title:GetText()))
Fire("PLAYER_DEAD")

-- The range line, for a ranged class.
rawset(G, "UnitClass", function() return "Warrior", "WARRIOR" end)
Fire("PLAYER_ENTERING_WORLD")
expect(rawget(G, "PredUISwingRangeHint") == nil, "melee classes shouldn't get the range line")
rawset(G, "UnitClass", function() return "Hunter", "HUNTER" end)
Fire("PLAYER_ENTERING_WORLD")
local hint = rawget(G, "PredUISwingRangeHint")
expect(hint ~= nil, "a hunter should get the range line")
if hint then
	local text = hint.text
	local spellRange, askedSpell
	local spellInfo
	rawset(G.C_Spell, "IsSpellInRange", function(spell) askedSpell = spell; return spellRange end)
	rawset(G.C_Spell, "GetSpellInfo", function() return spellInfo end)
	rawset(G, "LibStub", nil)

	-- The spell check answers even when the swing check can't, and goes first.
	inRange = nil
	spellRange = true
	Tick(0.3)
	expect(askedSpell == 75, "a hunter should check Auto Shot, got " .. tostring(askedSpell))
	expect(text:IsShown() and text:GetText() == "In range", "spell check should fill in for a nil swing check, got " .. tostring(text:GetText()))
	inRange = true
	spellRange = false
	Tick(0.3)
	expect(text:GetText() == "Out of range", "spell check should go first, got " .. tostring(text:GetText()))
	spellRange = Secret()
	Tick(0.3)
	expect(text:GetText() == "In range", "a secret spell answer should use the swing check, got " .. tostring(text:GetText()))
	G.SlashCmdList.PREDUISWING("range")

	-- Needed range works without the library; distance bands need it.
	spellRange = false
	spellInfo = { minRange = 8, maxRange = 35 }
	Tick(0.3)
	expect(text:GetText() == "Out of range (need 35)", "should give the range needed, got " .. tostring(text:GetText()))
	local low, high = 40, 45
	local checker = { GetRange = function() return low, high end }
	local stub = { GetLibrary = function() return checker end }
	rawset(G, "LibStub", stub)
	Tick(0.3)
	expect(text:GetText() == "Out of range: 40-45 yd (need 35)", "should show the band, got " .. tostring(text:GetText()))
	low, high = 60, nil
	Tick(0.3)
	expect(text:GetText() == "Out of range: 60+ yd (need 35)", "no upper edge should read 60+, got " .. tostring(text:GetText()))
	low, high = 0, 5
	Tick(0.3)
	expect(text:GetText() == "Too close: 0-5 yd (need 8)", "should say too close, got " .. tostring(text:GetText()))
	spellRange = true
	low, high = 25, 30
	Tick(0.3)
	expect(text:GetText() == "In range: 25-30 yd", "in range shows only the band, got " .. tostring(text:GetText()))
	low, high = Secret(), Secret()
	spellInfo = { minRange = Secret(), maxRange = Secret() }
	spellRange = false
	Tick(0.3)
	expect(text:GetText() == "Out of range", "secret numbers should be left out, got " .. tostring(text:GetText()))
	checker.GetRange = function() error("boom") end
	Tick(0.3)
	expect(text:GetText() == "Out of range", "a library error should be survived, got " .. tostring(text:GetText()))
	rawset(G, "LibStub", nil)
	spellInfo = nil
	spellRange = nil

	inRange = true
	Tick(0.3)
	expect(text:IsShown() and text:GetText() == "In range", "should say in range, got " .. tostring(text:GetText()))
	inRange = false
	Tick(0.3)
	expect(text:IsShown() and text:GetText() == "Out of range", "should say out of range, got " .. tostring(text:GetText()))
	inRange = nil
	Tick(0.3)
	expect(not text:IsShown(), "no target should hide the line")
	inRange = Secret()
	Tick(0.3)
	expect(not text:IsShown(), "a secret answer should hide the line")
	inRange = true
	G.PredUIDB.swing.showRangeHint = false
	Tick(0.3)
	expect(not text:IsShown(), "the setting should turn the line off")
	G.PredUIDB.swing.showRangeHint = nil

	-- With a target and no shot running, the ranged bar shows ready.
	Fire("PLAYER_DEAD")
	inRange = true
	Tick(0.3)
	expect(rangedBar:IsShown() and rangedBar.time:GetText() == "Ready", "a target should show the ranged bar ready, got " .. tostring(rangedBar.time:GetText()))
	inRange = false
	Tick(0.3)
	expect(rangedBar:IsShown() and rangedBar.time:GetText() == "Out of range", "an out of range target should say so, got " .. tostring(rangedBar.time:GetText()))
	inRange = true
	Fire("PLAYER_SWING", 3.0, RANGED)
	Tick(0.3)
	local shotLeft = tonumber(rangedBar.time:GetText())
	expect(shotLeft and shotLeft > 2.5 and shotLeft < 3, "a shot should take over the bar, got " .. tostring(rangedBar.time:GetText()))
	Fire("PLAYER_DEAD")
	inRange = nil
	Tick(0.3)
	expect(not rangedBar:IsShown(), "no target and no shot should leave the bar hidden")
	inRange = true
	Tick(0.3)
	expect(rangedBar:IsShown(), "targeting again should show it")
	inRange = nil
	Tick(3)
	expect(not rangedBar:IsShown(), "losing the target should fade the bar")
	G.PredUIDB.swing.showOnTarget = false
	inRange = true
	Tick(0.3)
	expect(not rangedBar:IsShown(), "the setting should stop the ready bar")
	G.PredUIDB.swing.showOnTarget = nil

	-- Turning auto shot on from a ready bar runs the wind-up at once.
	inRange = true
	Tick(0.3)
	expect(rangedBar.time:GetText() == "Ready", "should be ready first, got " .. tostring(rangedBar.time:GetText()))
	Fire("START_AUTOREPEAT_SPELL")
	Tick(0.1)
	expect(rangedBar.title:GetText() == "Stand still", "first shot should show the wind-up, got " .. tostring(rangedBar.title:GetText()))
	local firstLeft = tonumber(rangedBar.time:GetText())
	expect(firstLeft and firstLeft <= 0.5, "first shot should count the wind-up only, got " .. tostring(rangedBar.time:GetText()))
	Fire("PLAYER_SWING", 3.0, RANGED)
	Tick(0.1)
	expect(rangedBar.title:GetText() == "Ranged", "the shot should start the full swing, got " .. tostring(rangedBar.title:GetText()))
	-- A second START while shooting changes nothing.
	Fire("START_AUTOREPEAT_SPELL")
	Tick(0.1)
	local left = tonumber(rangedBar.time:GetText())
	expect(left and left > 2.5, "START mid-swing shouldn't restart it, got " .. tostring(rangedBar.time:GetText()))

	-- Inside the hunter's minimum range: "Too close", on the bar and the line.
	local low, high = 5, 10
	rawset(G, "LibStub", { GetLibrary = function() return { GetRange = function() return low, high end } end })
	rawset(G.C_Spell, "IsSpellInRange", function() return false end)
	rawset(G.C_Spell, "GetSpellInfo", function() return { minRange = 8, maxRange = 35 } end)
	Tick(3.5)
	expect(rangedBar.time:GetText() == "Too close", "a waiting bar in the dead zone should say too close, got " .. tostring(rangedBar.time:GetText()))
	expect(hint.text:GetText() == "Too close: 5-10 yd (need 8)", "5-10 yd with an 8 yd minimum is too close, got " .. tostring(hint.text:GetText()))
	low, high = 40, 45
	Tick(0.3)
	expect(rangedBar.time:GetText() == "Out of range", "far away is out of range, got " .. tostring(rangedBar.time:GetText()))
	expect(hint.text:GetText() == "Out of range: 40-45 yd (need 35)", "far line, got " .. tostring(hint.text:GetText()))
	Fire("PLAYER_DEAD")
	Tick(0.3)
	expect(rangedBar.time:GetText() == "Out of range", "ready bar far away, got " .. tostring(rangedBar.time:GetText()))
	low, high = 5, 10
	Tick(0.3)
	expect(rangedBar.time:GetText() == "Too close", "ready bar too close, got " .. tostring(rangedBar.time:GetText()))
	rawset(G, "LibStub", nil)
	rawset(G.C_Spell, "IsSpellInRange", function() return nil end)
	rawset(G.C_Spell, "GetSpellInfo", function() return nil end)

	-- Shooting the moment you target, before the ready bar is drawn.
	Fire("PLAYER_DEAD")
	Fire("STOP_AUTOREPEAT_SPELL")
	inRange = true
	Fire("START_AUTOREPEAT_SPELL")
	Tick(0.1)
	expect(rangedBar:IsShown() and rangedBar.title:GetText() == "Stand still", "auto shot right after targeting should start the wind-up, got " .. tostring(rangedBar.title:GetText()))

	-- The first shot sends no PLAYER_SWING: the Auto Shot cast starts the swing.
	Tick(0.5)
	Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-guid", 75)
	Tick(0.1)
	local castLeft = tonumber(rangedBar.time:GetText())
	expect(castLeft and castLeft > 2.7 and castLeft < 3, "the Auto Shot cast should start a full swing, got " .. tostring(rangedBar.time:GetText()))
	expect(rangedBar.title:GetText() == "Ranged", "a fresh swing isn't a wind-up, got " .. tostring(rangedBar.title:GetText()))

	-- A PLAYER_SWING right before the cast keeps its own length.
	Fire("PLAYER_SWING", 2.0, RANGED)
	Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-guid", 75)
	Tick(0.1)
	local eventLeft = tonumber(rangedBar.time:GetText())
	expect(eventLeft and eventLeft < 2, "PLAYER_SWING should win over the cast, got " .. tostring(rangedBar.time:GetText()))

	-- Other spells, and secret IDs, don't start anything.
	Fire("PLAYER_DEAD")
	Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-guid", 3044)
	Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-guid", Secret())
	expect(not rangedBar:IsShown() or rangedBar.time:GetText() == "Ready", "other casts shouldn't start the bar, got " .. tostring(rangedBar.time:GetText()))

	-- Out of range: no wind-up on START.
	Fire("PLAYER_DEAD")
	inRange = false
	Fire("START_AUTOREPEAT_SPELL")
	Tick(0.1)
	expect(rangedBar.title:GetText() ~= "Stand still", "no wind-up when the target is out of range")

	-- The debug printout survives every event, secrets included.
	G.SlashCmdList.PREDUISWING("debug")
	Fire("PLAYER_SWING", 3.0, RANGED)
	Fire("UNIT_SPELLCAST_SUCCEEDED", "player", Secret(), Secret())
	Fire("STOP_AUTOREPEAT_SPELL")
	G.SlashCmdList.PREDUISWING("debug")
	local log = rawget(G.PredUIDB.swing, "debugLog")
	expect(type(log) == "table" and #log >= 3, "debug lines should be saved, got " .. tostring(log and #log))
	Fire("PLAYER_DEAD")

	-- Arcane Shot as the opener: auto shot comes on with no START event; the
	-- poll sees it and starts the first shot. A stand-in answer is ignored.
	local autoOn = false
	local asked
	rawset(G.C_Spell, "IsAutoRepeatSpell", function(spell) asked = spell; return autoOn end)
	Fire("STOP_AUTOREPEAT_SPELL")
	inRange = true
	Tick(0.3)
	expect(rangedBar.time:GetText() == "Ready", "auto shot off: ready, got " .. tostring(rangedBar.time:GetText()))
	expect(asked == 75, "should ask about Auto Shot, got " .. tostring(asked))
	Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-guid", 3044)   -- Arcane Shot
	autoOn = true
	Tick(0.3)
	Tick(0.1)   -- the poll can start it on the last frame of the tick
	expect(rangedBar.title:GetText() == "Stand still", "auto shot coming on should start the wind-up, got " .. tostring(rangedBar.title:GetText()))
	-- Staying on doesn't restart it.
	Fire("PLAYER_SWING", 3.0, RANGED)
	Tick(0.3)
	local onLeft = tonumber(rangedBar.time:GetText())
	expect(onLeft and onLeft > 2.5, "auto shot staying on shouldn't restart the swing, got " .. tostring(rangedBar.time:GetText()))
	autoOn = Secret()
	Tick(0.3)
	autoOn = false
	Tick(0.3)
	Fire("PLAYER_DEAD")
	inRange = nil
	Tick(0.3)

	-- The in-game log: Arcane Shot, auto shot on, then the shot ~0.6 s later.
	-- Arcane Shot put the player in combat, so the weapon speed was secret.
	autoOn = false
	Fire("STOP_AUTOREPEAT_SPELL")
	inRange = true
	Tick(0.3)                  -- out of combat: the speed (3) is read and kept
	ranged = Secret()
	Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-guid", 3044)
	autoOn = true
	Fire("START_AUTOREPEAT_SPELL")
	Tick(0.1)
	expect(rangedBar.title:GetText() == "Stand still", "Arcane Shot opener in combat should start the wind-up, got " .. tostring(rangedBar.title:GetText()))
	Tick(0.5)
	Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-guid", 75)
	Tick(0.1)
	local keptLeft = tonumber(rangedBar.time:GetText())
	expect(keptLeft and keptLeft > 2.7 and keptLeft < 3, "the Auto Shot cast should use the kept speed, got " .. tostring(rangedBar.time:GetText()))
	Fire("PLAYER_SWING", 2.09, RANGED)
	Tick(0.1)
	local swingLeft = tonumber(rangedBar.time:GetText())
	expect(swingLeft and swingLeft < 2.1, "PLAYER_SWING's length should win, got " .. tostring(rangedBar.time:GetText()))
	-- And from then on the swing's length is the one kept.
	Fire("PLAYER_DEAD")
	Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-guid", 75)
	Tick(0.1)
	local learnedLeft = tonumber(rangedBar.time:GetText())
	expect(learnedLeft and learnedLeft < 2.1, "a later cast should use PLAYER_SWING's length, got " .. tostring(rangedBar.time:GetText()))
	ranged = 3
	autoOn = false
	Fire("PLAYER_DEAD")
	inRange = nil
	Tick(0.3)
end
