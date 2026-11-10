--------------------------------------------------------------------------------
-- Swing Timer: PredUI bars for your main hand, off hand and ranged auto attacks,
-- in place of Blizzard's own.
--
--   * Forever has an event for this: PLAYER_SWING gives each swing's real length
--     and which weapon made it, so there's no combat log reading or guessing.
--     It reports the swing that just happened, so a bar only starts at the first
--     hit, not when you turn auto attack on.
--   * A bar fills up to the next swing, stays full while you're in combat, and
--     fades when combat is over.
--   * A haste change takes effect from the next swing, as on Blizzard's bars;
--     the swing in progress keeps the length PLAYER_SWING gave it.
--   * Changing weapons restarts a running bar at the new weapon's speed.
--     UnitAttackSpeed can be secret in combat; then the old length is kept until
--     the next swing corrects it.
--   * Out of range is read from C_SwingTimer.IsTargetWithinSwingRange while a bar
--     waits. EnableRangeCheck isn't used: Blizzard's bars switch that same check
--     on and off for themselves.
--   * A ranged shot has a short wind-up at the end of its swing, and moving during
--     it holds the shot back. No API or event reports the wind-up, so it's timed
--     back from the end of the bar: a line marks where it starts, then the bar
--     turns red and says "Stand still". Its length is a setting.
--   * Ranged classes (hunter, and wand users) get a line under the ranged bar
--     while they have a target, saying whether it's in range. It asks about the
--     Auto Shot or Shoot spell first, as Blizzard's gamepad bar does, because the
--     swing range check can give no answer with a target up. Neither check
--     covers facing or line of sight. It also shows the distance as a band of
--     yards when LibRangeCheck is loaded, and the yards you need when out of range.
--   * For those classes the ranged bar also shows, full and "Ready", whenever an
--     enemy is targeted and no shot is counting down, so you see it before the
--     first shot. It fades when the target goes. Turning auto shot on from there
--     starts the first shot's wind-up at once (START_AUTOREPEAT_SPELL), since
--     PLAYER_SWING only arrives after the shot. It checks the target itself, so
--     targeting and shooting in the same moment still starts it. As a backup for
--     a shot that sends no PLAYER_SWING, the Auto Shot / Shoot cast
--     (UNIT_SPELLCAST_SUCCEEDED) starts the swing too; PLAYER_SWING wins.
--     Openers like Arcane Shot turn auto shot on by themselves, so the range
--     poll also watches C_Spell.IsAutoRepeatSpell and starts the first shot
--     when it switches on.
--   * A ranged bar waiting for its shot uses the spell range check too, so the
--     hunter's minimum range reads "Too close" instead of a stuck "0.0".
--   * Blizzard's bars are faded out, not hidden or moved: they belong to Edit
--     Mode, and only alpha is safe to touch. Edit Mode still shows them.
--   * Our own bars can be moved and snapped in Edit Mode (EditMode.lua). While it
--     is open they show as a still sample and ignore swings.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.Style
local EditMode = ns.EditMode
local Public, PublicNumber, Try = ns.Public, ns.PublicNumber, ns.Try

local M = ns.NewModule("swing", {
	title = "Swing Timer",
	notes = "Bars counting down to your next main hand, off hand and ranged swing.",
	defaults = { locked = false, hideBlizzard = true, showOffHand = true, showRanged = true, windup = 0.5, showRangeHint = true, showOnTarget = true },
})

local BAR_W, BAR_H = 260, 16
local RANGE_CHECK_INTERVAL = 0.2   -- seconds between range checks on a waiting bar
local PREVIEW_ROUNDS = 5           -- swings the preview runs, so there's time to drag
local WINDUP_COLOR = { 1.00, 0.30, 0.25 }
local WINDUP_TITLE = "Stand still"
local AUTO_SHOT_SPELL, WAND_SPELL = 75, 5019
local RANGED_CLASSES = { HUNTER = AUTO_SHOT_SPELL, MAGE = WAND_SPELL, PRIEST = WAND_SPELL, WARLOCK = WAND_SPELL }

local KINDS = {
	{ id = "MainHand", swing = Enum.PlayerSwingType.MainHand, title = "Main Hand", speedIndex = 1,
	  frame = "SwingTimerMainHandFrame", color = { 1.00, 0.72, 0.20 }, point = { "CENTER", "CENTER", 0, -180 }, preview = 2.6 },
	{ id = "OffHand", swing = Enum.PlayerSwingType.OffHand, title = "Off Hand", speedIndex = 2, option = "showOffHand",
	  frame = "SwingTimerOffHandFrame", color = { 0.45, 0.80, 0.45 }, point = { "CENTER", "CENTER", 0, -204 }, preview = 1.8 },
	{ id = "Ranged", swing = Enum.PlayerSwingType.Ranged, title = "Ranged", speedIndex = 3, option = "showRanged", hasWindup = true,
	  frame = "SwingTimerRangedFrame", color = { 0.40, 0.70, 1.00 }, point = { "CENTER", "CENTER", 0, -228 }, preview = 3.0 },
}

local byType = {}              -- [Enum.PlayerSwingType] = kind
for _, kind in ipairs(KINDS) do byType[kind.swing] = kind end

local db
local bars = {}                -- [kind] = bar
local swings = {}              -- [kind] = { duration=, ends=, ready=, preview=, rounds= }
local editing = false          -- Edit Mode is open
local autoShooting = false     -- auto shot or wand is switched on
local rangeHint                -- the "in range" line, only made for ranged classes
local rangeSpell               -- the spell whose range that line checks
local debugging = false        -- /swingtimer debug: print the events as they come
local DebugEvent               -- defined with the commands
local WatchAutoShot            -- defined with the range line

local function Wanted(kind)
	return not kind.option or db[kind.option]
end

-- UnitAttackSpeed is secret in combat, and an opener like Arcane Shot puts you
-- in combat before auto shot starts. So the last speed seen is kept: from
-- UnitAttackSpeed while it can be read, and from each PLAYER_SWING.
local knownSpeed = {}          -- [kind] = seconds

local function WeaponSpeed(kind)
	local speed = PublicNumber(select(kind.speedIndex, Try(UnitAttackSpeed, "player")))
	if speed and speed > 0 then knownSpeed[kind] = speed end
	return knownSpeed[kind]
end

--------------------------------------------------------------------------------
-- Bars
--------------------------------------------------------------------------------

local function IsOutOfRange(kind)
	local inRange = Try(C_SwingTimer.IsTargetWithinSwingRange, kind.swing)
	-- nil means no check could be made, which isn't the same as out of range.
	return Public(inRange) and inRange == false
end

-- The game gives no exact distance to an enemy. LibRangeCheck (it comes with
-- Platynator) narrows it to a band by trying spells and items of known ranges.
local function TargetDistance()
	local stub = _G.LibStub        -- only there when an addon that bundles it is on
	local checker = stub and Try(stub.GetLibrary, stub, "LibRangeCheck-3.0", true)
	if not checker then return nil, nil end
	local low, high = Try(checker.GetRange, checker, "target", false, false, RANGE_CHECK_INTERVAL)
	return PublicNumber(low), PublicNumber(high)
end

local function SpellRange()
	local info = Try(C_Spell.GetSpellInfo, rangeSpell)
	if not Public(info) or type(info) ~= "table" then return nil, nil end
	return PublicNumber(info.minRange), PublicNumber(info.maxRange)
end

-- true, false, or nil when neither check can say. The swing check alone
-- doesn't count the hunter's minimum range as out of range, the spell does.
local function TargetInRange(kind)
	local inRange = Try(C_Spell.IsSpellInRange, rangeSpell, "target")
	if Public(inRange) and inRange ~= nil then return inRange end
	inRange = Try(C_SwingTimer.IsTargetWithinSwingRange, kind.swing)
	if Public(inRange) then return inRange end
end

-- Everything known about the ranged target: inRange (nil = no target to shoot),
-- the distance band, the range the spell needs, and whether you're too close.
-- Out of range but no farther than the spell reaches means too close.
local function ReadRange(kind)
	local inRange = TargetInRange(kind)
	if inRange == nil then return nil end
	local low, high = TargetDistance()
	local minNeeded, maxNeeded = SpellRange()
	local tooClose = not inRange and minNeeded and minNeeded > 0 and high
		and high <= math.max(minNeeded, maxNeeded or 0) or false
	return inRange, low, high, minNeeded, maxNeeded, tooClose
end

local function SetWindup(kind, bar, on)
	if (bar.inWindup or false) == on then return end
	bar.inWindup = on
	local c = on and WINDUP_COLOR or kind.color
	bar:SetColor(c[1], c[2], c[3])
	bar:SetTexts(on and WINDUP_TITLE or kind.title)
end

local function WindupExpected(kind, swing)
	return kind.hasWindup and (swing.preview or autoShooting) or false
end

local function PlaceWindupMark(kind, bar, duration)
	if not kind.hasWindup then return end
	local x = math.max(0, math.floor(bar.fillWidth * (1 - db.windup / duration) + 0.5))
	bar.windupMark:ClearAllPoints()
	bar.windupMark:SetPoint("TOPLEFT", bar.status, "TOPLEFT", x, 0)
	bar.windupMark:SetPoint("BOTTOMLEFT", bar.status, "BOTTOMLEFT", x, 0)
end

local function BeginSwing(kind, swing, bar)
	bar.idle = nil
	swing.ready = nil
	swing.started = GetTime()
	swing.ends = swing.started + swing.duration
	swings[kind] = swing
	SetWindup(kind, bar, false)
	PlaceWindupMark(kind, bar, swing.duration)
	bar:ShowBar()
	bar:SetTexts(kind.title)
end

local function Finish(kind, bar)
	swings[kind] = nil
	SetWindup(kind, bar, false)
	bar:Still(1)
	bar:FadeOut()
end

-- The bar has reached the next swing. Waits there in combat.
local function WaitForSwing(kind, swing, bar)
	local now = GetTime()
	if swing.preview or not InCombatLockdown() then
		Finish(kind, bar)
		return
	end
	if now < (bar.nextRangeCheck or 0) then return end
	bar.nextRangeCheck = now + RANGE_CHECK_INTERVAL
	local away, tooClose
	if kind.hasWindup then
		local inRange, _, _, _, _, close = ReadRange(kind)
		away = inRange == false
		tooClose = close
	else
		away = IsOutOfRange(kind)
	end
	SetWindup(kind, bar, WindupExpected(kind, swing) and not away)
	bar.status:SetAlpha(away and 0.35 or 1)
	bar:SetTexts(nil, tooClose and "Too close" or away and "Out of range" or "0.0")
end

local function OnBarUpdate(bar)
	if editing or bar:UpdateFade() then return end
	local kind = bar.kind
	local swing = swings[kind]
	if not swing then return end
	if swing.ready then
		WaitForSwing(kind, swing, bar)
		return
	end

	local left = swing.ends - GetTime()
	if left > 0 then
		SetWindup(kind, bar, WindupExpected(kind, swing) and left <= db.windup)
		bar:SetTexts(nil, ("%.1f"):format(left))
		bar:Animate(1 - left / swing.duration, true, false)
	elseif swing.preview and swing.rounds > 1 then
		swing.rounds = swing.rounds - 1
		BeginSwing(kind, swing, bar)
	else
		swing.ready = true
		bar.nextRangeCheck = nil
		bar:Still(1)
		bar:SetTexts(nil, "0.0")
	end
end

local function GetBar(kind)
	if bars[kind] then return bars[kind] end
	local bar = S.Bar({
		name = "PredUISwingBar" .. kind.id, width = BAR_W, height = BAR_H,
		db = db, pointKey = "point" .. kind.id, defaultPoint = kind.point,
		locked = function() return db.locked end,
	})
	local c = kind.color
	bar:SetColor(c[1], c[2], c[3])
	bar.spark:SetHeight(BAR_H + 10)
	bar.kind = kind
	if kind.hasWindup then
		bar.windupMark = bar.top:CreateTexture(nil, "ARTWORK", nil, 3)
		bar.windupMark:SetColorTexture(1, 1, 1, 0.9)
		bar.windupMark:SetWidth(2)
	end
	bar:SetScript("OnUpdate", OnBarUpdate)
	EditMode.Add(bar, kind.title .. " Swing", bar.status, function(self)
		S.SavePoint(self, db, "point" .. kind.id)
	end)
	bars[kind] = bar
	return bar
end

local function StartSwing(duration, swingType)
	duration = PublicNumber(duration)
	if editing or not Public(swingType) or not duration or duration <= 0 then return end
	local kind = byType[swingType]
	if kind and kind.hasWindup then autoShooting = true end
	if not kind then return end
	knownSpeed[kind] = duration
	if not Wanted(kind) then return end
	BeginSwing(kind, { duration = duration, fromEvent = true }, GetBar(kind))
end

-- PLAYER_SWING only comes once a shot has landed, so the first shot's wind-up
-- would pass with the bar still on Ready. Starting auto shot from a ready bar
-- runs the wind-up straight away; the shot's PLAYER_SWING then takes over.
-- It checks the target itself rather than waiting for the ready bar, which is
-- only drawn a fraction of a second after targeting.
local function StartFirstShot()
	local kind = byType[Enum.PlayerSwingType.Ranged]
	if editing or swings[kind] or not Wanted(kind) then return end
	if TargetInRange(kind) ~= true then return end
	-- The speed only sizes the bar here (the wind-up is what's timed), so a
	-- stand-in will do if none has been seen yet.
	local speed = WeaponSpeed(kind) or kind.preview
	BeginSwing(kind, { duration = speed, firstShot = true }, GetBar(kind))
	swings[kind].ends = GetTime() + math.min(db.windup, speed)
end

-- Backup for a shot that sends no PLAYER_SWING (the first one may not): the
-- Auto Shot / Shoot cast itself starts the swing at the weapon's speed. A
-- PLAYER_SWING that already started it, or comes right after, wins.
local SHOT_SPELLS = { [AUTO_SHOT_SPELL] = true, [WAND_SPELL] = true }
local PLAYER_SWING_GRACE = 0.3     -- seconds a PLAYER_SWING start is trusted over a cast

local function OnShotCast(spellID)
	if not Public(spellID) or not SHOT_SPELLS[spellID] then return end
	local kind = byType[Enum.PlayerSwingType.Ranged]
	if editing or not Wanted(kind) then return end
	local swing = swings[kind]
	if swing and swing.fromEvent and GetTime() - swing.started < PLAYER_SWING_GRACE then return end
	local speed = WeaponSpeed(kind)
	if not speed then return end
	BeginSwing(kind, { duration = speed }, GetBar(kind))
end

local function Clear(kind)
	swings[kind] = nil
	if bars[kind] then
		bars[kind].idle = nil
		SetWindup(kind, bars[kind], false)
		bars[kind]:Hide()
	end
end

local function ClearAll()
	for _, kind in ipairs(KINDS) do Clear(kind) end
end

local function EnterEditMode()
	ClearAll()
	editing = true
	for _, kind in ipairs(KINDS) do
		if Wanted(kind) then
			local bar = GetBar(kind)
			bar:ShowBar()
			bar:SetTexts(kind.title, ("%.1f"):format(kind.preview))
			bar.status:SetAlpha(1)
			PlaceWindupMark(kind, bar, kind.preview)
			bar:Still(0.6)
			EditMode.Show(bar)
		end
	end
end

local function ExitEditMode()
	editing = false
	for _, bar in pairs(bars) do
		EditMode.Hide(bar)
		bar:Hide()
	end
end

-- Changing weapons restarts the swing, as on Blizzard's bars.
local function OnWeaponChanged()
	for _, kind in ipairs(KINDS) do
		local swing = swings[kind]
		if swing and not swing.preview then
			local speed = select(kind.speedIndex, Try(UnitAttackSpeed, "player"))
			local known = Public(speed)
			if known and not (PublicNumber(speed) and speed > 0) then
				Clear(kind)
			elseif not swing.ready then
				if known then swing.duration = speed end
				BeginSwing(kind, swing, bars[kind])
			end
		end
	end
end

--------------------------------------------------------------------------------
-- In range line
--------------------------------------------------------------------------------

local function DistanceText(low, high)
	if low and high then return ("%d-%d yd"):format(low, high) end
	if low then return ("%d+ yd"):format(low) end
end

local function ShowRangeHint(canHit, low, high, minNeeded, maxNeeded, tooClose)
	local text = canHit and "In range" or tooClose and "Too close" or "Out of range"
	local distance = DistanceText(low, high)
	if distance then text = text .. ": " .. distance end
	local needed = tooClose and minNeeded or maxNeeded
	if not canHit and needed and needed > 0 then
		text = text .. (" (need %d)"):format(needed)
	end
	rangeHint.text:SetText(text)
	if canHit then
		rangeHint.text:SetTextColor(0.40, 1.00, 0.40)
	else
		rangeHint.text:SetTextColor(1.00, 0.30, 0.25)
	end
	rangeHint.text:Show()
end

-- With no shot running, the ranged bar shows full while there's a target to
-- shoot at (inRange true or false), and fades when there isn't (nil).
local function UpdateIdleBar(kind, inRange, tooClose)
	local bar = bars[kind]
	if not bar or editing or swings[kind] then return end
	if inRange == nil or not Wanted(kind) or not db.showOnTarget then
		if bar.idle then
			bar.idle = nil
			bar:FadeOut()
		end
		return
	end
	if not bar.idle then
		bar.idle = true
		SetWindup(kind, bar, false)
		PlaceWindupMark(kind, bar, WeaponSpeed(kind) or kind.preview)
		bar:ShowBar()
		bar:Still(1)
	end
	bar.status:SetAlpha(inRange and 1 or 0.35)
	bar:SetTexts(kind.title, inRange and "Ready" or tooClose and "Too close" or "Out of range")
end

-- An opener like Arcane Shot turns auto shot on without the bar seeing a
-- START_AUTOREPEAT_SPELL it can rely on, so it also asks the game whether auto
-- shot is on (Blizzard's gamepad bar reads C_Spell.IsAutoRepeatSpell the same
-- way) and starts the first shot when it switches on.
local autoWasOn = false

function WatchAutoShot()
	if not rangeSpell then return end
	local on = Try(C_Spell.IsAutoRepeatSpell, rangeSpell)
	if not Public(on) or type(on) ~= "boolean" then return end
	if on and not autoWasOn then
		if debugging then DebugEvent("AUTO_SHOT_ON_POLL") end
		autoShooting = true
		StartFirstShot()
	end
	autoWasOn = on
end

local function UpdateRanged()
	local kind = byType[Enum.PlayerSwingType.Ranged]
	local swing = swings[kind]
	local sample = (editing and Wanted(kind)) or (swing and swing.preview)
	local inRange, low, high, minNeeded, maxNeeded, tooClose
	if not editing then inRange, low, high, minNeeded, maxNeeded, tooClose = ReadRange(kind) end
	UpdateIdleBar(kind, inRange, tooClose)
	WeaponSpeed(kind)          -- keeps the speed fresh while it can be read
	WatchAutoShot()

	if not db.showRangeHint then
		rangeHint.text:Hide()
	elseif sample then
		ShowRangeHint(true, 25, 30)
	else
		if inRange ~= nil then
			ShowRangeHint(inRange, low, high, minNeeded, maxNeeded, tooClose)
		else
			rangeHint.text:Hide()   -- no target, or it can't be attacked
		end
	end
end

-- UnitClass is only sure to answer once the player is in the world.
local function SetUpRangeHint()
	if rangeHint then return end
	local class = select(2, Try(UnitClass, "player"))
	if not Public(class) or not RANGED_CLASSES[class] then return end
	rangeSpell = RANGED_CLASSES[class]

	local bar = GetBar(byType[Enum.PlayerSwingType.Ranged])
	rangeHint = CreateFrame("Frame", "PredUISwingRangeHint", UIParent)
	rangeHint:SetSize(BAR_W, BAR_H)
	rangeHint:SetPoint("TOP", bar.status, "BOTTOM", 0, -4)
	rangeHint:SetFrameStrata("MEDIUM")
	rangeHint.text = S.Text(rangeHint, 12, true)
	rangeHint.text:SetPoint("CENTER")
	rangeHint.text:Hide()
	S.Scaled(rangeHint)

	local waited = RANGE_CHECK_INTERVAL
	rangeHint:SetScript("OnUpdate", function(_, elapsed)
		waited = waited + elapsed
		if waited < RANGE_CHECK_INTERVAL then return end
		waited = 0
		UpdateRanged()
	end)
end

--------------------------------------------------------------------------------
-- Blizzard's bars
--------------------------------------------------------------------------------

local hookedKinds = {}         -- [Blizzard's frame] = kind (kept here: writing to an Edit Mode frame taints it)

local function FadeBlizzardBar(frame)
	local kind = hookedKinds[frame]
	local hide = M.enabled and db.hideBlizzard and kind and Wanted(kind) and not frame.isInEditMode
	frame:SetAlpha(hide and 0 or 1)
end

local function HookBlizzard()
	for _, kind in ipairs(KINDS) do
		local frame = _G[kind.frame]
		if frame and frame.UpdateShownState and not hookedKinds[frame] then
			hookedKinds[frame] = kind
			hooksecurefunc(frame, "UpdateShownState", FadeBlizzardBar)
		end
	end
end

local function RefreshBlizzard()
	for frame in pairs(hookedKinds) do FadeBlizzardBar(frame) end
end

-- Turning a bar off clears it and gives that weapon back to Blizzard's bar.
local function OnBarOptionChanged()
	for _, kind in ipairs(KINDS) do
		if not Wanted(kind) then Clear(kind) end
	end
	RefreshBlizzard()
end

--------------------------------------------------------------------------------
-- Commands (slash and settings menu)
--------------------------------------------------------------------------------

function M.Test()
	if editing then
		M.Say("Edit Mode is open: the bars are already showing.")
		return
	end
	for _, swing in pairs(swings) do
		if not swing.preview then
			M.Say("you're swinging, so the bars are busy.")
			return
		end
	end
	for _, kind in ipairs(KINDS) do
		if Wanted(kind) then
			BeginSwing(kind, { duration = kind.preview, preview = true, rounds = PREVIEW_ROUNDS }, GetBar(kind))
		end
	end
	M.Say(db.locked and "preview running. The bars are locked: unlock them to drag them."
		or "preview running. Drag the bars where you want them.")
end

function M.ResetPosition()
	for _, kind in ipairs(KINDS) do
		db["point" .. kind.id] = nil
		if bars[kind] then S.RestorePoint(bars[kind], db, "point" .. kind.id, kind.point) end
	end
	M.Say("bar positions reset.")
end

-- /swingtimer debug: prints the events the bars run on, with times, so a bar
-- that starts late can be matched against what the game actually sent.
local DEBUG_EVENTS = {
	PLAYER_SWING = true, START_AUTOREPEAT_SPELL = true, STOP_AUTOREPEAT_SPELL = true,
	UNIT_SPELLCAST_SUCCEEDED = true, PLAYER_DEAD = true, AUTO_SHOT_ON_POLL = true,
}
local DEBUG_LOG_LINES = 300        -- kept in the saved settings, newest last

function DebugEvent(event, ...)
	if not DEBUG_EVENTS[event] then return end
	local parts = {}
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		-- The cast GUID is long and tells nothing here.
		if not (event == "UNIT_SPELLCAST_SUCCEEDED" and i == 2) then
			parts[#parts + 1] = Public(v) and tostring(v) or "secret"
		end
	end
	local kind = byType[Enum.PlayerSwingType.Ranged]
	local swing = swings[kind]
	local state = swing and ("%.1f s left"):format(math.max(0, swing.ends - GetTime())) or "no shot"
	local line = ("%.2f %s %s (ranged bar: %s)"):format(GetTime() % 1000, event, table.concat(parts, " "), state)
	M.Say(line)
	local log = rawget(db, "debugLog")
	if type(log) ~= "table" then
		log = {}
		db.debugLog = log
	end
	log[#log + 1] = line
	if #log > DEBUG_LOG_LINES then table.remove(log, 1) end
end

local function OnSlash(input)
	local cmd = input:lower():match("^%s*(%S*)")
	if cmd == "test" then
		M.Test()
	elseif cmd == "lock" or cmd == "unlock" then
		db.locked = cmd == "lock"
		M.Say(db.locked and "bars locked." or "bars unlocked: drag them while they're showing.")
	elseif cmd == "reset" then
		M.ResetPosition()
	elseif cmd == "options" then
		ns.OpenSettings(M)
	elseif cmd == "debug" then
		debugging = not debugging
		if debugging then db.debugLog = {} end
		M.Say(debugging and "printing swing events (also saved on /reload). /swingtimer debug again to stop."
			or "stopped printing swing events.")
	elseif cmd == "range" then
		local function Show(v) return Public(v) and tostring(v) or "secret" end
		M.Say(("spell %s, swing %s, target exists %s"):format(
			rangeSpell and Show(Try(C_Spell.IsSpellInRange, rangeSpell, "target")) or "not a ranged class",
			Show(Try(C_SwingTimer.IsTargetWithinSwingRange, Enum.PlayerSwingType.Ranged)),
			Show(Try(UnitExists, "target"))))
	else
		M.Say("move the bars in Edit Mode, where they snap, or drag one while it's showing. Commands for /swingtimer:")
		print("  test - show a preview, to position the bars")
		print("  lock / unlock - stop or allow dragging")
		print("  reset - put the bars back in their default places")
		print("  options - open the settings")
		print("  range - print what the game says about your target's range")
		print("  debug - print swing events as they happen, to report a bar that starts late")
	end
end

M.options = {
	{ type = "checkbox", key = "showOffHand", label = "Off hand bar", tooltip = "Show a bar for your off hand weapon.", onChange = OnBarOptionChanged },
	{ type = "checkbox", key = "showRanged", label = "Ranged bar", tooltip = "Show a bar for your ranged attacks.", onChange = OnBarOptionChanged },
	{ type = "slider", key = "windup", label = "Ranged wind-up", min = 0.1, max = 1, step = 0.1, format = function(v) return ("%.1f s"):format(v) end, tooltip = "How long before a ranged shot you need to stand still. Marked on the ranged bar." },
	{ type = "checkbox", key = "showOnTarget", label = "Ranged bar with a target", tooltip = "Hunters and wand users: show the ranged bar, full and ready, whenever you target an enemy, not only once you've shot." },
	{ type = "checkbox", key = "showRangeHint", label = "Target range line", tooltip = "Hunters and wand users: show under the ranged bar whether your target is in range, about how far away it is, and the range you need." },
	{ type = "checkbox", key = "locked", label = "Lock the bars", tooltip = "Stop the bars from being dragged outside Edit Mode." },
	{ type = "checkbox", key = "hideBlizzard", label = "Hide Blizzard's bars", tooltip = "Fade out the game's own swing timer for the weapons shown here.", onChange = RefreshBlizzard },
	{ type = "button", label = "Preview", button = "Test bars", tooltip = "Show a preview so you can place the bars.", func = function() M.Test() end },
	{ type = "button", label = "Position", button = "Reset", tooltip = "Put the bars back in their default places.", func = function() M.ResetPosition() end },
}

--------------------------------------------------------------------------------
-- Start-up
--------------------------------------------------------------------------------

function M:OnAddonLoaded(name)
	if name == "Blizzard_SwingTimer" then
		HookBlizzard()
		RefreshBlizzard()
	end
end

function M:Enable()
	db = self.db
	HookBlizzard()
	EditMode.Watch(EnterEditMode, ExitEditMode)

	local events = CreateFrame("Frame")
	events:RegisterEvent("PLAYER_SWING")
	events:RegisterEvent("WEAPON_SLOT_CHANGED")
	events:RegisterEvent("PLAYER_DEAD")
	events:RegisterEvent("PLAYER_ENTERING_WORLD")
	events:RegisterEvent("START_AUTOREPEAT_SPELL")
	events:RegisterEvent("STOP_AUTOREPEAT_SPELL")
	events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
	events:SetScript("OnEvent", function(_, event, ...)
		if debugging then DebugEvent(event, ...) end
		if event == "UNIT_SPELLCAST_SUCCEEDED" then
			OnShotCast(select(3, ...))
		elseif event == "PLAYER_SWING" then
			StartSwing(...)
		elseif event == "WEAPON_SLOT_CHANGED" then
			OnWeaponChanged()
		elseif event == "START_AUTOREPEAT_SPELL" then
			autoShooting = true
			StartFirstShot()
		elseif event == "STOP_AUTOREPEAT_SPELL" then
			autoShooting = false
		else
			if event == "PLAYER_ENTERING_WORLD" then SetUpRangeHint() end
			if not editing then ClearAll() end
			RefreshBlizzard()
		end
	end)
end

SLASH_PREDUISWING1 = "/swingtimer"
SlashCmdList.PREDUISWING = ns.SlashHandler(M, OnSlash)
