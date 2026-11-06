--------------------------------------------------------------------------------
-- Craft Timer: how long a bulk craft will take, and a countdown while it runs.
--
--   * The Professions window gets a line next to the Create buttons with the
--     total time for the amount in the box, and for "Create All".
--   * C_TradeSkillUI.CraftRecipe (and the enchant/salvage variants) are hooked,
--     so every craft, single or bulk, from the window or another addon, shows a bar: crafts
--     done and time left. It's Flight Timer's bar (glow, sheen, spark) in amber,
--     with the recipe's icon and a divider at each craft: the fill's edge passes
--     one each time a craft finishes.
--   * While our bar runs, Blizzard's cast bar is hidden (optional). Its own
--     ApplyAlpha, which runs at every cast start, is hooked to set alpha 0, so
--     nothing of Blizzard's is replaced; Edit Mode still shows it.
--   * Each recipe's real time per craft (cast plus the small gap before the next
--     one starts) is measured during bulk crafts and saved account-wide. Until a
--     recipe has been measured, its time is the spell's cast time plus a typical
--     gap, and is shown with a "~".
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.Style
local Public, PublicNumber, Try, Clock = ns.Public, ns.PublicNumber, ns.Try, ns.Clock

local M = ns.NewModule("craft", {
	title = "Craft Timer",
	notes = "Shows how long a bulk craft will take, and a countdown bar while it runs. Learns each recipe's real time.",
	defaults = { locked = false, showLabel = true, hideCastBar = true, ticks = true },
})

local BAR_W, BAR_H = 320, 22
local DEFAULT_POINT = { "CENTER", "CENTER", 0, -200 }
local GAP_GUESS = 0.35         -- seconds between one craft ending and the next starting
local LEARN_WEIGHT = 0.3       -- how much one new measurement moves the learned time
local URGENT_SECONDS = 5       -- the glow pulses faster in the last few seconds
local GOLD = S.GOLD

local AMBER = { 0.95, 0.62, 0.12 }
local DONE  = { 0.30, 0.85, 0.35 }
local STOP  = { 0.85, 0.20, 0.20 }

local db
local run                      -- the bulk craft in progress
local bar, label, page

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function CastSeconds(spellID)
	local info = Try(C_Spell and C_Spell.GetSpellInfo, spellID)
	local ms = Public(info) and type(info) == "table" and PublicNumber(info.castTime)
	return ms and ms / 1000 or 0
end

-- Seconds per craft, and whether that's a measured time.
local function PerCraft(spellID)
	if not spellID then return nil end
	local learned = db.learned[spellID]
	if learned then return learned, true end
	return CastSeconds(spellID) + GAP_GUESS, false
end

--------------------------------------------------------------------------------
-- Blizzard's cast bar
--------------------------------------------------------------------------------

local castBars = {}            -- [frame] = true for the cast bars we've hooked
local muted = {}               -- [frame] = true while we hold it at alpha 0

local function Muting()
	return db.hideCastBar and run and not run.finished and not run.test
end

-- Only the recipe being crafted is hidden; any other cast keeps Blizzard's bar.
-- The bar sets spellID before it calls ApplyAlpha at cast start.
local function Mute(frame)
	if Muting() and not frame.isInEditMode and frame.spellID == run.spellID then
		frame:SetAlpha(0)
		muted[frame] = true
	end
end

-- The player's cast bar, and the overlay one the crafting orders page uses instead.
local function HookCastBars()
	for _, frame in ipairs({ PlayerCastingBarFrame, OverlayPlayerCastingBarFrame }) do
		if frame and not castBars[frame] and frame.ApplyAlpha then
			castBars[frame] = true
			hooksecurefunc(frame, "ApplyAlpha", Mute)
			frame:HookScript("OnShow", Mute)
		end
	end
end

-- A run started or ended: mute now, or give back a bar we muted.
local function UpdateCastBars()
	for frame in pairs(castBars) do
		if Muting() then
			if frame:IsShown() then Mute(frame) end
		elseif muted[frame] then
			muted[frame] = nil
			if frame:IsShown() then frame:SetAlpha(1) end
		end
	end
end

--------------------------------------------------------------------------------
-- The countdown bar
--------------------------------------------------------------------------------

-- Seconds left in the cast of `spellID` that's running now, if it is.
local function CurrentCastLeft(spellID)
	local _, _, _, _, endMS, _, _, _, castSpell = Try(UnitCastingInfo, "player")
	endMS, castSpell = PublicNumber(endMS), PublicNumber(castSpell)
	if endMS and (not castSpell or castSpell == spellID) then
		return math.max(0, endMS / 1000 - GetTime())
	end
end

local function TimeLeft()
	if run.test then
		return math.max(0, run.started + run.total * run.per - GetTime())
	end
	local remaining = run.total - run.done
	if remaining <= 0 then return 0 end
	local castLeft = CurrentCastLeft(run.spellID)
	if castLeft then
		return castLeft + (remaining - 1) * run.per
	end
	return remaining * run.per
end

local function Title()
	return ("%s  %s%d/%d|r"):format(run.name, GOLD, run.done, run.total)
end

local function Describe()
	if run.test then
		return M.db.locked and "Test - bar is locked" or "Test - drag the bar to move it"
	elseif run.measured then
		return ("Learned time: %.1fs a craft"):format(run.per)
	end
	return ("Estimate: ~%.1fs a craft - learning this recipe now"):format(run.per)
end

local FinishRun                -- defined below; UpdateBar can end an idle run

local function UpdateBar()
	if not run then return end
	if bar:UpdateFade() then
		if not bar:IsShown() then run = nil end
		return
	end
	if run.finished then return end
	local now = GetTime()

	if run.test then
		run.done = math.min(run.total, math.floor((now - run.started) / run.per))
	end

	local left = TimeLeft()
	local elapsed = now - run.started

	-- Nothing being cast and no time left: the craft never started or the queue
	-- stopped without telling us. Don't leave the bar (or a hidden cast bar) up.
	if not run.test and left <= 0 and not CurrentCastLeft(run.spellID) then
		run.idleSince = run.idleSince or now
		if now - run.idleSince > 3 then return FinishRun() end
	else
		run.idleSince = nil
	end
	local frac = elapsed + left > 0 and left / (elapsed + left) or 0
	bar:SetTexts(Title(), (run.measured and "" or "~") .. Clock(left) .. " left", Describe())
	bar:Animate(frac, true, left < URGENT_SECONDS)

	if run.test and run.done >= run.total then
		run.finished = now
		bar:SetColor(DONE[1], DONE[2], DONE[3])
		bar:Still(0)
		bar:SetTexts(Title(), "Done", "Test finished")
		bar:FadeOut()
	end
end

local function StartRun(spellID, name, icon, count, test)
	local per, measured = PerCraft(spellID)
	run = {
		spellID = spellID, name = name or "Crafting", total = count, done = 0,
		per = per or 3, measured = measured, started = GetTime(), test = test,
	}
	bar.icon:SetTexture(icon or 134400)
	bar:SetColor(AMBER[1], AMBER[2], AMBER[3])
	bar:SetTicks(db.ticks and count or 0)
	bar:ShowBar()
	UpdateBar()
	UpdateCastBars()
end

function FinishRun(reason)
	if not run or run.finished then return end
	run.finished = GetTime()
	UpdateCastBars()
	local took = Clock(GetTime() - run.started)
	if run.done >= run.total then
		bar:SetColor(DONE[1], DONE[2], DONE[3])
		bar:Still(0)
		bar:SetTexts(Title(), "Done", ("Crafted %d in %s"):format(run.total, took))
		if run.total > 1 then
			M.Say(("crafted %d x %s in %s."):format(run.total, run.name, took))
		end
	else
		bar:SetColor(STOP[1], STOP[2], STOP[3])
		bar:Still(bar.status:GetValue())
		bar:SetTexts(Title(), reason or "Stopped", ("Stopped after %d of %d (%s)"):format(run.done, run.total, took))
	end
	bar:FadeOut()
end

--------------------------------------------------------------------------------
-- Learning each recipe's real time
--------------------------------------------------------------------------------

local function OnCastStart(spellID)
	local now = GetTime()
	if run.lastStart then
		local sample = now - run.lastStart
		-- Ignore anything far off the expected time (lag spikes, a stalled queue).
		local expected = CastSeconds(spellID) + GAP_GUESS
		if sample > expected * 0.5 and sample < expected * 3 + 2 then
			local old = db.learned[spellID]
			db.learned[spellID] = old and (old * (1 - LEARN_WEIGHT) + sample * LEARN_WEIGHT) or sample
			run.per, run.measured = db.learned[spellID], true
		end
	end
	run.lastStart = now
end

--------------------------------------------------------------------------------
-- The line on the Professions window
--------------------------------------------------------------------------------

local function SelectedRecipeID()
	local form = page and page.SchematicForm
	local info = form and Try(form.GetRecipeInfo, form)
	if Public(info) and type(info) == "table" and info.learned and not info.isRecraft
		and not info.isDummyRecipe and not info.isGatheringRecipe then
		return PublicNumber(info.recipeID)
	end
end

local function UpdateLabel()
	if not label then return end
	if not db.showLabel then return label:SetText("") end
	local spellID = page.CreateButton and page.CreateButton:IsShown() and SelectedRecipeID()
	local per, measured = PerCraft(spellID)
	if not per then return label:SetText("") end

	local box = page.CreateMultipleInputBox
	local count = box and box:IsShown() and PublicNumber(Try(box.GetValue, box)) or 1
	count = math.max(1, count)

	local mark = measured and "" or "~"
	local text = ("%sTime:|r %d x %.1fs = %s%s"):format(GOLD, count, per, mark, Clock(per * count))

	local all = page.CreateAllButton and page.CreateAllButton:IsShown()
		and PublicNumber(Try(page.GetCraftableCount, page))
	if all and all > 1 and all ~= count then
		text = text .. ("\n%sAll %d:|r %s%s"):format(GOLD, all, mark, Clock(per * all))
	end
	label:SetText(text)
end

local function SetUpProfessionsFrame()
	if label or not (ProfessionsFrame and ProfessionsFrame.CraftingPage) then return end
	page = ProfessionsFrame.CraftingPage
	if not page.CreateAllButton then return end   -- controls are made in the page's OnLoad

	label = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	label:SetPoint("RIGHT", page.CreateAllButton, "LEFT", -10, 0)
	label:SetJustifyH("RIGHT")

	-- Runs on recipe selection, bag changes and after each craft starts.
	hooksecurefunc(page, "ValidateControls", UpdateLabel)
	if page.CreateMultipleInputBox then
		page.CreateMultipleInputBox:HookScript("OnTextChanged", UpdateLabel)
	end
	UpdateLabel()
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local function OnCraft(recipeID, count)
	recipeID, count = PublicNumber(recipeID), PublicNumber(count) or 1
	if not recipeID then return end
	local info = Try(C_TradeSkillUI.GetRecipeInfo, recipeID)
	local name, icon
	if Public(info) and type(info) == "table" then name, icon = info.name, info.icon end
	if not Public(name) then name = nil end
	if not Public(icon) then icon = nil end
	StartRun(recipeID, name, icon, count)
end

-- The repeat queue stopped (out of materials, moved, etc.). The last craft's
-- SUCCEEDED can arrive around the same time, so give it a moment.
local function CheckStopped()
	if run and not run.finished and not run.test and not CurrentCastLeft(run.spellID) then
		FinishRun()
	end
end

function M:OnAddonLoaded()
	SetUpProfessionsFrame()
end

--------------------------------------------------------------------------------
-- Commands (slash and settings menu)
--------------------------------------------------------------------------------

function M.Test()
	StartRun(nil, "Test Craft", nil, 5, true)
	run.per, run.measured = 2, true
	M.Say("showing a 5-craft test. Drag the bar to move it.")
end

function M.ResetPosition()
	db.point = nil
	S.RestorePoint(bar, db, "point", DEFAULT_POINT)
	M.Say("bar position reset.")
end

function M.Forget()
	ns.Confirm("Forget every learned craft time?", function()
		wipe(db.learned)
		M.Say("forgot all learned craft times.")
		UpdateLabel()
	end)
end

local function OnSlash(msg)
	msg = msg:lower():match("^%s*(.-)%s*$")
	if msg == "test" then
		M.Test()
	elseif msg == "reset" then
		M.ResetPosition()
	elseif msg == "castbar" then
		db.hideCastBar = not db.hideCastBar
		UpdateCastBars()
		M.Say("Blizzard's cast bar while crafting: " .. (db.hideCastBar and "hidden." or "shown."))
	elseif msg == "lock" or msg == "unlock" then
		db.locked = msg == "lock"
		M.Say(db.locked and "bar locked." or "bar unlocked.")
	elseif msg == "forget" then
		M.Forget()
	elseif msg == "options" then
		ns.OpenSettings(M)
	else
		local n = 0
		for _ in pairs(db.learned) do n = n + 1 end
		M.Say(("%d recipe times learned. Commands:"):format(n))
		print("  /crafttimer test - show a test bar (drag it to move)")
		print("  /crafttimer lock / unlock - stop or allow dragging")
		print("  /crafttimer reset - put the bar back where it started")
		print("  /crafttimer castbar - hide or show Blizzard's cast bar while crafting")
		print("  /crafttimer forget - forget all learned craft times")
		print("  /crafttimer options - open the settings")
	end
end

M.options = {
	{ type = "checkbox", key = "showLabel", label = "Time on the Professions window", tooltip = "Show the total time next to the Create buttons.", onChange = function() UpdateLabel() end },
	{ type = "checkbox", key = "hideCastBar", label = "Hide Blizzard's cast bar", tooltip = "Hide the game's own cast bar while you craft; the Craft Timer bar shows instead. Other casts still use the game's bar.", onChange = function() UpdateCastBars() end },
	{ type = "checkbox", key = "ticks", label = "Line at each craft", tooltip = "Divide the bar at each craft, so you can see each one finish.", onChange = function() if run then bar:SetTicks(db.ticks and run.total or 0) end end },
	{ type = "checkbox", key = "locked", label = "Lock the bar", tooltip = "Stop the bar from being dragged." },
	{ type = "button", label = "Preview", button = "Test bar", tooltip = "Show a 5-craft test so you can place the bar.", func = function() M.Test() end },
	{ type = "button", label = "Position", button = "Reset", tooltip = "Put the bar back in its default place.", func = function() M.ResetPosition() end },
	{ type = "button", label = "Learned times", button = "Forget all", tooltip = "Forget every learned craft time.", func = function() M.Forget() end },
}

--------------------------------------------------------------------------------
-- Start-up
--------------------------------------------------------------------------------

function M:Enable()
	db = self.db
	db.learned = type(db.learned) == "table" and db.learned or {}

	bar = S.Bar({
		name = "PredUICraftBar", width = BAR_W, height = BAR_H, icon = true,
		db = db, pointKey = "point", defaultPoint = DEFAULT_POINT,
		locked = function() return db.locked end,
	})
	bar:SetColor(AMBER[1], AMBER[2], AMBER[3])

	-- All three take (recipeSpellID, numCasts, ...).
	for _, fn in ipairs({ "CraftRecipe", "CraftEnchant", "CraftSalvage" }) do
		if C_TradeSkillUI and C_TradeSkillUI[fn] then
			hooksecurefunc(C_TradeSkillUI, fn, OnCraft)
		end
	end
	SetUpProfessionsFrame()
	HookCastBars()

	local events = CreateFrame("Frame")
	events:RegisterEvent("TRADE_SKILL_SHOW")
	events:RegisterEvent("UPDATE_TRADESKILL_CAST_STOPPED")
	events:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
	events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
	events:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")
	events:SetScript("OnEvent", function(_, event, _, _, spellID)
		if event == "TRADE_SKILL_SHOW" then
			SetUpProfessionsFrame()
			UpdateLabel()
		elseif event == "UPDATE_TRADESKILL_CAST_STOPPED" then
			C_Timer.After(0.5, CheckStopped)
		elseif run and not run.finished and not run.test then
			spellID = PublicNumber(spellID)
			if spellID ~= run.spellID then return end
			if event == "UNIT_SPELLCAST_START" then
				OnCastStart(spellID)
			elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
				run.done = run.done + 1
				if run.done >= run.total then FinishRun() end
			elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
				FinishRun("Interrupted")
			end
		end
	end)

	-- ~30 updates a second while a bar is up, so the sheen and glow move smoothly.
	local sinceUpdate = 0
	events:SetScript("OnUpdate", function(_, elapsed)
		if not run then return end
		sinceUpdate = sinceUpdate + elapsed
		if sinceUpdate < 0.03 then return end
		sinceUpdate = 0
		UpdateBar()
	end)
end

SLASH_PREDUICRAFT1 = "/crafttimer"
SlashCmdList.PREDUICRAFT = ns.SlashHandler(M, OnSlash)
