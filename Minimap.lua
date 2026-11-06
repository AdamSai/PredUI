--------------------------------------------------------------------------------
-- PredUI minimap button. Left-click opens the settings, right-click shows or
-- hides the Mail Ledger panel. Drag to move it around the minimap.
--
-- Modules can add to it: M.MinimapTooltip() adds lines to GameTooltip, and
-- M.MinimapRightClick() runs on right-click (the first module that has one).
--
-- The name matters: MinimapButtonButton collects frames whose name contains
-- "MinimapButton", so this button joins its bar when that addon is enabled.
-- It is built at ADDON_LOADED so that addon finds it on its first scan.
--
-- This used to be Mail Ledger's own button; its position and on/off setting
-- are carried over once.
--------------------------------------------------------------------------------

local _, ns = ...

local RADIUS_OFFSET = 5
local DEFAULT_ANGLE = 215
local ICON = "Interface\\AddOns\\PredUI\\Media\\Icon"

local button

local function Place(degrees)
	local angle = math.rad(degrees)
	local x, y = math.cos(angle), math.sin(angle)
	local w = Minimap:GetWidth() / 2 + RADIUS_OFFSET
	local h = Minimap:GetHeight() / 2 + RADIUS_OFFSET
	-- GetMinimapShape is defined by minimap-reshaping addons, when one is loaded.
	local getShape = _G.GetMinimapShape
	local shape = getShape and getShape() or "ROUND"
	if shape == "ROUND" then
		x, y = x * w, y * h
	else
		-- Follow the edge of a square minimap instead of cutting across it.
		local diagonal = math.sqrt(2)
		x = math.max(-w, math.min(x * w * diagonal, w))
		y = math.max(-h, math.min(y * h * diagonal, h))
	end
	button:ClearAllPoints()
	button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function CursorAngle()
	local centerX, centerY = Minimap:GetCenter()
	local cursorX, cursorY = GetCursorPosition()
	local scale = Minimap:GetEffectiveScale()
	return math.deg(math.atan2(cursorY / scale - centerY, cursorX / scale - centerX)) % 360
end

local function RightClickModule()
	for _, M in ipairs(ns.modules) do
		if M.enabled and M.MinimapRightClick then return M end
	end
end

local function ShowTooltip(self)
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:SetText("PredUI")
	for _, M in ipairs(ns.modules) do
		if M.enabled and M.MinimapTooltip then M.MinimapTooltip() end
	end
	GameTooltip:AddLine("Left-click: settings", 0.5, 0.5, 0.5)
	local M = RightClickModule()
	if M then GameTooltip:AddLine("Right-click: " .. M.title, 0.5, 0.5, 0.5) end
	GameTooltip:AddLine("Drag to move.", 0.5, 0.5, 0.5)
	GameTooltip:Show()
end

-- Carries over Mail Ledger's old button settings, once.
local function Migrate()
	local mail = type(PredUIDB.mail) == "table" and PredUIDB.mail.settings
	if type(mail) ~= "table" then return end
	if mail.minimapAngle ~= nil then
		if rawget(ns.global, "minimapAngle") == nil then ns.global.minimapAngle = mail.minimapAngle end
		mail.minimapAngle = nil
	end
	if mail.showMinimap ~= nil then
		if rawget(ns.global, "minimap") == nil then ns.global.minimap = mail.showMinimap and true or false end
		mail.showMinimap = nil
	end
end

local function Update()
	if not button then return end
	if ns.global.minimap then button:Show() else button:Hide() end
end

function ns.SetMinimapButtonShown(shown)
	ns.global.minimap = shown and true or false
	Update()
end

function ns.ToggleMinimapButton()
	ns.SetMinimapButtonShown(not ns.global.minimap)
	ns.Print("minimap button " .. (ns.global.minimap and "on" or "off") .. ".")
end

function ns.BuildMinimapButton()
	if button or not Minimap then return end
	Migrate()

	button = CreateFrame("Button", "PredUIMinimapButton", Minimap)
	button:SetSize(31, 31)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:RegisterForClicks("AnyUp")
	button:RegisterForDrag("LeftButton")
	button:SetHighlightTexture(136477) -- UI-Minimap-ZoomButton-Highlight

	-- Sizes copied from LibDBIcon, which differ between clients.
	local modern = AddonCompartmentFrame ~= nil

	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetTexture(136467) -- UI-Minimap-Background
	if modern then
		background:SetSize(24, 24)
		background:SetPoint("CENTER")
	else
		background:SetSize(20, 20)
		background:SetPoint("TOPLEFT", 7, -5)
	end

	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetTexture(ICON)
	if modern then
		icon:SetSize(18, 18)
		icon:SetPoint("CENTER")
	else
		icon:SetSize(17, 17)
		icon:SetPoint("TOPLEFT", 7, -6)
	end

	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetTexture(136430) -- MiniMap-TrackingBorder
	border:SetSize(modern and 50 or 53, modern and 50 or 53)
	border:SetPoint("TOPLEFT")

	button:SetScript("OnClick", function(_, mouseButton)
		if mouseButton == "LeftButton" then
			ns.OpenSettings()
		elseif mouseButton == "RightButton" then
			local M = RightClickModule()
			if M then M.MinimapRightClick() end
		end
	end)
	button:SetScript("OnEnter", ShowTooltip)
	button:SetScript("OnLeave", function() GameTooltip:Hide() end)
	button:SetScript("OnDragStart", function(self)
		GameTooltip:Hide()
		self:SetScript("OnUpdate", function() Place(CursorAngle()) end)
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
		ns.global.minimapAngle = CursorAngle()
	end)

	Place(ns.global.minimapAngle or DEFAULT_ANGLE)
	Update()
end
