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
	defaults = { locked = false, hideBlizzard = true, showOffHand = true, showRanged = true },
})

local BAR_W, BAR_H = 260, 16
local RANGE_CHECK_INTERVAL = 0.2   -- seconds between range checks on a waiting bar
local PREVIEW_ROUNDS = 5           -- swings the preview runs, so there's time to drag

local KINDS = {
	{ id = "MainHand", swing = Enum.PlayerSwingType.MainHand, title = "Main Hand", speedIndex = 1,
	  frame = "SwingTimerMainHandFrame", color = { 1.00, 0.72, 0.20 }, point = { "CENTER", "CENTER", 0, -180 }, preview = 2.6 },
	{ id = "OffHand", swing = Enum.PlayerSwingType.OffHand, title = "Off Hand", speedIndex = 2, option = "showOffHand",
	  frame = "SwingTimerOffHandFrame", color = { 0.45, 0.80, 0.45 }, point = { "CENTER", "CENTER", 0, -204 }, preview = 1.8 },
	{ id = "Ranged", swing = Enum.PlayerSwingType.Ranged, title = "Ranged", speedIndex = 3, option = "showRanged",
	  frame = "SwingTimerRangedFrame", color = { 0.40, 0.70, 1.00 }, point = { "CENTER", "CENTER", 0, -228 }, preview = 3.0 },
}

local byType = {}              -- [Enum.PlayerSwingType] = kind
for _, kind in ipairs(KINDS) do byType[kind.swing] = kind end

local db
local bars = {}                -- [kind] = bar
local swings = {}              -- [kind] = { duration=, ends=, ready=, preview=, rounds= }
local editing = false          -- Edit Mode is open

local function Wanted(kind)
	return not kind.option or db[kind.option]
end

--------------------------------------------------------------------------------
-- Bars
--------------------------------------------------------------------------------

local function IsOutOfRange(kind)
	local inRange = Try(C_SwingTimer.IsTargetWithinSwingRange, kind.swing)
	-- nil means no check could be made, which isn't the same as out of range.
	return Public(inRange) and inRange == false
end

local function BeginSwing(kind, swing, bar)
	swing.ready = nil
	swing.ends = GetTime() + swing.duration
	swings[kind] = swing
	bar:ShowBar()
	bar:SetTexts(kind.title)
end

local function Finish(kind, bar)
	swings[kind] = nil
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
	local away = IsOutOfRange(kind)
	bar.status:SetAlpha(away and 0.35 or 1)
	bar:SetTexts(nil, away and "Out of range" or "0.0")
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
	if not kind or not Wanted(kind) then return end
	BeginSwing(kind, { duration = duration }, GetBar(kind))
end

local function Clear(kind)
	swings[kind] = nil
	if bars[kind] then bars[kind]:Hide() end
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
	else
		M.Say("move the bars in Edit Mode, where they snap, or drag one while it's showing. Commands for /swingtimer:")
		print("  test - show a preview, to position the bars")
		print("  lock / unlock - stop or allow dragging")
		print("  reset - put the bars back in their default places")
		print("  options - open the settings")
	end
end

M.options = {
	{ type = "checkbox", key = "showOffHand", label = "Off hand bar", tooltip = "Show a bar for your off hand weapon.", onChange = OnBarOptionChanged },
	{ type = "checkbox", key = "showRanged", label = "Ranged bar", tooltip = "Show a bar for your ranged attacks.", onChange = OnBarOptionChanged },
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
	events:SetScript("OnEvent", function(_, event, ...)
		if event == "PLAYER_SWING" then
			StartSwing(...)
		elseif event == "WEAPON_SLOT_CHANGED" then
			OnWeaponChanged()
		else
			if not editing then ClearAll() end
			RefreshBlizzard()
		end
	end)
end

SLASH_PREDUISWING1 = "/swingtimer"
SlashCmdList.PREDUISWING = ns.SlashHandler(M, OnSlash)
