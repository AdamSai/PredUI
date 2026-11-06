--------------------------------------------------------------------------------
-- PredUI look: every window, button and bar is built from these pieces, so the
-- modules share one style.
--
--   * Windows: a flat dark body, a 1px edge, a drop shadow and a soft accent
--     glow, with a title bar and a small close button.
--   * Bars: Flight Timer's bar (gloss fill, moving sheen, spark at the edge and
--     a pulsing glow in the bar's own colour), used by Flight and Craft Timer.
--   * The glow is a radial texture cut into corners and edges, so it stays
--     soft on frames of any size.
--   * Scale and glow come from the General settings (ns.global) and are applied
--     to everything registered here.
--------------------------------------------------------------------------------

local _, ns = ...

local S = {}
ns.Style = S

local MEDIA = "Interface\\AddOns\\" .. ns.ADDON .. "\\Media\\"
local WHITE = "Interface\\Buttons\\WHITE8x8"
local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
S.MEDIA = MEDIA

S.ACCENT = { 0.31, 0.76, 0.97 }
S.BODY   = { 0.055, 0.06, 0.075, 0.94 }
S.EDGE   = { 0.20, 0.23, 0.28, 1 }
S.TITLE_H = 26
S.PAD = 12

S.GOLD  = "|cffffd100"
S.DIM   = "|cff808080"
S.GOOD  = "|cff40ff40"
S.BAD   = "|cffff6060"
S.WARN  = "|cffff8040"

local scaled = {}              -- frames that follow the scale setting
local glows = {}               -- glows that follow the glow setting

--------------------------------------------------------------------------------
-- Small pieces
--------------------------------------------------------------------------------

local function Tex(parent, layer, sub, file, blend)
	local t = parent:CreateTexture(nil, layer, nil, sub)
	t:SetTexture(file or WHITE)
	if blend then t:SetBlendMode(blend) end
	return t
end
S.Texture = Tex

-- size: points; outline: true for text on bars (it sits on bright colours).
function S.Text(parent, size, outline, layer)
	local fs = parent:CreateFontString(nil, layer or "OVERLAY")
	fs:SetFont(FONT, size or 12, outline and "OUTLINE" or "")
	if not outline then
		fs:SetShadowColor(0, 0, 0, 0.9)
		fs:SetShadowOffset(1, -1)
	end
	fs:SetWordWrap(false)
	return fs
end

function S.Lighten(r, g, b, lift)
	lift = lift or 0.35
	return math.min(1, r + lift), math.min(1, g + lift), math.min(1, b + lift)
end

-- The 1px edge, a 2px shadow behind it and the body, all on the frame itself.
local function Body(frame, body, edge)
	body, edge = body or S.BODY, edge or S.EDGE
	local shadow = Tex(frame, "BACKGROUND", -6)
	shadow:SetVertexColor(0, 0, 0, 0.6)
	shadow:SetPoint("TOPLEFT", -2, 2)
	shadow:SetPoint("BOTTOMRIGHT", 2, -2)
	local e = Tex(frame, "BACKGROUND", -5)
	e:SetVertexColor(edge[1], edge[2], edge[3], edge[4] or 1)
	e:SetPoint("TOPLEFT", -1, 1)
	e:SetPoint("BOTTOMRIGHT", 1, -1)
	local b = Tex(frame, "BACKGROUND", -4)
	b:SetVertexColor(body[1], body[2], body[3], body[4] or 1)
	b:SetAllPoints()
	frame.pEdge, frame.pBody, frame.pShadow = e, b, shadow
	return b, e
end
S.Body = Body

--------------------------------------------------------------------------------
-- Glow
--------------------------------------------------------------------------------

local GlowMixin = {}

function GlowMixin:SetColor(r, g, b)
	for _, t in ipairs(self.pieces) do t:SetVertexColor(r, g, b) end
end

function GlowMixin:SetAlpha(a)
	self.alpha = a
	local shown = ns.global == nil or ns.global.glow
	for _, t in ipairs(self.pieces) do
		t:SetAlpha(a)
		t:SetShown(shown)
	end
end

-- A soft glow `size` points wide around `frame`, starting `inset` inside its
-- edge so there's no seam. Drawn behind everything else on the frame.
function S.Glow(frame, size, inset, r, g, b, alpha)
	size, inset = size or 18, inset or 2
	local file = MEDIA .. "PanelGlow"
	local function Piece(l, rr, t, bb)
		local tex = Tex(frame, "BACKGROUND", -8, file, "ADD")
		tex:SetTexCoord(l, rr, t, bb)
		return tex
	end
	local tl, tr = Piece(0, 0.5, 0, 0.5), Piece(0.5, 1, 0, 0.5)
	local bl, br = Piece(0, 0.5, 0.5, 1), Piece(0.5, 1, 0.5, 1)
	for _, c in ipairs({ tl, tr, bl, br }) do c:SetSize(size, size) end
	tl:SetPoint("BOTTOMRIGHT", frame, "TOPLEFT", inset, -inset)
	tr:SetPoint("BOTTOMLEFT", frame, "TOPRIGHT", -inset, -inset)
	bl:SetPoint("TOPRIGHT", frame, "BOTTOMLEFT", inset, inset)
	br:SetPoint("TOPLEFT", frame, "BOTTOMRIGHT", -inset, inset)

	local top = Piece(0.49, 0.51, 0, 0.5)
	top:SetPoint("TOPLEFT", tl, "TOPRIGHT")
	top:SetPoint("BOTTOMRIGHT", tr, "BOTTOMLEFT")
	local bottom = Piece(0.49, 0.51, 0.5, 1)
	bottom:SetPoint("TOPLEFT", bl, "TOPRIGHT")
	bottom:SetPoint("BOTTOMRIGHT", br, "BOTTOMLEFT")
	local left = Piece(0, 0.5, 0.49, 0.51)
	left:SetPoint("TOPLEFT", tl, "BOTTOMLEFT")
	left:SetPoint("BOTTOMRIGHT", bl, "TOPRIGHT")
	local right = Piece(0.5, 1, 0.49, 0.51)
	right:SetPoint("TOPLEFT", tr, "BOTTOMLEFT")
	right:SetPoint("BOTTOMRIGHT", br, "TOPRIGHT")

	local glow = Mixin({ pieces = { tl, tr, bl, br, top, bottom, left, right } }, GlowMixin)
	glow:SetColor(r or S.ACCENT[1], g or S.ACCENT[2], b or S.ACCENT[3])
	glow:SetAlpha(alpha or 0.35)
	glows[#glows + 1] = glow
	return glow
end

--------------------------------------------------------------------------------
-- Buttons and inputs
--------------------------------------------------------------------------------

local function ButtonState(self)
	local a = S.ACCENT
	if not self:IsEnabled() then
		self.pEdge:SetVertexColor(0.15, 0.16, 0.18)
		self.label:SetTextColor(0.45, 0.45, 0.45)
	elseif self.hover then
		self.pEdge:SetVertexColor(a[1], a[2], a[3])
		self.label:SetTextColor(1, 1, 1)
	else
		self.pEdge:SetVertexColor(S.EDGE[1] + 0.08, S.EDGE[2] + 0.08, S.EDGE[3] + 0.08)
		self.label:SetTextColor(0.9, 0.9, 0.9)
	end
	self.pBody:SetVertexColor(self.hover and 0.12 or 0.09, self.hover and 0.13 or 0.10, self.hover and 0.16 or 0.12, 1)
end

function S.Button(parent, text, w, h)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(w or 120, h or 22)
	Body(b, { 0.09, 0.10, 0.12, 1 })
	b.pShadow:SetVertexColor(0, 0, 0, 0.4)
	b.label = S.Text(b, 11)
	b.label:SetPoint("CENTER", 0, 0)
	b.label:SetText(text or "")
	b:SetFontString(b.label)
	b:SetPushedTextOffset(1, -1)
	b:SetScript("OnEnter", function(self)
		self.hover = true
		ButtonState(self)
		if self.tooltip then
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText(self.tooltip, nil, nil, nil, nil, true)
			GameTooltip:Show()
		end
	end)
	b:SetScript("OnLeave", function(self)
		self.hover = nil
		ButtonState(self)
		GameTooltip_Hide()
	end)
	b:SetScript("OnEnable", ButtonState)
	b:SetScript("OnDisable", ButtonState)
	ButtonState(b)
	return b
end

-- The small "x" in a window's title bar.
function S.CloseButton(parent)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(20, 20)
	b.label = S.Text(b, 15)
	b.label:SetPoint("CENTER", 0, 1)
	b.label:SetText("x")
	b.label:SetTextColor(0.65, 0.65, 0.65)
	b:SetScript("OnEnter", function(self) self.label:SetTextColor(1, 0.35, 0.35) end)
	b:SetScript("OnLeave", function(self) self.label:SetTextColor(0.65, 0.65, 0.65) end)
	b:SetScript("OnClick", function(self) self:GetParent():Hide() end)
	return b
end

function S.EditBox(parent, w, h)
	local e = CreateFrame("EditBox", nil, parent)
	e:SetSize(w or 160, h or 22)
	Body(e, { 0.03, 0.035, 0.045, 1 })
	e.pShadow:SetVertexColor(0, 0, 0, 0.4)
	e:SetFont(FONT, 12, "")
	e:SetTextColor(1, 1, 1)
	e:SetTextInsets(6, 6, 0, 0)
	e:SetAutoFocus(false)
	e:SetScript("OnEscapePressed", e.ClearFocus)
	e:SetScript("OnEditFocusGained", function(self)
		self.pEdge:SetVertexColor(S.ACCENT[1], S.ACCENT[2], S.ACCENT[3])
	end)
	e:SetScript("OnEditFocusLost", function(self)
		self.pEdge:SetVertexColor(S.EDGE[1], S.EDGE[2], S.EDGE[3])
	end)
	return e
end

-- A thin accent-coloured row highlight for list buttons.
function S.RowHighlight(button)
	local hl = button:CreateTexture(nil, "HIGHLIGHT")
	hl:SetTexture(WHITE)
	hl:SetAllPoints()
	hl:SetVertexColor(S.ACCENT[1], S.ACCENT[2], S.ACCENT[3], 0.14)
	return hl
end

function S.Divider(parent, y, inset)
	inset = inset or S.PAD
	local line = Tex(parent, "ARTWORK", 0)
	line:SetVertexColor(1, 1, 1, 0.08)
	line:SetHeight(1)
	line:SetPoint("TOPLEFT", inset, y)
	line:SetPoint("TOPRIGHT", -inset, y)
	return line
end

-- A section heading: accent text with a faint rule after it, across the
-- parent's width. Move it with heading:SetY(y); Show/Hide work as usual.
function S.Heading(parent, text, y)
	local h = CreateFrame("Frame", nil, parent)
	h:SetHeight(14)
	h.text = S.Text(h, 12)
	h.text:SetPoint("LEFT")
	h.text:SetTextColor(S.ACCENT[1], S.ACCENT[2], S.ACCENT[3])
	h.text:SetText(text)
	local line = Tex(h, "ARTWORK", 0)
	line:SetVertexColor(S.ACCENT[1], S.ACCENT[2], S.ACCENT[3], 0.25)
	line:SetHeight(1)
	line:SetPoint("LEFT", h.text, "RIGHT", 6, 0)
	line:SetPoint("RIGHT")
	function h:SetY(newY)
		self:ClearAllPoints()
		self:SetPoint("TOPLEFT", parent, "TOPLEFT", S.PAD, newY)
		self:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -S.PAD, newY)
	end
	h:SetY(y or 0)
	return h
end

-- A slim vertical scroll bar. onScroll(value) gets whole steps from 0 to max.
function S.ScrollBar(parent, onScroll)
	local s = CreateFrame("Slider", nil, parent)
	s:SetOrientation("VERTICAL")
	s:SetWidth(8)
	s:SetValueStep(1)
	s:SetObeyStepOnDrag(true)
	s:SetMinMaxValues(0, 0)
	s:SetValue(0)
	local track = Tex(s, "BACKGROUND", 0)
	track:SetVertexColor(1, 1, 1, 0.06)
	track:SetAllPoints()
	local thumb = s:CreateTexture(nil, "OVERLAY")
	thumb:SetTexture(WHITE)
	thumb:SetVertexColor(S.ACCENT[1], S.ACCENT[2], S.ACCENT[3], 0.7)
	thumb:SetSize(8, 30)
	s:SetThumbTexture(thumb)
	s:SetScript("OnValueChanged", function(_, value) onScroll(math.floor(value + 0.5)) end)
	return s
end

--------------------------------------------------------------------------------
-- Windows
--------------------------------------------------------------------------------

-- opts: title, width, height, name (global name, for Esc to close it),
-- movable (default true), onMoved(frame) after a drag.
function S.Window(opts)
	local f = CreateFrame("Frame", opts.name, opts.parent or UIParent)
	f:SetSize(opts.width or 300, opts.height or 200)
	f:SetFrameStrata(opts.strata or "HIGH")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	Body(f)
	f.glow = S.Glow(f, 22, 2)

	-- Title bar: a slightly lighter band with an accent line under it.
	local bar = Tex(f, "BACKGROUND", -3)
	bar:SetVertexColor(1, 1, 1, 0.035)
	bar:SetPoint("TOPLEFT")
	bar:SetPoint("TOPRIGHT")
	bar:SetHeight(S.TITLE_H)
	local line = Tex(f, "ARTWORK", 0)
	line:SetVertexColor(S.ACCENT[1], S.ACCENT[2], S.ACCENT[3], 0.55)
	line:SetHeight(1)
	line:SetPoint("TOPLEFT", 0, -S.TITLE_H)
	line:SetPoint("TOPRIGHT", 0, -S.TITLE_H)

	f.title = S.Text(f, 13)
	f.title:SetPoint("LEFT", f, "TOPLEFT", S.PAD, -S.TITLE_H / 2)
	f.title:SetTextColor(1, 0.95, 0.85)
	f.title:SetText(opts.title or "")

	f.close = S.CloseButton(f)
	f.close:SetPoint("RIGHT", f, "TOPRIGHT", -4, -S.TITLE_H / 2)

	if opts.movable ~= false then
		f:SetMovable(true)
		f:RegisterForDrag("LeftButton")
		f:SetScript("OnDragStart", f.StartMoving)
		f:SetScript("OnDragStop", function(self)
			self:StopMovingOrSizing()
			if opts.onMoved then opts.onMoved(self) end
		end)
	end
	if opts.name then tinsert(UISpecialFrames, opts.name) end
	S.Scaled(f)
	f:Hide()
	return f
end

--------------------------------------------------------------------------------
-- Positions
--------------------------------------------------------------------------------

function S.SavePoint(frame, db, key)
	local point, _, relPoint, x, y = frame:GetPoint(1)
	db[key] = { point, relPoint, x, y }
end

function S.RestorePoint(frame, db, key, default)
	local p = type(db[key]) == "table" and db[key] or default
	frame:ClearAllPoints()
	frame:SetPoint(p[1], UIParent, p[2], p[3], p[4])
end

--------------------------------------------------------------------------------
-- Timer bars (Flight Timer's look)
--------------------------------------------------------------------------------

local BarMixin = {}

function BarMixin:SetColor(r, g, b)
	self.status:SetStatusBarColor(r, g, b)
	self.glow:SetVertexColor(r, g, b)
	self.edge:SetVertexColor(r * 0.65, g * 0.65, b * 0.65)
	self.back:SetVertexColor(r * 0.12, g * 0.12, b * 0.12)
	local lr, lg, lb = S.Lighten(r, g, b)
	self.spark:SetVertexColor(lr, lg, lb)
	self.sheen:SetVertexColor(lr, lg, lb)
	if self.hasIcon then self.iconEdge:SetVertexColor(r * 0.65, g * 0.65, b * 0.65) end
end

-- Only touches the font strings when the text really changed.
function BarMixin:SetTexts(title, timeText, statusText)
	if title and title ~= self.lastTitle then
		self.title:SetText(title)
		self.lastTitle = title
	end
	if timeText and timeText ~= self.lastTime then
		self.time:SetText(timeText)
		self.lastTime = timeText
	end
	if statusText and statusText ~= self.lastStatus then
		self.statusText:SetText(statusText)
		self.lastStatus = statusText
	end
end

function BarMixin:ResetTexts()
	self.lastTitle, self.lastTime, self.lastStatus = nil, nil, nil
end

-- The highlight sweeping along the filled part, trimmed so it never leaves it.
function BarMixin:UpdateSheen(now, fillWidth)
	local width = 70
	local x = (now % 3.2) / 3.2 * (fillWidth + width) - width
	local left, right = math.max(x, 0), math.min(x + width, fillWidth)
	if right - left < 1 then
		self.sheen:Hide()
		return
	end
	self.sheen:ClearAllPoints()
	self.sheen:SetPoint("TOPLEFT", self.status, "TOPLEFT", left, 0)
	self.sheen:SetPoint("BOTTOMLEFT", self.status, "BOTTOMLEFT", left, 0)
	self.sheen:SetWidth(right - left)
	self.sheen:SetTexCoord((left - x) / width, (right - x) / width, 0, 1)
	self.sheen:Show()
end

-- frac: 0..1 fill. known: false dims the fill (nothing to count down).
-- urgent: faster, brighter pulse.
function BarMixin:Animate(frac, known, urgent)
	local now = GetTime()
	self.status:SetValue(frac)
	self.status:SetAlpha(known and 1 or 0.35)
	self.spark:SetShown(known and frac > 0 and frac < 1)
	self:UpdateSheen(now, self.status:GetWidth() * frac)
	local speed = urgent and 6 or 2
	local base = urgent and 0.85 or 0.6
	local pulse = math.sin(now * speed)
	self.glow:SetAlpha(base + pulse * 0.18)
	self.spark:SetAlpha(0.85 + pulse * 0.15)
end

-- The bar has stopped: freeze the moving parts.
function BarMixin:Still(frac)
	self.status:SetValue(frac)
	self.spark:Hide()
	self.sheen:Hide()
end

local MIN_TICK_GAP = 4         -- points between dividers; closer than this and they're left out

-- Dividers splitting the bar into `parts` equal pieces (a line at each 1/parts),
-- e.g. one per craft. 0 or 1 part, or too many to tell apart, shows none.
function BarMixin:SetTicks(parts)
	parts = parts or 0
	local width = self.fillWidth
	local count = (parts > 1 and width / parts >= MIN_TICK_GAP) and parts - 1 or 0
	for i = 1, count do
		local tick = self.ticks[i]
		if not tick then
			-- A dark 1px cut with a faint light edge, so it reads on both the fill
			-- and the empty part of the bar.
			tick = Tex(self.top, "ARTWORK", 2)
			tick:SetVertexColor(0, 0, 0, 0.6)
			tick:SetWidth(1)
			tick.light = Tex(self.top, "ARTWORK", 2)
			tick.light:SetVertexColor(1, 1, 1, 0.18)
			tick.light:SetWidth(1)
			self.ticks[i] = tick
		end
		local x = math.floor(width * i / parts + 0.5)
		tick:ClearAllPoints()
		tick:SetPoint("TOPLEFT", self.status, "TOPLEFT", x, 0)
		tick:SetPoint("BOTTOMLEFT", self.status, "BOTTOMLEFT", x, 0)
		tick.light:ClearAllPoints()
		tick.light:SetPoint("TOPLEFT", tick, "TOPRIGHT")
		tick.light:SetPoint("BOTTOMLEFT", tick, "BOTTOMRIGHT")
		tick:Show()
		tick.light:Show()
	end
	for i = count + 1, #self.ticks do
		self.ticks[i]:Hide()
		self.ticks[i].light:Hide()
	end
end

-- Starts the fade-out. Call self:UpdateFade() from OnUpdate; it returns true
-- while fading and hides the bar when done.
function BarMixin:FadeOut()
	self.fadeStart = GetTime()
end

function BarMixin:UpdateFade()
	if not self.fadeStart then return false end
	local a = 1 - (GetTime() - self.fadeStart) / 2.5
	if a <= 0 then
		self.fadeStart = nil
		self:Hide()
	else
		-- Hold, then fade over the last part so the message can be read.
		self:SetAlpha(math.min(1, a * 2.5))
	end
	return true
end

function BarMixin:ShowBar()
	self.fadeStart = nil
	self:SetAlpha(1)
	self:ResetTexts()
	self:Show()
end

-- opts: name, width, height, icon (true to show an icon box on the left),
-- db + pointKey + defaultPoint (where the position is saved), locked() -> bool.
function S.Bar(opts)
	local w, h = opts.width or 340, opts.height or 22
	local iconW = opts.icon and (h + 6) or 0

	local bar = CreateFrame("Frame", opts.name, UIParent)
	Mixin(bar, BarMixin)
	bar:SetSize(w, h + 16)
	bar:SetFrameStrata("MEDIUM")
	bar:SetClampedToScreen(true)
	bar:SetMovable(true)
	bar:EnableMouse(true)
	bar:RegisterForDrag("LeftButton")
	if bar.SetDontSavePosition then bar:SetDontSavePosition(true) end   -- saved in our db
	bar:SetScript("OnDragStart", function(self)
		if not (opts.locked and opts.locked()) then self:StartMoving() end
	end)
	bar:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		S.SavePoint(self, opts.db, opts.pointKey or "point")
	end)
	bar:Hide()

	local status = CreateFrame("StatusBar", nil, bar)
	status:SetPoint("TOPLEFT", iconW, 0)
	status:SetPoint("TOPRIGHT")
	status:SetHeight(h)
	status:SetStatusBarTexture(MEDIA .. "Fill")
	status:SetMinMaxValues(0, 1)
	status:SetValue(1)
	bar.status = status

	-- Bar's dressing sits on the parent, behind the StatusBar child.
	bar.glow = Tex(bar, "BACKGROUND", -8, MEDIA .. "Glow", "ADD")
	bar.glow:SetPoint("TOPLEFT", status, "TOPLEFT", -20 - iconW, 20)
	bar.glow:SetPoint("BOTTOMRIGHT", status, "BOTTOMRIGHT", 20, -20)
	glows[#glows + 1] = { SetAlpha = function() end, bar = bar }

	local shadow = Tex(bar, "BACKGROUND", -4)
	shadow:SetVertexColor(0, 0, 0, 1)
	shadow:SetPoint("TOPLEFT", status, "TOPLEFT", -2, 2)
	shadow:SetPoint("BOTTOMRIGHT", status, "BOTTOMRIGHT", 2, -2)

	bar.edge = Tex(bar, "BACKGROUND", -3)
	bar.edge:SetPoint("TOPLEFT", status, "TOPLEFT", -1, 1)
	bar.edge:SetPoint("BOTTOMRIGHT", status, "BOTTOMRIGHT", 1, -1)

	bar.back = Tex(bar, "BACKGROUND", -2)
	bar.back:SetAllPoints(status)

	if opts.icon then
		bar.hasIcon = true
		local size = h + 4
		local iconShadow = Tex(bar, "BACKGROUND", -4)
		iconShadow:SetVertexColor(0, 0, 0, 1)
		iconShadow:SetSize(size + 4, size + 4)
		iconShadow:SetPoint("RIGHT", status, "LEFT", -4, 0)
		bar.iconEdge = Tex(bar, "BACKGROUND", -3)
		bar.iconEdge:SetSize(size + 2, size + 2)
		bar.iconEdge:SetPoint("CENTER", iconShadow)
		bar.icon = bar:CreateTexture(nil, "ARTWORK")
		bar.icon:SetSize(size, size)
		bar.icon:SetPoint("CENTER", iconShadow)
		bar.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
	end

	-- Bright details and text on a frame above the fill.
	-- Parented to the main frame so dimming the fill leaves the text bright.
	local top = CreateFrame("Frame", nil, bar)
	top:SetAllPoints(status)
	top:SetFrameLevel(status:GetFrameLevel() + 2)
	bar.top = top
	bar.fillWidth = w - iconW
	bar.ticks = {}

	bar.sheen = Tex(top, "ARTWORK", 0, MEDIA .. "Sheen", "ADD")
	bar.sheen:SetAlpha(0.35)
	bar.sheen:Hide()

	bar.spark = Tex(top, "ARTWORK", 1, MEDIA .. "Spark", "ADD")
	bar.spark:SetSize(20, h + 18)
	bar.spark:SetPoint("CENTER", status:GetStatusBarTexture(), "RIGHT", 0, 0)

	bar.time = S.Text(top, 12, true)
	bar.time:SetPoint("RIGHT", status, "RIGHT", -7, 0)
	bar.time:SetJustifyH("RIGHT")
	bar.time:SetTextColor(1, 1, 1)

	bar.title = S.Text(top, 12, true)
	bar.title:SetPoint("LEFT", status, "LEFT", 7, 0)
	bar.title:SetPoint("RIGHT", bar.time, "LEFT", -8, 0)
	bar.title:SetJustifyH("LEFT")
	bar.title:SetTextColor(1, 0.95, 0.8)

	bar.statusText = S.Text(bar, 10, true)
	bar.statusText:SetPoint("TOP", status, "BOTTOM", 0, -4)
	bar.statusText:SetWidth(w)
	bar.statusText:SetTextColor(0.85, 0.85, 0.85)

	S.RestorePoint(bar, opts.db, opts.pointKey or "point", opts.defaultPoint)
	S.Scaled(bar)
	return bar
end

--------------------------------------------------------------------------------
-- Scale and glow settings
--------------------------------------------------------------------------------

function S.Scaled(frame)
	scaled[#scaled + 1] = frame
	if ns.global then frame:SetScale(ns.global.scale or 1) end
end

function S.ApplyGlobal()
	local scale = ns.global and ns.global.scale or 1
	for _, f in ipairs(scaled) do f:SetScale(scale) end
	for _, g in ipairs(glows) do
		if g.bar then
			g.bar.glow:SetShown(ns.global.glow)
		else
			g:SetAlpha(g.alpha or 0.35)
		end
	end
end
