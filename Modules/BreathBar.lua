--------------------------------------------------------------------------------
-- Breath Bar: Flight Timer's bar for the game's "mirror timers" (breath when
-- under water, fatigue in deep water, feign death), instead of Blizzard's small ones.
--
--   * MIRROR_TIMER_START gives the timer's value and max (in ms), its scale (how
--     fast it moves: below 0 it drains, above 0 it refills) and whether it's paused.
--     GetMirrorTimerProgress gives the live value; if it can't be read, the value
--     is worked out from the start value and the scale.
--   * MIRROR_TIMER_PAUSE / _STOP pause or end it (STOP comes when it's full again
--     or no longer applies). At login or /reload, GetMirrorTimerInfo picks up a
--     timer that's already running.
--   * Each kind of timer has its own bar and saved position.
--   * Blizzard's bars (MirrorTimerContainer) are faded out, not hidden or moved:
--     they belong to Edit Mode, and only alpha is safe to touch. Edit Mode's
--     "Timer Bars" preview still shows them.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.Style
local Public, PublicNumber, PublicString, Try = ns.Public, ns.PublicNumber, ns.PublicString, ns.Try

local M = ns.NewModule("breath", {
	title = "Breath Bar",
	notes = "Flight Timer's bar for breath, fatigue and feign death, in place of Blizzard's small bars.",
	defaults = { locked = false, hideBlizzard = true },
})

local BAR_W, BAR_H = 340, 22
local URGENT_SECONDS = 10
local MAX_TIMERS = 3           -- the game has three mirror timer slots

local KINDS = {
	BREATH     = { title = "Breath",      color = { 0.25, 0.68, 1.00 }, point = { "TOP", "TOP", 0, -120 } },
	EXHAUSTION = { title = "Fatigue",     color = { 1.00, 0.62, 0.12 }, point = { "TOP", "TOP", 0, -168 } },
	FEIGNDEATH = { title = "Feign Death", color = { 0.62, 0.62, 0.70 }, point = { "TOP", "TOP", 0, -216 } },
	DEATH      = { title = "Death",       color = { 0.62, 0.62, 0.70 }, point = { "TOP", "TOP", 0, -216 } },
}

local db
local bars = {}                -- [timer name] = bar
local timers = {}              -- [timer name] = { value=, max=, scale=, paused=, start=, label=, preview= }

local Clock = ns.Clock

--------------------------------------------------------------------------------
-- Timer values
--------------------------------------------------------------------------------

-- Current value in ms: the live one if the game gives it, else worked out.
local function CurrentValue(name, t)
	if t.preview or t.paused then
		if t.preview then
			return math.max(0, math.min(t.max, t.value + t.scale * (GetTime() - t.start) * 1000))
		end
		return t.value
	end
	local live = PublicNumber(Try(GetMirrorTimerProgress, name))
	if live then return math.max(0, math.min(t.max, live)) end
	return math.max(0, math.min(t.max, t.value + t.scale * (GetTime() - t.start) * 1000))
end

local function StatusFor(name, t, value)
	if t.preview then return db.locked and "Preview - bars are locked" or "Preview - drag the bar to move it" end
	if t.paused then return "Paused" end
	if t.scale > 0 then
		return name == "BREATH" and "Catching your breath" or "Recovering"
	end
	if value <= 0 then
		return name == "BREATH" and "Drowning!" or name == "EXHAUSTION" and "Fatigued - swim back!" or ""
	end
	if value / 1000 / -t.scale < URGENT_SECONDS then
		return name == "BREATH" and "Get to the surface" or name == "EXHAUSTION" and "Swim back to shallower water" or ""
	end
	return ""
end

--------------------------------------------------------------------------------
-- Bars
--------------------------------------------------------------------------------

local function Kind(name)
	return KINDS[name] or KINDS.FEIGNDEATH
end

local function GetBar(name)
	if bars[name] then return bars[name] end
	local kind = Kind(name)
	local bar = S.Bar({
		name = "PredUIBreathBar" .. name, width = BAR_W, height = BAR_H,
		db = db, pointKey = "point" .. name, defaultPoint = kind.point,
		locked = function() return db.locked end,
	})
	local c = kind.color
	bar:SetColor(c[1], c[2], c[3])
	bar.timerName = name
	bar:SetScript("OnUpdate", function(self)
		if self:UpdateFade() then return end
		local t = timers[self.timerName]
		if not t then return end
		local value = CurrentValue(self.timerName, t)
		local frac = t.max > 0 and value / t.max or 0
		local draining = not t.paused and t.scale < 0
		local secsLeft = draining and value / 1000 / -t.scale or value / 1000

		if t.preview and value <= 0 then
			timers[self.timerName] = nil
			self:Still(0)
			self:SetTexts(nil, "0:00", "Preview finished")
			self:FadeOut()
			return
		end

		self:SetTexts(nil, ("%s / %s"):format(Clock(math.ceil(secsLeft)), Clock(t.max / 1000)), StatusFor(self.timerName, t, value))
		self:Animate(frac, true, draining and secsLeft < URGENT_SECONDS)
	end)
	bars[name] = bar
	return bar
end

local function StartTimer(name, value, maxValue, scale, paused, label, preview)
	name, value, maxValue = PublicString(name), PublicNumber(value), PublicNumber(maxValue)
	if not (name and value and maxValue) or name == "UNKNOWN" or maxValue <= 0 then return end
	scale = PublicNumber(scale) or -1
	paused = Public(paused) and paused and paused ~= 0 or false
	label = PublicString(label)

	timers[name] = {
		value = value, max = maxValue, scale = scale ~= 0 and scale or -1,
		paused = paused, start = GetTime(), preview = preview,
	}
	local bar = GetBar(name)
	bar:ShowBar()
	bar:SetTexts(label or Kind(name).title)
end

local function StopTimer(name)
	name = PublicString(name)
	local t = name and timers[name]
	local bar = name and bars[name]
	timers[name or ""] = nil
	if not (t and bar and bar:IsShown()) then return end
	local full = t.scale > 0 or CurrentValue(name, t) >= t.max
	bar:Still(full and 1 or 0)
	bar:SetTexts(nil, nil, full and (name == "BREATH" and "Breath full" or "") or "")
	bar:FadeOut()
end

local function PauseTimer(name, paused)
	name = PublicString(name)
	local t = name and timers[name]
	if not t then return end
	-- Keep the value it reached, then carry on from there when it resumes.
	t.value = CurrentValue(name, t)
	t.start = GetTime()
	t.paused = Public(paused) and paused and paused ~= 0 or false
end

-- Timers already running at login or /reload.
local function ReadRunning()
	for i = 1, MAX_TIMERS do
		local name, value, maxValue, scale, paused, label = Try(GetMirrorTimerInfo, i)
		if PublicString(name) and name ~= "UNKNOWN" then
			StartTimer(name, value, maxValue, scale, paused, label)
		end
	end
end

--------------------------------------------------------------------------------
-- Blizzard's bars
--------------------------------------------------------------------------------

local function FadeBlizzardTimer(frame)
	local hide = M.enabled and db.hideBlizzard and frame.timer and not frame.isInEditMode
	frame:SetAlpha(hide and 0 or 1)
end

local function HookBlizzard()
	local list = MirrorTimerContainer and MirrorTimerContainer.mirrorTimers
	if type(list) ~= "table" then return end
	for _, frame in ipairs(list) do
		if frame.UpdateShownState then
			hooksecurefunc(frame, "UpdateShownState", FadeBlizzardTimer)
			FadeBlizzardTimer(frame)
		end
	end
end

local function RefreshBlizzard()
	local list = MirrorTimerContainer and MirrorTimerContainer.mirrorTimers
	if type(list) ~= "table" then return end
	for _, frame in ipairs(list) do FadeBlizzardTimer(frame) end
end

--------------------------------------------------------------------------------
-- Commands (slash and settings menu)
--------------------------------------------------------------------------------

function M.Test()
	if next(timers) and not select(2, next(timers)).preview then
		M.Say("a real timer is running, so the bars are busy.")
		return
	end
	StartTimer("BREATH", 30000, 60000, -1, 0, nil, true)
	StartTimer("EXHAUSTION", 45000, 60000, -1, 0, nil, true)
	M.Say(db.locked and "preview running. The bars are locked: unlock them to drag them."
		or "preview running. Drag the bars where you want them.")
end

function M.ResetPosition()
	for name, kind in pairs(KINDS) do
		db["point" .. name] = nil
		if bars[name] then S.RestorePoint(bars[name], db, "point" .. name, kind.point) end
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
		M.Say("drag a bar to move it. Commands for /breathbar:")
		print("  test - show a breath and a fatigue preview, to position the bars")
		print("  lock / unlock - stop or allow dragging")
		print("  reset - put the bars back in their default places")
		print("  options - open the settings")
	end
end

M.options = {
	{ type = "checkbox", key = "locked", label = "Lock the bars", tooltip = "Stop the bars from being dragged." },
	{ type = "checkbox", key = "hideBlizzard", label = "Hide Blizzard's bars", tooltip = "Fade out the game's own small breath and fatigue bars while ours show.", onChange = RefreshBlizzard },
	{ type = "button", label = "Preview", button = "Test bars", tooltip = "Show a breath and a fatigue preview so you can place the bars.", func = function() M.Test() end },
	{ type = "button", label = "Position", button = "Reset", tooltip = "Put the bars back in their default places.", func = function() M.ResetPosition() end },
}

--------------------------------------------------------------------------------
-- Start-up
--------------------------------------------------------------------------------

function M:Enable()
	db = self.db
	HookBlizzard()

	local events = CreateFrame("Frame")
	events:RegisterEvent("PLAYER_ENTERING_WORLD")
	events:RegisterEvent("MIRROR_TIMER_START")
	events:RegisterEvent("MIRROR_TIMER_STOP")
	events:RegisterEvent("MIRROR_TIMER_PAUSE")
	events:SetScript("OnEvent", function(_, event, ...)
		if event == "MIRROR_TIMER_START" then
			StartTimer(...)
		elseif event == "MIRROR_TIMER_STOP" then
			StopTimer(...)
		elseif event == "MIRROR_TIMER_PAUSE" then
			PauseTimer(...)
		else
			ReadRunning()
			RefreshBlizzard()
		end
	end)
end

SLASH_PREDUIBREATH1 = "/breathbar"
SlashCmdList.PREDUIBREATH = ns.SlashHandler(M, OnSlash)
