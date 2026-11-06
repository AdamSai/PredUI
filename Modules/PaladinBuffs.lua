--------------------------------------------------------------------------------
-- Paladin Buffs: the seal and Righteous Fury icons the Cooldown Manager misses.
--
--   * Why: Blizzard's Cooldown Manager matches a buff to its icon by exact spell
--     ID. Forever has spell ranks, and each rank of a seal is its own spell and
--     its own buff, so the manager doesn't light up for the seals (and some
--     aren't in its list at all). We can't add spells to Blizzard's list without
--     tainting it, so this module draws its own icons in the same style and
--     lines them up beside the manager's buff icons.
--   * Seal: shown while any seal is on you (every rank of every seal), with its
--     time left as a swipe, like the manager's own buff icons.
--   * Righteous Fury: shown, tinted red, while you're in a dungeon or raid,
--     know the spell and don't have it on. It's a reminder, so it disappears as
--     soon as you cast it.
--   * Buffs are looked up by spell ID, with a fallback on the buff's name for
--     any rank this list doesn't know.
--   * In combat (and encounters, PvP) the game makes buff data secret to
--     addons, so lookups come back empty. Your own casts aren't secret, so in
--     combat the module goes by them instead: casting a seal shows it for its
--     duration (learned from earlier, readable casts; 30 s until then). If
--     the game still lists buff instance IDs readably, the seal's buff is
--     followed by its ID so its removal is noticed; if not, it stays until its
--     timer runs out. Judgement doesn't use up seals on Forever, so it changes
--     nothing. Nothing secret is ever read as "buff gone" (the UNIT_AURA
--     payload is secret in combat and isn't used). Righteous Fury works the
--     same way. Leaving combat reads the real buffs again.
--   * The icons sit beside the Cooldown Manager's "Tracked Buffs" bar
--     (BuffIconCooldownViewer) and use its icon size. They're only anchored to
--     it, never parented, so Blizzard's layout isn't touched. They line up
--     with the manager's visible icons (its bar keeps empty slots for hidden
--     buffs); when none show, or it's hidden out of combat, they sit in the
--     middle of its bar, so the spot is the same in and out of combat. With
--     no manager bar on screen they use their own spot (drag them).
--   * Does nothing on other classes.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.Style
local Public, PublicNumber, PublicString, Try = ns.Public, ns.PublicNumber, ns.PublicString, ns.Try

local M = ns.NewModule("paladin", {
	title = "Paladin Buffs",
	notes = "Shows your active seal next to the Cooldown Manager's buff icons, and a Righteous Fury reminder in dungeons and raids.",
	defaults = {
		seal = true, fury = true,
		attach = "right",      -- right / left / above / below of the manager's buff icons, or "free"
		matchSize = true, size = 40, gap = 4,
		locked = false, debug = false,
	},
})

local RIGHTEOUS_FURY = 25780
local DEFAULT_POINT = { "CENTER", "CENTER", 0, -120 }
local BASE_SIZE = 40           -- CooldownViewerBuffIconItemTemplate's size
local TEST_SECONDS = 15
local FURY_TINT = { 1, 0.35, 0.35 }

-- Every rank of every seal on Forever (from the game's rank data).
local SEALS = {
	{ 20154, 21084, 20287, 20288, 20289, 20290, 20291, 20292, 20293 }, -- Seal of Righteousness
	{ 21082, 20162, 20305, 20306, 20307, 20308 },                      -- Seal of the Crusader
	{ 20164 },                                                          -- Seal of Justice
	{ 20165, 20347, 20348, 20349 },                                     -- Seal of Light
	{ 20166, 20356, 20357 },                                            -- Seal of Wisdom
	{ 20375, 20915, 20918, 20919, 20920 },                              -- Seal of Command
	{ 1311649, 1311656, 20163, 20419, 20421, 20422, 20423 },            -- Seal of Fury
}

local SEAL_IDS = {}            -- [spellID] = true, every rank
for _, ranks in ipairs(SEALS) do
	for _, id in ipairs(ranks) do SEAL_IDS[id] = true end
end

local SEAL_DURATION = 30       -- until a seal's real duration has been seen
local CATCH_WINDOW = 1         -- seconds after a cast to pick up its new buff

local INSTANCE_TYPES = { party = true, raid = true, scenario = true }

local db
local holder, mover, sealIcon, furyIcon
local sealNames = {}           -- [localized name] = true, for the name fallback
local testUntil

-- What we know is on the player. Kept up to date from the buffs while they
-- can be read, and from your own casts while they can't (combat).
local seal                     -- nil, or { id, duration, expires, instanceID, castAt }
local lastSealID               -- for the log: the seal shown last time

-- A short log of why the seal icon appeared or went away: /palbuffs why.
local log = {}
local function Log(text)
	local combat = InCombatLockdown() and " (combat)" or ""
	log[#log + 1] = ("%s%s %s"):format(date("%H:%M:%S"), combat, text)
	if #log > 15 then table.remove(log, 1) end
	if db and db.debug then M.Say(text) end
end
local fury = { on = false }    -- { on, instanceID, castAt }

--------------------------------------------------------------------------------
-- Aura lookups
--------------------------------------------------------------------------------

local function PlayerAura(spellID)
	if not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then return nil end
	local aura = Try(C_UnitAuras.GetPlayerAuraBySpellID, spellID)
	if type(aura) == "table" then return aura end
end

-- A buff on the player whose name is in names (secret names are skipped).
local function AuraByName(names)
	if not (C_UnitAuras and C_UnitAuras.GetBuffDataByIndex) then return nil end
	for i = 1, 40 do
		local aura = Try(C_UnitAuras.GetBuffDataByIndex, "player", i)
		if type(aura) ~= "table" then return nil end
		local name = PublicString(aura.name)
		if name and names[name] then return aura end
	end
end

local function SpellIcon(spellID)
	return C_Spell and C_Spell.GetSpellTexture and Try(C_Spell.GetSpellTexture, spellID) or 134400
end

local function FindSeal()
	for _, ranks in ipairs(SEALS) do
		for _, id in ipairs(ranks) do
			local aura = PlayerAura(id)
			if aura then return aura, id end
		end
	end
	local aura = AuraByName(sealNames)
	if aura then return aura, PublicNumber(aura.spellId) or SEALS[1][1] end
end

local function KnowsSpell(spellID)
	if C_SpellBook and C_SpellBook.IsSpellKnown then
		return Try(C_SpellBook.IsSpellKnown, spellID) and true or false
	end
	return IsPlayerSpell and Try(IsPlayerSpell, spellID) and true or false
end

local function FuryAura()
	local aura = PlayerAura(RIGHTEOUS_FURY)
	if aura then return aura end
	local name = C_Spell and C_Spell.GetSpellName and PublicString(Try(C_Spell.GetSpellName, RIGHTEOUS_FURY))
	return name and AuraByName({ [name] = true }) or nil
end

-- In combat (and encounters, PvP...) the game hands addons secret buff data:
-- lookups come back empty, so they can't tell us a buff is gone.
local function AurasReadable()
	if C_Secrets and C_Secrets.ShouldAurasBeSecret then
		local secret = Try(C_Secrets.ShouldAurasBeSecret)
		if secret ~= nil and Public(secret) then return not secret end
	end
	return not InCombatLockdown()
end

-- The instance IDs of the player's buffs, as a set, with when each was first
-- seen. Only when the game hands them over readable: in combat the list may
-- come back secret, and then we know nothing (nil), rather than "gone".
local firstSeen = {}           -- [instanceID] = GetTime() it first appeared

local function ReadIDs()
	local ids = Try(C_UnitAuras and C_UnitAuras.GetUnitAuraInstanceIDs, "player", "HELPFUL")
	if not Public(ids) or type(ids) ~= "table" then return nil end
	local set = {}
	local ok = pcall(function()
		for _, id in ipairs(ids) do
			if not Public(id) or type(id) ~= "number" then error("secret") end
			set[id] = true
		end
	end)
	return ok and set or nil
end

local function AuraIDs()
	local set = ReadIDs()
	if not set then return nil end
	local now = GetTime()
	for id in pairs(set) do firstSeen[id] = firstSeen[id] or now end
	for id in pairs(firstSeen) do
		if not set[id] then firstSeen[id] = nil end
	end
	return set
end

-- The one buff that appeared around a cast, or nil if that isn't clear.
local function NewAuraNear(castAt)
	local found
	for id, at in pairs(firstSeen) do
		if math.abs(at - castAt) <= CATCH_WINDOW then
			if found then return nil end
			found = id
		end
	end
	return found
end

local function SealDuration(id)
	return db.durations[id] or SEAL_DURATION
end

-- Read the real buffs (only while they're readable).
local function Rescan()
	AuraIDs()
	local aura, id = FindSeal()
	if aura then
		local duration, expires = PublicNumber(aura.duration), PublicNumber(aura.expirationTime)
		if duration and duration > 0 then db.durations[id] = duration end
		seal = {
			id = id,
			duration = duration and duration > 0 and duration or nil,
			expires = expires and expires > 0 and expires or nil,
			instanceID = PublicNumber(aura.auraInstanceID),
		}
	elseif seal and seal.castAt and GetTime() - seal.castAt <= CATCH_WINDOW then
		-- Just cast: the buff can land a moment after the cast event.
	else
		if seal then Log("buffs readable, no seal on you") end
		seal = nil
	end
	local f = FuryAura()
	fury = { on = f ~= nil, instanceID = f and PublicNumber(f.auraInstanceID) }
end

-- Your own casts are never secret, so they carry us through combat.
local function OnCast(spellID)
	spellID = PublicNumber(spellID)
	if not spellID then return end
	local now = GetTime()
	if SEAL_IDS[spellID] then
		local duration = SealDuration(spellID)
		seal = { id = spellID, duration = duration, expires = now + duration, castAt = now }
		Log(("seal cast (spell %d), %d s timer"):format(spellID, duration))
		C_Timer.After(duration + 0.1, M.Update)
		C_Timer.After(CATCH_WINDOW + 0.1, M.Update)
	elseif spellID == RIGHTEOUS_FURY then
		fury = { on = true, castAt = now }
		C_Timer.After(CATCH_WINDOW + 0.1, M.Update)
	end
end

-- While buff data is secret: follow buffs by instance ID, if the list of
-- instance IDs is readable. The UNIT_AURA payload itself isn't used (it's
-- secret in combat).
local function TrackByInstanceID()
	local set = AuraIDs()
	if not set then return end
	if seal and seal.castAt and not seal.instanceID then
		seal.instanceID = NewAuraNear(seal.castAt)
	end
	if fury.on and fury.castAt and not fury.instanceID then
		fury.instanceID = NewAuraNear(fury.castAt)
	end
	if seal and seal.instanceID and not set[seal.instanceID] then
		seal = nil
		Log("seal buff removed (by instance ID)")
	end
	if fury.on and fury.instanceID and not set[fury.instanceID] then fury = { on = false } end
end

local function InInstance()
	local inside, kind = IsInInstance()
	return Public(inside) and inside and Public(kind) and INSTANCE_TYPES[kind] or false
end

--------------------------------------------------------------------------------
-- Icons (the look of the Cooldown Manager's buff icons)
--------------------------------------------------------------------------------

local function NewIcon()
	local f = CreateFrame("Frame", nil, holder)
	f:SetSize(BASE_SIZE, BASE_SIZE)

	f.Icon = f:CreateTexture(nil, "ARTWORK")
	f.Icon:SetAllPoints()
	local mask = f:CreateMaskTexture()
	mask:SetAtlas("UI-HUD-CoolDownManager-Mask")
	mask:SetAllPoints()
	f.Icon:AddMaskTexture(mask)

	local overlay = f:CreateTexture(nil, "OVERLAY")
	overlay:SetAtlas("UI-HUD-CoolDownManager-IconOverlay")
	overlay:SetPoint("TOPLEFT", -8, 7)
	overlay:SetPoint("BOTTOMRIGHT", 8, -7)

	f.Cooldown = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
	f.Cooldown:SetAllPoints()
	f.Cooldown:SetReverse(true)
	f.Cooldown:SetSwipeTexture("Interface\\HUD\\UI-HUD-CoolDownManager-Icon-Swipe")
	f.Cooldown:SetSwipeColor(0, 0, 0, 0.7)
	f.Cooldown:SetDrawEdge(false)

	-- Click-through, no tooltip.
	f:EnableMouse(false)
	f:Hide()
	return f
end

--------------------------------------------------------------------------------
-- Placement
--------------------------------------------------------------------------------

-- The manager's buff icons that are really showing. Its bar also keeps empty
-- slots for buffs set to hide while inactive, so its own edges aren't where
-- the visible icons end.
local function ShownViewerItems(viewer)
	if not viewer:IsVisible() then return nil end
	local items = viewer.GetItemFrames and Try(viewer.GetItemFrames, viewer)
	if type(items) ~= "table" then return nil end
	local shown = {}
	for _, item in ipairs(items) do
		if item.IsVisible and item:IsVisible() then shown[#shown + 1] = item end
	end
	return #shown > 0 and shown or nil
end

-- Screen x (at scale 1) of the outermost visible icon on one side ("right"
-- or "left"), or nil.
local function OuterEdge(items, side)
	local best
	for _, item in ipairs(items) do
		local x = PublicNumber(side == "left" and item:GetLeft() or item:GetRight())
		local scale = PublicNumber(item:GetEffectiveScale())
		if x and scale then
			x = x * scale
			if not best or (side == "left" and x < best) or (side ~= "left" and x > best) then best = x end
		end
	end
	return best
end

-- How to place the icons:
--   "edge"   beside the manager's visible buff icons
--   "center" in the middle of the manager's bar: nothing of it is showing
--            (no active buffs, or it's hidden out of combat), so the icons
--            sit where its buffs would. Same spot in and out of combat.
--   "free"   our own saved spot: chosen in the settings, or there's no
--            manager bar placed on screen
local function AnchorMode()
	local viewer = BuffIconCooldownViewer
	if db.attach == "free" or not viewer then return "free" end
	if (Try(viewer.GetNumPoints, viewer) or 0) == 0 then return "free" end
	local items = ShownViewerItems(viewer)
	if not items then return "center" end
	return "edge", items
end

local function IconSize()
	if db.matchSize then
		local viewer = BuffIconCooldownViewer
		local scale = viewer and PublicNumber(viewer.iconScale)
		return math.floor(BASE_SIZE * (scale or 1) + 0.5)
	end
	return db.size
end

local ATTACH = {
	-- holder point, viewer point, x sign, y sign
	right = { "LEFT", "RIGHT", 1, 0 },
	left  = { "RIGHT", "LEFT", -1, 0 },
	above = { "BOTTOM", "TOP", 0, 1 },
	below = { "TOP", "BOTTOM", 0, -1 },
}

local function Place()
	local size = IconSize()
	local gap = db.gap
	local shown = {}
	if sealIcon:IsShown() then shown[#shown + 1] = sealIcon end
	if furyIcon:IsShown() then shown[#shown + 1] = furyIcon end
	local n = math.max(#shown, 1)
	holder:SetSize(n * size + (n - 1) * gap, size)

	-- Icons fill outward from the manager, so the seal sits next to it.
	local leftToRight = db.attach ~= "left"
	for i, icon in ipairs(shown) do
		icon:SetSize(size, size)
		icon:ClearAllPoints()
		local offset = (i - 1) * (size + gap)
		if leftToRight then
			icon:SetPoint("LEFT", holder, "LEFT", offset, 0)
		else
			icon:SetPoint("RIGHT", holder, "RIGHT", -offset, 0)
		end
	end

	holder:ClearAllPoints()
	local mode, items = AnchorMode()
	local a = ATTACH[db.attach]
	if mode == "edge" and a then
		-- Left/right: next to the outermost visible icon. The holder is anchored
		-- to the bar with a measured offset, never to one of Blizzard's icons:
		-- those are pooled, and a released one loses its position (and anything
		-- anchored to it would vanish). Above/below: the bar's middle.
		local viewer = BuffIconCooldownViewer
		local edge = (db.attach == "left" or db.attach == "right") and OuterEdge(items, db.attach)
		local viewerLeft = PublicNumber(viewer:GetLeft())
		local vs, hs = PublicNumber(viewer:GetEffectiveScale()), PublicNumber(holder:GetEffectiveScale())
		if edge and viewerLeft and vs and hs and hs > 0 then
			local x = (edge - viewerLeft * vs) / hs + a[3] * gap
			holder:SetPoint(a[1], viewer, "LEFT", x, 0)
		else
			holder:SetPoint(a[1], viewer, a[2], a[3] * gap, a[4] * gap)
		end
	elseif mode == "center" then
		holder:SetPoint("CENTER", BuffIconCooldownViewer, "CENTER", 0, 0)
	else
		S.RestorePoint(holder, db, "point", DEFAULT_POINT)
	end
end

--------------------------------------------------------------------------------
-- Update
--------------------------------------------------------------------------------

local isPaladin

local function Update()
	if not holder then return end
	local testing = testUntil and GetTime() < testUntil
	if not testing then testUntil = nil end

	if isPaladin then
		if AurasReadable() then Rescan() else TrackByInstanceID() end
		local now = GetTime()
		if seal and seal.expires and now >= seal.expires then
			-- The buff can outlast our timer (refreshed without a cast we saw).
			-- If we can still see it by instance ID, keep it, without a swipe.
			local set = seal.instanceID and ReadIDs()
			if set and set[seal.instanceID] then
				seal.expires, seal.duration = nil, nil
			else
				seal = nil
				Log("seal timer ran out")
			end
		end
		if UnitIsDeadOrGhost("player") and (seal or fury.on) then
			seal, fury = nil, { on = false }
			Log("you died")
		end
		local id = seal and seal.id
		if id ~= lastSealID then
			if id then
				Log(("seal shown: %s"):format(PublicString(Try(C_Spell.GetSpellName, id)) or id))
			elseif lastSealID then
				Log("seal hidden")
			end
			lastSealID = id
		end
	end

	-- Seal
	local sealID
	if testing then
		sealID = SEALS[1][1]
		sealIcon.Cooldown:SetCooldown(testUntil - TEST_SECONDS, TEST_SECONDS)
	elseif isPaladin and db.seal and seal then
		sealID = seal.id
		if seal.expires and seal.duration then
			sealIcon.Cooldown:SetCooldown(seal.expires - seal.duration, seal.duration)
		else
			sealIcon.Cooldown:Clear()
		end
	end
	if sealID and sealIcon.spellID ~= sealID then
		sealIcon.Icon:SetTexture(SpellIcon(sealID))
		sealIcon.spellID = sealID
	end
	sealIcon:SetShown(sealID ~= nil)

	-- Righteous Fury reminder
	local showFury = testing or (isPaladin and db.fury and InInstance() and not UnitIsDeadOrGhost("player")
		and KnowsSpell(RIGHTEOUS_FURY) and not fury.on)
	furyIcon:SetShown(showFury and true or false)

	-- Always shown when there's something to show, even if the manager is
	-- hidden or empty: then the icons use their own spot (see AnchorMode).
	holder:SetShown(sealIcon:IsShown() or furyIcon:IsShown())
	-- The drag handle only exists while /palbuffs test runs on freely placed
	-- icons; set before Place so an error there can't leave it up.
	mover:SetShown((testing and AnchorMode() == "free" and not db.locked) and true or false)
	Place()
end
M.Update = Update

--------------------------------------------------------------------------------
-- Commands (slash and settings menu)
--------------------------------------------------------------------------------

function M.Test()
	testUntil = GetTime() + TEST_SECONDS
	Update()
	C_Timer.After(TEST_SECONDS + 0.1, Update)
	if AnchorMode() == "free" then
		M.Say(("showing both icons for %d seconds. Drag them to move them; the rest of the time they're click-through."):format(TEST_SECONDS))
	else
		M.Say(("showing both icons for %d seconds, next to the Cooldown Manager's buff icons."):format(TEST_SECONDS))
	end
end

function M.ResetPosition()
	db.point = nil
	if holder then Place() end
	M.Say("position reset.")
end

local ATTACH_NAMES = {
	{ "right", "Right of the buff icons" },
	{ "left", "Left of the buff icons" },
	{ "above", "Above the buff icons" },
	{ "below", "Below the buff icons" },
	{ "free", "Anywhere (drag to move)" },
}

local function OnSlash(msg)
	msg = msg:lower():match("^%s*(.-)%s*$")
	local where = msg:match("^attach%s+(%a+)$")
	if msg == "test" then
		M.Test()
	elseif msg == "reset" then
		M.ResetPosition()
	elseif where then
		for _, choice in ipairs(ATTACH_NAMES) do
			if choice[1] == where then
				db.attach = where
				Update()
				M.Say("icons: " .. choice[2]:lower() .. ".")
				return
			end
		end
		M.Say("attach to right, left, above, below or free.")
	elseif msg == "seal" or msg == "fury" then
		db[msg] = not db[msg]
		Update()
		M.Say((msg == "seal" and "seal icon: " or "Righteous Fury reminder: ") .. (db[msg] and "on." or "off."))
	elseif msg == "lock" or msg == "unlock" then
		db.locked = msg == "lock"
		M.Say(db.locked and "icons locked." or "icons unlocked.")
	elseif msg == "why" then
		if #log == 0 then
			M.Say("nothing logged yet.")
		else
			M.Say("why the seal icon came and went, newest last:")
			for _, line in ipairs(log) do print("  " .. line) end
		end
	elseif msg == "debug" then
		db.debug = not db.debug
		M.Say(db.debug and "printing each seal change in chat." or "no longer printing seal changes.")
	elseif msg == "options" then
		ns.OpenSettings(M)
	else
		M.Say(isPaladin and "commands:" or "this character isn't a paladin, so nothing is shown. Commands:")
		print("  /palbuffs test - show both icons for a moment")
		print("  /palbuffs seal / fury - turn the seal icon or the Righteous Fury reminder on or off")
		print("  /palbuffs attach right|left|above|below|free - where the icons go")
		print("  /palbuffs lock / unlock - stop or allow dragging during test (when free)")
		print("  /palbuffs reset - put the icons back in their default place (when free)")
		print("  /palbuffs why - why the seal icon last appeared or went away")
		print("  /palbuffs debug - print each seal change in chat as it happens")
		print("  /palbuffs options - open the settings")
	end
end

M.options = {
	{ type = "checkbox", key = "seal", label = "Active seal", tooltip = "Show your seal while it's on you, with its time left.", onChange = Update },
	{ type = "checkbox", key = "fury", label = "Righteous Fury reminder", tooltip = "In dungeons and raids, show Righteous Fury while it's missing.", onChange = Update },
	{ type = "dropdown", key = "attach", label = "Position", tooltip = "Where the icons go, relative to the Cooldown Manager's tracked buff icons.",
		values = function() return ATTACH_NAMES end, onChange = Update },
	{ type = "checkbox", key = "matchSize", label = "Same size as the Cooldown Manager", tooltip = "Use the Cooldown Manager's icon size. Turn off to pick your own.", onChange = Update },
	{ type = "slider", key = "size", label = "Icon size", min = 20, max = 80, step = 1, tooltip = "Used when the size isn't matched to the Cooldown Manager.", onChange = Update },
	{ type = "slider", key = "gap", label = "Spacing", min = 0, max = 20, step = 1, tooltip = "Space between the icons and the Cooldown Manager.", onChange = Update },
	{ type = "checkbox", key = "locked", label = "Lock", tooltip = "Stop the icons from being dragged during the test preview. They are always click-through otherwise." },
	{ type = "button", label = "Preview", button = "Test", tooltip = "Show both icons for a moment so you can see where they go.", func = function() M.Test() end },
	{ type = "button", label = "Position", button = "Reset", tooltip = "Put freely placed icons back in their default place.", func = function() M.ResetPosition() end },
}

--------------------------------------------------------------------------------
-- Start-up
--------------------------------------------------------------------------------

local function CacheSealNames()
	if not (C_Spell and C_Spell.GetSpellName) then return end
	for _, ranks in ipairs(SEALS) do
		local name = PublicString(Try(C_Spell.GetSpellName, ranks[1]))
		if name then sealNames[name] = true end
	end
end

local function PlaceLater()
	if holder and holder:IsShown() then Place() end
end

local hookedViewer = false
local function HookViewer()
	if hookedViewer or not BuffIconCooldownViewer then return end
	hookedViewer = true
	BuffIconCooldownViewer:HookScript("OnShow", Update)
	BuffIconCooldownViewer:HookScript("OnHide", Update)
	BuffIconCooldownViewer:HookScript("OnSizeChanged", function() if holder:IsShown() then Place() end end)
	-- Runs when buffs are added to or removed from the manager's list.
	if BuffIconCooldownViewer.RefreshLayout then
		hooksecurefunc(BuffIconCooldownViewer, "RefreshLayout", function() if holder:IsShown() then Place() end end)
	end
end

function M:OnAddonLoaded(name)
	if name == "Blizzard_CooldownViewer" then
		HookViewer()
		Update()
	end
end

function M:Enable()
	db = self.db
	db.durations = type(rawget(db, "durations")) == "table" and db.durations or {}
	local _, classFile = UnitClass("player")
	isPaladin = classFile == "PALADIN"

	-- The icons and their holder have no mouse scripts at all, so they're
	-- always click-through (any mouse script, RegisterForDrag included,
	-- turns a frame's mouse back on).
	holder = CreateFrame("Frame", nil, UIParent)
	holder:SetFrameStrata("LOW")
	holder:SetClampedToScreen(true)
	holder:SetMovable(true)
	holder:EnableMouse(false)
	holder:Hide()

	-- A separate drag handle over the icons, shown only during the test.
	mover = CreateFrame("Frame", nil, UIParent)
	mover:SetFrameStrata("MEDIUM")
	mover:SetAllPoints(holder)
	mover:EnableMouse(true)
	mover:RegisterForDrag("LeftButton")
	mover:SetScript("OnDragStart", function()
		if AnchorMode() == "free" and not db.locked then holder:StartMoving() end
	end)
	mover:SetScript("OnDragStop", function()
		holder:StopMovingOrSizing()
		if AnchorMode() == "free" then S.SavePoint(holder, db, "point") end
	end)
	mover:Hide()

	sealIcon = NewIcon()
	furyIcon = NewIcon()
	furyIcon.spellID = RIGHTEOUS_FURY
	furyIcon.Icon:SetTexture(SpellIcon(RIGHTEOUS_FURY))
	furyIcon.Icon:SetVertexColor(FURY_TINT[1], FURY_TINT[2], FURY_TINT[3])
	furyIcon.Glow = S.Glow(furyIcon, 10, 2, 1, 0.2, 0.2, 0.6)

	CacheSealNames()
	HookViewer()

	local events = CreateFrame("Frame")
	events:RegisterUnitEvent("UNIT_AURA", "player")
	events:RegisterEvent("PLAYER_ENTERING_WORLD")
	events:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	events:RegisterEvent("SPELLS_CHANGED")
	events:RegisterEvent("PLAYER_DEAD")
	events:RegisterEvent("PLAYER_ALIVE")
	events:RegisterEvent("PLAYER_UNGHOST")
	events:RegisterEvent("PLAYER_REGEN_ENABLED")
	events:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
	events:SetScript("OnEvent", function(_, event, _, _, arg3)
		if event == "SPELLS_CHANGED" or event == "PLAYER_ENTERING_WORLD" then CacheSealNames() end
		if not isPaladin then return end
		if event == "UNIT_SPELLCAST_SUCCEEDED" then OnCast(arg3) end
		Update()
		-- The manager shows or hides its own icons for the same buff change,
		-- possibly after us: line up again once it has.
		if event == "UNIT_AURA" then C_Timer.After(0, PlaceLater) end
	end)
	Update()
end

SLASH_PREDUIPALADIN1 = "/palbuffs"
SlashCmdList.PREDUIPALADIN = ns.SlashHandler(M, OnSlash)
