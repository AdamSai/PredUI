--------------------------------------------------------------------------------
-- PredUI floating button: a small button you can drag anywhere. Click it for a
-- row of icons, one per PredUI window (Notes, Loot Room, Mail Ledger...), plus
-- a gear for the settings. Right-click the button for the settings too.
--
-- Modules add icons with M.launcher, a list of
--   { icon, label, hint, func, rightClick (optional), count (optional) }
-- `hint` is the grey tooltip line, `count` a function returning a number shown
-- on the icon. Only modules that are on get icons. The row is rebuilt every
-- time it opens, so counts are current.
--
-- This replaces Notes' own floating button; its position and on/off setting
-- are carried over once.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.Style

local ICON = "Interface\\AddOns\\PredUI\\Media\\Icon"
local SETTINGS_ICON = "Interface\\Icons\\Trade_Engineering"
local DEFAULT_POINT = { "RIGHT", "RIGHT", -60, 120 }   -- where Notes' button used to be
local SIZE, ICON_SIZE, GAP = 32, 28, 4

local button, row
local icons = {}

-- Carries over Notes' old button settings, once.
local function Migrate()
	local notes = type(PredUIDB.notes) == "table" and PredUIDB.notes
	if not notes then return end
	if type(rawget(notes, "buttonPoint")) == "table" then
		if rawget(ns.global, "launcherPoint") == nil then ns.global.launcherPoint = notes.buttonPoint end
		notes.buttonPoint = nil
	end
	if rawget(notes, "button") ~= nil then
		if notes.button == false and rawget(ns.global, "launcher") == nil then ns.global.launcher = false end
		notes.button = nil
	end
end

local function Entries()
	local list = {}
	for _, M in ipairs(ns.modules) do
		if M.enabled and type(M.launcher) == "table" then
			for _, e in ipairs(M.launcher) do list[#list + 1] = e end
		end
	end
	list[#list + 1] = {
		icon = SETTINGS_ICON, label = "PredUI settings", hint = "Modules, look and every module's options.",
		func = function() ns.OpenSettings() end,
	}
	return list
end

--------------------------------------------------------------------------------
-- Icon row
--------------------------------------------------------------------------------

local function Icon_OnEnter(self)
	local e = self.entry
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:SetText(e.label)
	if e.hint then GameTooltip:AddLine(e.hint, 0.5, 0.5, 0.5, true) end
	GameTooltip:Show()
end

local function Icon_OnClick(self, mouseButton)
	local e = self.entry
	row:Hide()
	if mouseButton == "RightButton" and e.rightClick then
		e.rightClick()
	else
		e.func()
	end
end

local function GetIcon(i)
	local b = icons[i]
	if b then return b end
	b = CreateFrame("Button", nil, row)
	b:SetSize(ICON_SIZE, ICON_SIZE)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	S.Body(b, { 0, 0, 0, 1 })
	b.icon = b:CreateTexture(nil, "ARTWORK")
	b.icon:SetPoint("TOPLEFT", 1, -1)
	b.icon:SetPoint("BOTTOMRIGHT", -1, 1)
	b.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetAllPoints(b.icon)
	hl:SetColorTexture(1, 1, 1, 0.15)
	b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	b.count:SetPoint("BOTTOMRIGHT", 0, 1)
	b:SetScript("OnEnter", Icon_OnEnter)
	b:SetScript("OnLeave", GameTooltip_Hide)
	b:SetScript("OnClick", Icon_OnClick)
	icons[i] = b
	return b
end

local function BuildRow()
	row = CreateFrame("Frame", "PredUILauncherRow", UIParent)
	row:SetFrameStrata("HIGH")
	row:SetClampedToScreen(true)
	row:Hide()
	S.Body(row)
	S.Glow(row, 14, 2)
	S.Scaled(row)
	tinsert(UISpecialFrames, "PredUILauncherRow")   -- Esc closes it
end

local function ShowRow()
	local entries = Entries()
	-- Open towards the middle of the screen, so the row stays on screen.
	local x = button:GetCenter()
	local toLeft = x and x * button:GetEffectiveScale() > UIParent:GetWidth() * UIParent:GetEffectiveScale() / 2

	for i, e in ipairs(entries) do
		local b = GetIcon(i)
		b.entry = e
		b.icon:SetTexture(e.icon)
		local n = e.count and ns.Try(e.count)
		b.count:SetText(type(n) == "number" and n > 0 and n or "")
		b:ClearAllPoints()
		local offset = GAP + (i - 1) * (ICON_SIZE + GAP)
		if toLeft then
			b:SetPoint("RIGHT", row, "RIGHT", -offset, 0)
		else
			b:SetPoint("LEFT", row, "LEFT", offset, 0)
		end
		b:Show()
	end
	for i = #entries + 1, #icons do icons[i]:Hide() end

	row:SetSize(GAP + #entries * (ICON_SIZE + GAP), ICON_SIZE + GAP * 2)
	row:ClearAllPoints()
	if toLeft then
		row:SetPoint("RIGHT", button, "LEFT", -6, 0)
	else
		row:SetPoint("LEFT", button, "RIGHT", 6, 0)
	end
	row:Show()
end

local function ToggleRow()
	if row:IsShown() then row:Hide() else ShowRow() end
end

--------------------------------------------------------------------------------
-- Button
--------------------------------------------------------------------------------

local function ShowTooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:SetText("PredUI")
	for _, M in ipairs(ns.modules) do
		if M.enabled and M.MinimapTooltip then M.MinimapTooltip() end
	end
	GameTooltip:AddLine("Click: your PredUI windows.", 0.5, 0.5, 0.5)
	GameTooltip:AddLine("Right-click: settings.", 0.5, 0.5, 0.5)
	GameTooltip:AddLine("Drag to move. Hide it in /predui.", 0.5, 0.5, 0.5)
	GameTooltip:Show()
end

local function Update()
	if not button then return end
	button:SetShown(ns.global.launcher and true or false)
	if not button:IsShown() then row:Hide() end
end

function ns.SetLauncherShown(shown)
	ns.global.launcher = shown and true or false
	Update()
end

function ns.ToggleLauncher()
	ns.SetLauncherShown(not ns.global.launcher)
	ns.Print("floating button " .. (ns.global.launcher and "on" or "off") .. ".")
end

function ns.ResetLauncherPosition()
	if not button then return end
	ns.global.launcherPoint = nil
	S.RestorePoint(button, ns.global, "launcherPoint", DEFAULT_POINT)
	if row:IsShown() then ShowRow() end
end

function ns.BuildLauncher()
	if button then return end
	Migrate()
	BuildRow()

	local b = CreateFrame("Button", "PredUILauncherButton", UIParent)
	b:SetSize(SIZE, SIZE)
	b:SetFrameStrata("MEDIUM")
	b:SetClampedToScreen(true)
	b:SetMovable(true)
	if b.SetDontSavePosition then b:SetDontSavePosition(true) end   -- saved in our db
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	S.Body(b, { 0, 0, 0, 1 })
	S.Glow(b, 14, 2)
	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetPoint("TOPLEFT", 3, -3)
	icon:SetPoint("BOTTOMRIGHT", -3, 3)
	icon:SetTexture(ICON)
	local hl = b:CreateTexture(nil, "HIGHLIGHT")
	hl:SetPoint("TOPLEFT", 1, -1)
	hl:SetPoint("BOTTOMRIGHT", -1, 1)
	hl:SetColorTexture(1, 1, 1, 0.15)

	b:SetScript("OnClick", function(_, mouseButton)
		GameTooltip_Hide()
		if mouseButton == "RightButton" then
			row:Hide()
			ns.OpenSettings()
		else
			ToggleRow()
		end
	end)
	b:SetScript("OnDragStart", function(self)
		GameTooltip_Hide()
		row:Hide()
		self:StartMoving()
	end)
	b:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		S.SavePoint(self, ns.global, "launcherPoint")
	end)
	b:SetScript("OnEnter", ShowTooltip)
	b:SetScript("OnLeave", GameTooltip_Hide)

	button = b
	S.RestorePoint(b, ns.global, "launcherPoint", DEFAULT_POINT)
	S.Scaled(b)
	Update()
end
