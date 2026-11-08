--------------------------------------------------------------------------------
-- Hidden Stats: a small panel beside the character sheet (C) with stats the
-- sheet doesn't show: movement speed (running, swimming, mounted, flight path),
-- mana or energy regen, attack speed, average item level and durability.
-- Hover a row for the details.
--
--   * It's our own frame, a child of PaperDollFrame, so it shows and hides with
--     the Character tab. Blizzard's stat list (PAPERDOLL_STATCATEGORIES) is
--     never touched: writing to it taints the stat pane, and the stat APIs
--     (GetUnitSpeed, GetManaRegen, UnitAttackSpeed...) return secret values to
--     tainted code in combat, which breaks Blizzard's own rows.
--   * Forever's sheet has a Movement Speed row of its own, but it only refreshes
--     on stat events (nothing fires when you start swimming), and EnhanceQoL
--     removes it at login. Here the rows are redrawn 5 times a second while the
--     panel is shown, so the speed follows what you're doing.
--   * In combat the game can make these values secret. The row then shows "-"
--     until they're readable again.
--   * The mount's own speed can only be read while mounted (it's in the run
--     speed then); there's no API for it otherwise.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.Style
local PublicNumber, PublicString, Try = ns.PublicNumber, ns.PublicString, ns.Try

local M = ns.NewModule("stats", {
	title = "Hidden Stats",
	notes = "A panel beside the character sheet with movement speed (running, swimming, mounted), regen, attack speed, item level and durability.",
	defaults = {
		show = true,          -- show the panel next to the character sheet
	},
})

local REFRESH_INTERVAL = 0.2   -- seconds between redraws while shown
local WIDTH = 190
local ROW_H = 18
local BASE_SPEED = 7           -- yards per second at 100% (BASE_MOVEMENT_SPEED)
local HIDDEN = "-"             -- shown for a value the game keeps secret

local db
local panel
local testMode = false
local wasSwimming = false      -- keeps the swim speed while jumping out of water

--------------------------------------------------------------------------------
-- Reading the stats. Each returns a table the row and its tooltip use, or nil
-- when the row doesn't apply to this character.
--------------------------------------------------------------------------------

local function Base()
	return PublicNumber(BASE_MOVEMENT_SPEED) or BASE_SPEED
end

local function Pct(yardsPerSec)
	return yardsPerSec and yardsPerSec / Base() * 100
end

local function Flag(fn, ...)
	local v = Try(fn, ...)
	return ns.Public(v) and v and true or false
end

local function ReadSpeed()
	local current, run, flight, swim = Try(GetUnitSpeed, "player")
	current, run, flight, swim = PublicNumber(current), PublicNumber(run), PublicNumber(flight), PublicNumber(swim)
	local s = { current = Pct(current), run = Pct(run), flight = Pct(flight), swim = Pct(swim) }

	local swimming = Flag(IsSwimming)
	if Flag(UnitOnTaxi, "player") then
		s.state, s.value = "Flight path", s.current
	elseif Flag(UnitIsDeadOrGhost, "player") then
		s.state, s.value = "Ghost speed", s.run
	elseif swimming or (wasSwimming and Flag(IsFalling)) then
		s.state, s.value = "Swim speed", s.swim
	elseif Flag(IsFlying) then
		s.state, s.value = "Flying speed", s.flight
	elseif Flag(IsMounted) then
		s.state, s.value, s.mounted = "Mounted speed", s.run, true
	else
		s.state, s.value = "Run speed", s.run
	end
	if not Flag(IsFalling) then wasSwimming = swimming end
	return s
end

local function ReadRegen()
	local maxMana = PublicNumber(Try(UnitPowerMax, "player", Enum.PowerType.Mana))
	if maxMana and maxMana > 0 then
		local base, casting = Try(GetManaRegen)
		base, casting = PublicNumber(base), PublicNumber(casting)
		return {
			kind = "mana",
			label = "Mana regen",
			base = base and math.floor(base * 5 + 0.5),
			casting = casting and math.floor(casting * 5 + 0.5),
		}
	end
	local _, token = Try(UnitPowerType, "player")
	if PublicString(token) == "ENERGY" then
		local rate = PublicNumber(Try(GetPowerRegen))
		return { kind = "energy", label = "Energy regen", rate = rate }
	end
end

local function ReadAttack()
	local main, off = Try(UnitAttackSpeed, "player")
	local ranged = Try(UnitRangedDamage, "player")
	main, off, ranged = PublicNumber(main), PublicNumber(off), PublicNumber(ranged)
	if ranged and ranged <= 0 then ranged = nil end
	if off and off <= 0 then off = nil end
	return { main = main, off = off, ranged = ranged }
end

local function ReadItemLevel()
	local overall, equipped = Try(GetAverageItemLevel)
	return { overall = PublicNumber(overall), equipped = PublicNumber(equipped) }
end

-- Every equipped item that wears down. Slots without durability (rings,
-- trinkets, neck, back...) return nothing and are skipped.
local FIRST_SLOT, LAST_SLOT = 1, 18

local function ReadDurability()
	local items, cur, max = {}, 0, 0
	for slot = FIRST_SLOT, LAST_SLOT do
		local c, m = Try(GetInventoryItemDurability, slot)
		c, m = PublicNumber(c), PublicNumber(m)
		if c and m and m > 0 then
			cur, max = cur + c, max + m
			items[#items + 1] = {
				link = PublicString(Try(GetInventoryItemLink, "player", slot)),
				cur = c, max = m, pct = c / m * 100,
			}
		end
	end
	if #items == 0 then return nil end
	table.sort(items, function(a, b) return a.pct < b.pct end)
	return { items = items, overall = cur / max * 100, lowest = items[1].pct }
end

-- Made-up values for /hstats test.
local TEST = {
	speed = { state = "Mounted speed", value = 160, current = 160, run = 160, swim = 67, mounted = true },
	regen = { kind = "mana", label = "Mana regen", base = 48, casting = 12 },
	attack = { main = 2.6, off = 1.8, ranged = 3.0 },
	ilvl = { overall = 52.4, equipped = 54.1 },
	durability = { overall = 81, lowest = 18, items = {
		{ link = "Chest", cur = 18, max = 100, pct = 18 },
		{ link = "Main hand", cur = 60, max = 75, pct = 80 },
		{ link = "Head", cur = 60, max = 60, pct = 100 },
	} },
}

--------------------------------------------------------------------------------
-- Formatting
--------------------------------------------------------------------------------

local function PctText(v)
	return v and ("%d%%"):format(v + 0.5) or HIDDEN
end

local function Secs(v)
	return v and ("%.2fs"):format(v) or HIDDEN
end

local function Line(label, value)
	GameTooltip:AddDoubleLine(label, value, 1, 0.82, 0, 1, 1, 1)
end

-- A smooth scale: green at 100%, yellow at 50%, red at 20% and below. In
-- between the colour blends, so 60% is already a yellowish green and 30% an
-- orange: it shows how close you are to the next step.
local DURA_STEPS = {
	{ 20,  { 1.00, 0.25, 0.25 } },   -- red (and anything lower)
	{ 50,  { 1.00, 0.82, 0.00 } },   -- yellow
	{ 100, { 0.25, 1.00, 0.25 } },   -- green
}

local function DurabilityColor(pct)
	local r, g, b
	if pct <= DURA_STEPS[1][1] then
		r, g, b = unpack(DURA_STEPS[1][2])
	else
		for i = 2, #DURA_STEPS do
			local hi, lo = DURA_STEPS[i], DURA_STEPS[i - 1]
			if pct <= hi[1] or i == #DURA_STEPS then
				local t = math.min(1, (pct - lo[1]) / (hi[1] - lo[1]))
				r = lo[2][1] + (hi[2][1] - lo[2][1]) * t
				g = lo[2][2] + (hi[2][2] - lo[2][2]) * t
				b = lo[2][3] + (hi[2][3] - lo[2][3]) * t
				break
			end
		end
	end
	return ("|cff%02x%02x%02x"):format(r * 255 + 0.5, g * 255 + 0.5, b * 255 + 0.5)
end

local function SecretNote(...)
	for i = 1, select("#", ...) do
		if select(i, ...) == nil then
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Some values are hidden by the game right now (in combat). They come back after.", 0.6, 0.6, 0.6, true)
			return
		end
	end
end

--------------------------------------------------------------------------------
-- Rows: each has read (data or nil to hide), text (label, value) and tip.
--------------------------------------------------------------------------------

local ROWS = {
	{
		key = "speed",
		read = ReadSpeed,
		text = function(s) return s.state, PctText(s.value) end,
		tip = function(s)
			GameTooltip:AddLine(("Movement speed %s"):format(PctText(s.value)), 1, 1, 1)
			GameTooltip:AddLine(s.state, 0.6, 0.6, 0.6)
			GameTooltip:AddLine(" ")
			local nowYards = s.current and s.current * Base() / 100
			Line("Moving now", s.current and ("%s  (%.1f yd/s)"):format(PctText(s.current), nowYards) or HIDDEN)
			Line(s.mounted and "Run (mounted)" or "Run", PctText(s.run))
			Line("Swim", PctText(s.swim))
			if s.mounted then
				Line("Mounted", PctText(s.run))
			else
				Line("Mounted", "|cff808080mount up to see|r")
			end
			local showFlight = Try(PaperDollFrame_ShowFlightSpeed)
			if showFlight and s.flight then Line("Flying", PctText(s.flight)) end
			if CR_SPEED then
				local rating = PublicNumber(Try(GetCombatRating, CR_SPEED))
				local bonus = PublicNumber(Try(GetCombatRatingBonus, CR_SPEED))
				if rating and rating > 0 then
					Line("Speed rating", ("%d  (+%.1f%%)"):format(rating, bonus or 0))
				end
			end
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine(("100%% is %g yards a second, normal running speed."):format(Base()), 0.6, 0.6, 0.6, true)
			SecretNote(s.current, s.run, s.swim)
		end,
	},
	{
		key = "regen",
		read = ReadRegen,
		text = function(r)
			if r.kind == "mana" then
				return r.label, r.base and (r.base .. " mp5") or HIDDEN
			end
			return r.label, r.rate and ("%.1f/s"):format(r.rate) or HIDDEN
		end,
		tip = function(r)
			if r.kind == "mana" then
				GameTooltip:AddLine("Mana regen (per 5 seconds)", 1, 1, 1)
				GameTooltip:AddLine(" ")
				Line("Not casting", r.base and tostring(r.base) or HIDDEN)
				Line("While casting", r.casting and tostring(r.casting) or HIDDEN)
				GameTooltip:AddLine(" ")
				GameTooltip:AddLine("The \"while casting\" rate applies for 5 seconds after you spend mana.", 0.6, 0.6, 0.6, true)
				SecretNote(r.base, r.casting)
			else
				GameTooltip:AddLine("Energy regen", 1, 1, 1)
				GameTooltip:AddLine(" ")
				Line("Per second", r.rate and ("%.1f"):format(r.rate) or HIDDEN)
				Line("Per 2s tick", r.rate and ("%.0f"):format(r.rate * 2) or HIDDEN)
				SecretNote(r.rate)
			end
		end,
	},
	{
		key = "attack",
		read = ReadAttack,
		text = function(a)
			local v = Secs(a.main)
			if a.off then v = v .. " / " .. Secs(a.off) end
			return "Attack speed", v
		end,
		tip = function(a)
			GameTooltip:AddLine("Attack speed (seconds per swing)", 1, 1, 1)
			GameTooltip:AddLine(" ")
			local function Swing(label, v)
				Line(label, v and ("%s  (%.2f/s)"):format(Secs(v), 1 / v) or HIDDEN)
			end
			Swing("Main hand", a.main)
			if a.off then Swing("Off hand", a.off) end
			if a.ranged then Swing("Ranged", a.ranged) end
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine("Includes haste from buffs and gear.", 0.6, 0.6, 0.6, true)
			SecretNote(a.main)
		end,
	},
	{
		key = "ilvl",
		read = ReadItemLevel,
		text = function(i)
			return "Item level", i.equipped and ("%.1f"):format(i.equipped) or HIDDEN
		end,
		tip = function(i)
			GameTooltip:AddLine("Average item level", 1, 1, 1)
			GameTooltip:AddLine(" ")
			Line("Equipped", i.equipped and ("%.1f"):format(i.equipped) or HIDDEN)
			Line("Best in bags", i.overall and ("%.1f"):format(i.overall) or HIDDEN)
		end,
	},
	{
		key = "durability",
		read = ReadDurability,
		text = function(d)
			-- The worst item decides the colour: one broken piece matters more
			-- than a good average.
			return "Durability", DurabilityColor(d.lowest) .. ("%d%%|r"):format(d.overall + 0.5)
		end,
		tip = function(d)
			GameTooltip:AddLine(("Durability %d%%"):format(d.overall + 0.5), 1, 1, 1)
			GameTooltip:AddLine(("Lowest item %d%%"):format(d.lowest + 0.5), 0.6, 0.6, 0.6)
			GameTooltip:AddLine(" ")
			local full = 0
			for _, item in ipairs(d.items) do
				if item.cur >= item.max then
					full = full + 1
				else
					local value = item.cur == 0 and "|cffff4040broken|r"
						or ("%s%d/%d  (%d%%)|r"):format(DurabilityColor(item.pct), item.cur, item.max, item.pct + 0.5)
					GameTooltip:AddDoubleLine(item.link or "?", value, 1, 1, 1, 1, 1, 1)
				end
			end
			if full > 0 then
				GameTooltip:AddLine(("%d %s fully repaired."):format(full, full == 1 and "item" or "items"), 0.6, 0.6, 0.6)
			end
		end,
	},
}

--------------------------------------------------------------------------------
-- Panel
--------------------------------------------------------------------------------

local function ShowTip(row)
	if not row.data then return end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	row.def.tip(row.data)
	GameTooltip:Show()
end

local function Refresh()
	if not panel then return end
	local want = db.show or testMode
	panel:SetShown(want)
	if not (want and panel:IsVisible()) then return end

	local y = -S.PAD - 18
	for _, row in ipairs(panel.rows) do
		local data
		if testMode then
			data = TEST[row.def.key]
		else
			data = row.def.read()
		end
		row.data = data
		if data then
			local label, value = row.def.text(data)
			row.label:SetText(label)
			row.value:SetText(value)
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", S.PAD, y)
			row:SetPoint("TOPRIGHT", -S.PAD, y)
			row:Show()
			y = y - ROW_H
			if GameTooltip:IsOwned(row) then ShowTip(row) end
		else
			row:Hide()
		end
	end
	panel:SetHeight(-y + S.PAD - 2)
end

local function BuildPanel()
	if panel or not PaperDollFrame then return end
	panel = CreateFrame("Frame", "PredUIHiddenStats", PaperDollFrame)
	panel:SetSize(WIDTH, 100)
	-- Beyond the window's side tabs (Character, Reputation, Skills...), which
	-- hang off its right edge, so they stay clickable.
	local tabs = CharacterFrame and CharacterFrame.ModeTabs
	if tabs then
		panel:SetPoint("TOPLEFT", tabs, "TOPRIGHT", 4, 0)
	else
		panel:SetPoint("TOPLEFT", CharacterFrame or PaperDollFrame, "TOPRIGHT", 6, -24)
	end
	S.Body(panel)
	S.Glow(panel)
	panel.heading = S.Heading(panel, "Hidden stats", -S.PAD)

	panel.rows = {}
	for i, def in ipairs(ROWS) do
		local row = CreateFrame("Frame", nil, panel)
		row:SetHeight(ROW_H)
		row.def = def
		row.label = S.Text(row, 12)
		row.label:SetPoint("LEFT")
		row.label:SetJustifyH("LEFT")
		row.label:SetTextColor(1, 0.82, 0)
		row.value = S.Text(row, 12)
		row.value:SetPoint("RIGHT")
		row.value:SetJustifyH("RIGHT")
		S.RowHighlight(row)
		row:EnableMouse(true)
		row:SetScript("OnEnter", ShowTip)
		row:SetScript("OnLeave", GameTooltip_Hide)
		panel.rows[i] = row
	end

	-- Swimming, mounting and flight paths fire nothing the sheet listens to,
	-- so redraw while shown (and only then).
	local elapsed = 0
	panel:SetScript("OnUpdate", function(_, delta)
		elapsed = elapsed + delta
		if elapsed < REFRESH_INTERVAL then return end
		elapsed = 0
		Refresh()
	end)
	panel:SetScript("OnShow", Refresh)
	PaperDollFrame:HookScript("OnShow", Refresh)
	Refresh()
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

local function OpenSheet()
	if PaperDollFrame and not PaperDollFrame:IsVisible() and ToggleCharacter then
		Try(ToggleCharacter, "PaperDollFrame")
	end
end

local function OnSlash(msg)
	msg = msg:lower():match("^%s*(.-)%s*$")
	if msg == "test" then
		testMode = not testMode
		if testMode then OpenSheet() end
		Refresh()
		M.Say(testMode and "showing made-up values. /hstats test again to stop." or "back to your own stats.")
	elseif msg == "toggle" then
		db.show = not db.show
		Refresh()
		M.Say(db.show and "panel shown." or "panel hidden.")
	elseif msg == "reset" then
		db.show = nil
		testMode = false
		Refresh()
		M.Say("settings reset.")
	elseif msg == "options" then
		ns.OpenSettings(M)
	else
		M.Say("Commands:")
		print("  /hstats toggle - show or hide the panel beside the character sheet")
		print("  /hstats test - show the panel with made-up values")
		print("  /hstats reset - back to the defaults")
		print("  /hstats options - settings")
	end
end

M.options = {
	{ type = "checkbox", key = "show", label = "Show the panel", tooltip = "Show the Hidden stats panel beside the character sheet (C).", onChange = Refresh },
	{ type = "button", label = "Preview", button = "Test", tooltip = "Show the panel with made-up values. Also /hstats test.", func = function() OnSlash("test") end },
}

--------------------------------------------------------------------------------
-- Start-up
--------------------------------------------------------------------------------

function M:Enable()
	db = self.db
	BuildPanel()

	local queued = false
	local function Queue()
		if queued then return end
		queued = true
		C_Timer.After(0.05, function()
			queued = false
			Refresh()
		end)
	end

	local events = CreateFrame("Frame")
	events:RegisterUnitEvent("UNIT_AURA", "player")
	events:RegisterUnitEvent("UNIT_STATS", "player")
	events:RegisterUnitEvent("UNIT_ATTACK_SPEED", "player")
	events:RegisterUnitEvent("UNIT_DISPLAYPOWER", "player")
	events:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
	events:RegisterEvent("UPDATE_INVENTORY_DURABILITY")
	events:RegisterEvent("PLAYER_REGEN_ENABLED")
	events:SetScript("OnEvent", Queue)
end

SLASH_PREDUIHSTATS1 = "/hstats"
SlashCmdList.PREDUIHSTATS = ns.SlashHandler(M, OnSlash)
