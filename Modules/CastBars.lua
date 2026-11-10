--------------------------------------------------------------------------------
-- Cast Bars: PredUI bars for your own, your target's and your focus's casts, in
-- place of Blizzard's.
--
--   * UNIT_SPELLCAST_* events drive each bar, and UnitCastingInfo /
--     UnitChannelInfo give the spell and its times. Each unit has its own event
--     frame, because the events' payload can be secret for other units.
--   * Other units' cast details are secret to addons. Secrets can't be compared
--     or tested, but font strings and textures do take them, so the spell name
--     and icon still show. For the fill, UnitCastingDuration goes to the bar's
--     SetTimerDuration; Blizzard's docs say that may refuse secrets from addons,
--     and then the bar shows dimmed with the spell name and no countdown. A
--     secret "can't interrupt" flag picks the colour via SetVertexColorFromBoolean.
--   * Stop events can't always be matched to a secret cast, so a bar in that
--     state also checks now and then that the unit is still casting.
--   * A craft that Craft Timer is showing isn't drawn here too.
--   * Blizzard's bars are faded out, not hidden or moved: they belong to Edit
--     Mode, and only alpha is safe to touch. Edit Mode still shows them.
--   * Our bars ignore the mouse unless a preview is running, so a bar in the
--     middle of the screen can't swallow clicks.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.Style
local EditMode = ns.EditMode
local Public, PublicNumber, PublicString, Try = ns.Public, ns.PublicNumber, ns.PublicString, ns.Try

local M = ns.NewModule("cast", {
	title = "Cast Bars",
	notes = "PredUI bars for your own, your target's and your focus's casts, in place of Blizzard's.",
	defaults = { locked = false, hideBlizzard = true, showPlayer = true, showTarget = true, showFocus = true },
})

local CAST_COLOR    = { 1.00, 0.72, 0.20 }
local CHANNEL_COLOR = { 0.40, 0.70, 1.00 }
local LOCKED_COLOR  = { 0.62, 0.62, 0.70 }  -- can't be interrupted
local DONE_COLOR    = { 0.35, 0.85, 0.40 }
local FAILED_COLOR  = { 0.90, 0.20, 0.20 }

local DONE_FADE, FAILED_FADE = 0.35, 1.0    -- seconds a finished bar takes to go
local RECHECK = 0.25                        -- seconds between "still casting?" checks
local LATE = 0.5                            -- seconds past a cast's end before rechecking it
local PREVIEW_SECONDS, PREVIEW_ROUNDS = 4, 4

local KINDS = {
	{ unit = "player", option = "showPlayer", title = "Player", width = 300, height = 20, point = { "BOTTOM", "BOTTOM", 0, 200 },
	  frames = function() return { PlayerCastingBarFrame, OverlayPlayerCastingBarFrame } end },
	{ unit = "target", option = "showTarget", title = "Target", width = 260, height = 18, point = { "CENTER", "CENTER", 0, 150 },
	  frames = function() return { TargetFrame and TargetFrame.spellbar } end },
	{ unit = "focus", option = "showFocus", title = "Focus", width = 260, height = 18, point = { "CENTER", "CENTER", 0, 195 },
	  frames = function() return { FocusFrame and FocusFrame.spellbar } end },
}

local db
local bars = {}                -- [kind] = bar
local blizzard = {}            -- [Blizzard's cast bar] = kind
local muted = {}               -- [Blizzard's cast bar] = true while we hold it at alpha 0
local editing = false          -- Edit Mode is open

--------------------------------------------------------------------------------
-- Reading a cast
--------------------------------------------------------------------------------

-- Secret values can't be tested, but a secret one is always there.
local function Exists(v)
	return not Public(v) or v ~= nil
end

local function ReadCast(unit)
	local name, text, icon, startMS, endMS, trade, castID, notInt, spellID = Try(UnitCastingInfo, unit)
	if Exists(name) then
		return { name = name, text = text, icon = icon, startMS = startMS, endMS = endMS, trade = trade,
			castID = castID, notInt = notInt, spellID = spellID }
	end
	name, text, icon, startMS, endMS, trade, notInt, spellID = Try(UnitChannelInfo, unit)
	if Exists(name) then
		return { name = name, text = text, icon = icon, startMS = startMS, endMS = endMS, trade = trade,
			notInt = notInt, spellID = spellID, channel = true }
	end
end

-- Craft Timer has its own bar for the recipe it's counting.
local function ShownByCraftTimer(c)
	local craft = ns.byKey.craft
	return craft and craft.enabled and craft.IsShowing and craft.IsShowing(PublicNumber(c.spellID))
end

--------------------------------------------------------------------------------
-- Bars
--------------------------------------------------------------------------------

local function Clear(bar)
	bar.cast, bar.ended, bar.fadeEnd = nil, nil, nil
	bar:Hide()
	bar:EnableMouse(false)
end

local function StartFade(bar, seconds)
	bar.fadeLength = seconds
	bar.fadeEnd = GetTime() + seconds
end

local function SetColors(bar, c)
	local color = c.channel and CHANNEL_COLOR or CAST_COLOR
	if bar.kind.unit ~= "player" then
		if not Public(c.notInt) then
			-- Can't be read, but a texture can pick its colour from it.
			bar:SetColor(color[1], color[2], color[3])
			pcall(function()
				bar.status:GetStatusBarTexture():SetVertexColorFromBoolean(c.notInt,
					CreateColor(LOCKED_COLOR[1], LOCKED_COLOR[2], LOCKED_COLOR[3]),
					CreateColor(color[1], color[2], color[3]))
			end)
			return
		elseif c.notInt then
			color = LOCKED_COLOR
		end
	end
	bar:SetColor(color[1], color[2], color[3])
end

local function StartCast(bar)
	local c = ReadCast(bar.kind.unit)
	if not c then return false end
	if ShownByCraftTimer(c) then
		Clear(bar)
		return true
	end

	bar.cast, bar.ended, bar.fadeEnd = c, nil, nil
	bar:ShowBar()
	bar:EnableMouse(false)
	SetColors(bar, c)

	if Public(c.text) and Public(c.name) then
		bar:SetTexts(PublicString(c.text) or PublicString(c.name) or "")
	else
		Try(bar.title.SetText, bar.title, c.text)
	end
	Try(bar.icon.SetTexture, bar.icon, c.icon)

	local startMS, endMS = PublicNumber(c.startMS), PublicNumber(c.endMS)
	if startMS and endMS and endMS > startMS then
		c.start, c.ends = startMS / 1000, endMS / 1000
		bar.status:SetAlpha(1)
		return true
	end

	-- The times are secret: hand the bar the game's own timer, if it takes it.
	c.nextCheck = GetTime() + RECHECK
	local duration = Try(c.channel and UnitChannelDuration or UnitCastingDuration, bar.kind.unit)
	if Exists(duration) then
		c.timer = pcall(bar.status.SetTimerDuration, bar.status, duration, Enum.StatusBarInterpolation.Immediate,
			c.channel and Enum.StatusBarTimerDirection.RemainingTime or Enum.StatusBarTimerDirection.ElapsedTime)
		c.duration = c.timer and duration or nil
	end
	bar:SetTexts(nil, "")
	if not c.timer then
		bar.status:SetValue(1)
		bar.status:SetAlpha(0.35)
		bar.spark:Hide()
	end
	bar.sheen:Hide()
	return true
end

local function EndCast(bar)
	local c = bar.cast
	bar.cast, bar.ended = nil, c
	bar:Still(c.channel and 0 or 1)
	if not c.channel then bar:SetColor(DONE_COLOR[1], DONE_COLOR[2], DONE_COLOR[3]) end
	bar:SetTexts(nil, "")
	StartFade(bar, DONE_FADE)
end

local function ShowFailed(bar, text)
	bar.cast, bar.ended = nil, nil
	bar:Still(1)
	bar.status:SetAlpha(1)
	bar:SetColor(FAILED_COLOR[1], FAILED_COLOR[2], FAILED_COLOR[3])
	bar:ResetTexts()
	bar:SetTexts(text, "")
	StartFade(bar, FAILED_FADE)
end

-- Is this event's cast the one on the bar? A secret id can't be compared, so
-- it's taken to be.
local function SameCast(c, guid)
	if not (Public(guid) and Public(c.castID)) then return true end
	return c.castID ~= nil and guid == c.castID
end

local function OnStop(bar, event, guid, interruptedBy)
	local c = bar.cast
	if not c or c.preview then return end
	if c.channel ~= (event == "UNIT_SPELLCAST_CHANNEL_STOP" or nil) then return end
	if not c.channel and not SameCast(c, guid) then return end
	if c.channel and Public(interruptedBy) and interruptedBy ~= nil then
		ShowFailed(bar, INTERRUPTED or "Interrupted")
	else
		EndCast(bar)
	end
end

local function OnFailed(bar, event, guid)
	-- The stop event can come first, so a cast that has just ended still counts.
	local c = bar.cast or bar.ended
	if not c or c.preview or not bar:IsShown() or not SameCast(c, guid) then return end
	ShowFailed(bar, event == "UNIT_SPELLCAST_FAILED" and (FAILED or "Failed") or (INTERRUPTED or "Interrupted"))
end

local function UpdatePreview(bar, c, now)
	if now < c.ends then return end
	c.rounds = c.rounds - 1
	if c.rounds > 0 then
		c.start, c.ends = now, now + PREVIEW_SECONDS
	else
		bar.cast = nil
		bar:Still(1)
		bar:SetTexts(nil, "")
		bar:EnableMouse(false)
		StartFade(bar, DONE_FADE)
	end
end

local function Gone(bar)
	EndCast(bar)
end

local function ShowSecretTime(bar, c)
	bar.time:SetFormattedText("%.1f", c.duration:GetRemainingDuration())
end

local function OnUpdate(bar)
	local now = GetTime()
	if bar.fadeEnd then
		local left = (bar.fadeEnd - now) / bar.fadeLength
		if left <= 0 then
			Clear(bar)
		else
			bar:SetAlpha(left)
		end
		return
	end

	local c = bar.cast
	if not c then return end

	if not c.start then
		if now >= c.nextCheck then
			c.nextCheck = now + RECHECK
			if not ReadCast(bar.kind.unit) then
				Gone(bar)
				return
			end
			if c.duration and not pcall(ShowSecretTime, bar, c) then c.duration = nil end
		end
		bar.glow:SetAlpha(0.6 + math.sin(now * 2) * 0.18)
		return
	end

	if c.preview then UpdatePreview(bar, c, now) end
	if not bar.cast then return end

	local length = c.ends - c.start
	local elapsed = math.max(0, math.min(length, now - c.start))
	local left = length - elapsed
	bar:SetTexts(nil, ("%.1f"):format(left))
	bar:Animate((c.channel and left or elapsed) / length, true, false)

	-- A missed stop event mustn't leave a bar up for good.
	if not c.preview and now > c.ends + LATE and not ReadCast(bar.kind.unit) then Gone(bar) end
end

local function ShowCurrent(bar)
	if editing or (bar.cast and bar.cast.preview) then return end
	if db[bar.kind.option] and StartCast(bar) then return end
	Clear(bar)
end

local STARTS = {
	UNIT_SPELLCAST_START = true, UNIT_SPELLCAST_CHANNEL_START = true, UNIT_SPELLCAST_DELAYED = true,
	UNIT_SPELLCAST_CHANNEL_UPDATE = true, UNIT_SPELLCAST_INTERRUPTIBLE = true, UNIT_SPELLCAST_NOT_INTERRUPTIBLE = true,
}

local function OnUnitEvent(self, event, _, guid, _, interruptedBy)
	local bar = self.bar
	if editing or not db[bar.kind.option] then return end
	if STARTS[event] then
		StartCast(bar)
	elseif event == "UNIT_SPELLCAST_STOP" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
		OnStop(bar, event, guid, interruptedBy)
	elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_INTERRUPTED" then
		OnFailed(bar, event, guid)
	end
end

local function BuildBar(kind)
	local bar = S.Bar({
		name = "PredUICastBar" .. kind.title, width = kind.width, height = kind.height, icon = true,
		db = db, pointKey = "point" .. kind.title, defaultPoint = kind.point,
		locked = function() return db.locked end,
	})
	bar:EnableMouse(false)   -- after S.Bar: its drag scripts turn the mouse on
	bar.kind = kind
	bar:SetScript("OnUpdate", OnUpdate)
	EditMode.Add(bar, kind.title .. " Cast", bar.status, function(self)
		S.SavePoint(self, db, "point" .. kind.title)
	end)

	local events = CreateFrame("Frame")
	events.bar = bar
	for event in pairs(STARTS) do events:RegisterUnitEvent(event, kind.unit) end
	events:RegisterUnitEvent("UNIT_SPELLCAST_STOP", kind.unit)
	events:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", kind.unit)
	events:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", kind.unit)
	events:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", kind.unit)
	events:SetScript("OnEvent", OnUnitEvent)

	bars[kind] = bar
end

--------------------------------------------------------------------------------
-- Blizzard's bars
--------------------------------------------------------------------------------

local function Wanted(frame)
	local kind = blizzard[frame]
	return M.enabled and kind and db.hideBlizzard and db[kind.option] and not frame.isInEditMode
end

-- ApplyAlpha(1) runs at every cast start; a bar at alpha 0 skips its fade-out.
local function Mute(frame)
	if Wanted(frame) then
		frame:SetAlpha(0)
		muted[frame] = true
	end
end

local function HookBlizzard()
	for _, kind in ipairs(KINDS) do
		for _, frame in pairs(kind.frames()) do
			if frame.ApplyAlpha and not blizzard[frame] then
				blizzard[frame] = kind
				hooksecurefunc(frame, "ApplyAlpha", Mute)
				frame:HookScript("OnShow", Mute)
			end
		end
	end
end

function M.RefreshBlizzard()
	for frame in pairs(blizzard) do
		if Wanted(frame) then
			if frame:IsShown() then Mute(frame) end
		elseif muted[frame] then
			muted[frame] = nil
			if frame:IsShown() then frame:SetAlpha(1) end
		end
	end
end

local function RefreshAll()
	M.RefreshBlizzard()
	for _, bar in pairs(bars) do ShowCurrent(bar) end
end

--------------------------------------------------------------------------------
-- Edit Mode
--------------------------------------------------------------------------------

local function EnterEditMode()
	editing = true
	M.RefreshBlizzard()
	for kind, bar in pairs(bars) do
		Clear(bar)
		if db[kind.option] then
			bar:ShowBar()
			bar:SetColor(CAST_COLOR[1], CAST_COLOR[2], CAST_COLOR[3])
			bar.status:SetAlpha(1)
			bar.icon:SetTexture(136243)
			bar:Still(0.6)
			bar:SetTexts(kind.title .. " Cast", "1.2")
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
	RefreshAll()
end

--------------------------------------------------------------------------------
-- Commands (slash and settings menu)
--------------------------------------------------------------------------------

function M.Test()
	if editing then return end
	local shown
	local now = GetTime()
	for kind, bar in pairs(bars) do
		if db[kind.option] and not (bar.cast and not bar.cast.preview) then
			local c = { preview = true, start = now, ends = now + PREVIEW_SECONDS, rounds = PREVIEW_ROUNDS, channel = kind.unit == "focus" or nil }
			bar.cast, bar.ended, bar.fadeEnd = c, nil, nil
			bar:ShowBar()
			bar:EnableMouse(true)
			SetColors(bar, c)
			bar.status:SetAlpha(1)
			bar.icon:SetTexture(136243)
			bar:SetTexts(kind.title .. " Cast")
			shown = true
		end
	end
	if not shown then
		M.Say("no bars to preview: they're turned off or busy.")
	else
		M.Say(db.locked and "preview running. The bars are locked: unlock them to drag them."
			or "preview running. Drag the bars where you want them, or use Edit Mode.")
	end
end

function M.ResetPosition()
	for kind, bar in pairs(bars) do
		db["point" .. kind.title] = nil
		S.RestorePoint(bar, db, "point" .. kind.title, kind.point)
	end
	M.Say("bar positions reset.")
end

local function OnSlash(input)
	local cmd = input:lower():match("^%s*(%S*)")
	if cmd == "test" then
		M.Test()
	elseif cmd == "lock" or cmd == "unlock" then
		db.locked = cmd == "lock"
		M.Say(db.locked and "bars locked." or "bars unlocked: drag them during a preview.")
	elseif cmd == "reset" then
		M.ResetPosition()
	elseif cmd == "options" then
		ns.OpenSettings(M)
	else
		M.Say("move the bars in a preview or in Edit Mode. Commands for /castbars:")
		print("  test - show a preview, to position the bars")
		print("  lock / unlock - stop or allow dragging")
		print("  reset - put the bars back in their default places")
		print("  options - open the settings")
	end
end

M.options = {
	{ type = "checkbox", key = "showFocus", label = "Focus cast bar", tooltip = "Show your focus's casts on a PredUI bar.", onChange = RefreshAll },
	{ type = "checkbox", key = "hideBlizzard", label = "Hide Blizzard's bars", tooltip = "Fade out the game's own cast bars for the units that have a PredUI bar.", onChange = function() M.RefreshBlizzard() end },
	{ type = "checkbox", key = "locked", label = "Lock the bars", tooltip = "Stop the bars from being dragged during a preview. Edit Mode can still move them." },
	{ type = "checkbox", key = "showPlayer", label = "Player cast bar", tooltip = "Show your own casts on a PredUI bar.", onChange = RefreshAll },
	{ type = "button", label = "Position", button = "Reset", tooltip = "Put the bars back in their default places.", func = function() M.ResetPosition() end },
	{ type = "button", label = "Preview", button = "Test bars", tooltip = "Show sample casts so you can place the bars.", func = function() M.Test() end },
	{ type = "checkbox", key = "showTarget", label = "Target cast bar", tooltip = "Show your target's casts on a PredUI bar.", onChange = RefreshAll },
}

--------------------------------------------------------------------------------
-- Start-up
--------------------------------------------------------------------------------

function M:Enable()
	db = self.db
	for _, kind in ipairs(KINDS) do BuildBar(kind) end
	HookBlizzard()
	EditMode.Watch(EnterEditMode, ExitEditMode)

	local events = CreateFrame("Frame")
	events:RegisterEvent("PLAYER_ENTERING_WORLD")
	events:RegisterEvent("PLAYER_TARGET_CHANGED")
	events:RegisterEvent("PLAYER_FOCUS_CHANGED")
	events:SetScript("OnEvent", function(_, event)
		if event == "PLAYER_ENTERING_WORLD" then
			HookBlizzard()
			RefreshAll()
			return
		end
		local unit = event == "PLAYER_TARGET_CHANGED" and "target" or "focus"
		for kind, bar in pairs(bars) do
			if kind.unit == unit then ShowCurrent(bar) end
		end
	end)
end

SLASH_PREDUICAST1 = "/castbars"
SlashCmdList.PREDUICAST = ns.SlashHandler(M, OnSlash)
