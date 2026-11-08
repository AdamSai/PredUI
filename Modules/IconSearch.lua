--------------------------------------------------------------------------------
-- Icon Search: search every macro icon by name or file ID, and apply it to the
-- macro or equipment set you're editing.
--
--   * Modern clients list macro icons as bare file IDs, which carry no text. To
--     make them searchable by name, the spell list is walked in the background
--     (a few ms a frame, from 15 s after login) and each icon remembers the
--     spell names that use it. That index is saved per game build, so it's only
--     built once a patch. Until it's done, name search covers part of the icons;
--     file-ID search always works.
--   * A "Search Icons" button sits under the macro window and the equipment set
--     icon picker.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.Style

local M = ns.NewModule("icon", {
	title = "Icon Search",
	notes = "Search every macro icon by name or file ID and apply it to a macro or equipment set. Type /iconsearch.",
	defaults = { buttons = true },
})

local COLS, ROWS = 10, 8
local ICON_SIZE, SPACING = 36, 4
local CELL = ICON_SIZE + SPACING
local GRID_TOP = -82
local BOTTOM_H = 84

local MAX_SPELL_ID = WOW_PROJECT_ID == WOW_PROJECT_MAINLINE and 1700000 or 90000
local FRAME_BUDGET_MS = 3
local MAX_NAMES_LEN = 140

local db
local icons = {}               -- every macro icon: a file ID (number) or an icon name (string)
local names = {}               -- [fileID] = "spell one / spell two", filled by the indexer
local indexProgress = 0        -- 0..1, how much of the spell-ID range has been indexed
local frame, searchBox, countText, selectedBox, previewTex, scrollBar
local buttons = {}
local results = {}
local offset = 0               -- first row shown
local selected                 -- icon entry currently selected

--------------------------------------------------------------------------------
-- Icon list
--------------------------------------------------------------------------------

local function LoadIcons()
	local list, seen = {}, {}
	local function add(source)
		for i = 1, #source do
			local v = source[i]
			local key = type(v) == "string" and v:lower() or v
			if not seen[key] then
				seen[key] = true
				list[#list + 1] = v
			end
		end
	end
	-- Each call gets its own table; the APIs append to whatever they are given.
	local getters = { GetLooseMacroIcons, GetLooseMacroItemIcons, GetMacroIcons, GetMacroItemIcons }
	for i = 1, 4 do
		local getter = getters[i]
		if getter then
			local t = {}
			if pcall(getter, t) then add(t) end
		end
	end
	icons = list
end

local function TexturePath(icon)
	if type(icon) == "string" and not icon:find("[\\/]") then
		return "Interface\\Icons\\" .. icon
	end
	return icon
end

local function DisplayName(icon)
	if type(icon) == "string" then
		return icon:match("([^\\/]+)$") or icon
	end
	return tostring(icon)
end

--------------------------------------------------------------------------------
-- Spell-name index
--------------------------------------------------------------------------------

local function SpellInfo(id)
	local info = C_Spell.GetSpellInfo(id)
	if info then return info.name, info.iconID end
end

local nextId = 1
local indexer = CreateFrame("Frame")
indexer:Hide()

local OnIndexProgress

indexer:SetScript("OnUpdate", function(self)
	local start = debugprofilestop()
	local id = nextId
	while id <= MAX_SPELL_ID do
		local name, icon = SpellInfo(id)
		if name and name ~= "" and type(icon) == "number" then
			local lname = name:lower()
			local existing = names[icon]
			if not existing then
				names[icon] = lname
			elseif #existing < MAX_NAMES_LEN and not existing:find(lname, 1, true) then
				names[icon] = existing .. " / " .. lname
			end
		end
		id = id + 1
		-- Checking the clock for every spell is wasteful; every 256 is plenty.
		if id % 256 == 0 and debugprofilestop() - start > FRAME_BUDGET_MS then
			break
		end
	end
	nextId = id
	db.nextId = id
	indexProgress = math.min(1, id / MAX_SPELL_ID)
	if id > MAX_SPELL_ID then
		self:Hide()
		db.complete = true
	end
	if OnIndexProgress then OnIndexProgress() end
end)

--------------------------------------------------------------------------------
-- Search
--------------------------------------------------------------------------------

-- Every space-separated term must appear in the icon name, its file ID or one
-- of the spell names that use it.
local function Search(query)
	query = (query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if query == "" then return icons end

	local terms = {}
	for term in query:gmatch("%S+") do terms[#terms + 1] = term end

	local list = {}
	for i = 1, #icons do
		local icon = icons[i]
		local text, extra
		if type(icon) == "string" then
			text = icon:lower()
		else
			text = tostring(icon)
			extra = names[icon]
		end
		local match = true
		for t = 1, #terms do
			local term = terms[t]
			if not (text:find(term, 1, true) or (extra and extra:find(term, 1, true))) then
				match = false
				break
			end
		end
		if match then list[#list + 1] = icon end
	end
	return list
end

--------------------------------------------------------------------------------
-- Window
--------------------------------------------------------------------------------

local function MaxOffset()
	return math.max(0, math.ceil(#results / COLS) - ROWS)
end

local function Update()
	if not frame then return end
	offset = math.max(0, math.min(offset, MaxOffset()))
	for r = 1, ROWS do
		for c = 1, COLS do
			local btn = buttons[(r - 1) * COLS + c]
			local icon = results[(offset + r - 1) * COLS + c]
			if icon then
				btn.icon = icon
				btn.tex:SetTexture(TexturePath(icon))
				btn.selected:SetShown(icon == selected)
				btn:Show()
			else
				btn.icon = nil
				btn:Hide()
			end
		end
	end

	local text = #results .. " icons"
	if indexProgress < 1 then
		text = text .. string.format("  %s(indexing names: %d%%)|r", S.DIM, indexProgress * 100)
	end
	countText:SetText(text)
end

local function SetOffset(value)
	offset = value
	Update()
end

local function RunSearch()
	if not frame then return end
	results = Search(searchBox:GetText())
	scrollBar:SetMinMaxValues(0, MaxOffset())
	scrollBar:SetValue(0)
	SetOffset(0)
end

local function Select(icon)
	selected = icon
	previewTex:SetTexture(TexturePath(icon))
	selectedBox:SetText(DisplayName(icon))
	selectedBox:HighlightText()
	selectedBox:SetFocus()
	Update()
end

-- Applying an icon to the macro open in the Blizzard macro window.
local function GetSelectedMacroIndex()
	if not (MacroFrame and MacroFrame:IsShown()) then return end
	local index
	if MacroFrame.GetSelectedIndex then
		local ok, value = pcall(MacroFrame.GetSelectedIndex, MacroFrame)
		if ok then index = value end
	end
	return index or MacroFrame.selectedMacro
end

local function ApplyToMacro()
	if not selected then return M.Say("pick an icon first.") end
	local index = GetSelectedMacroIndex()
	if not index then return M.Say("open the macro window (/macro) and select a macro first.") end
	if InCombatLockdown() then return M.Say("can't change macros in combat.") end

	local name, _, body = GetMacroInfo(index)
	if not name then return M.Say("that macro slot is empty.") end
	EditMacro(index, name, selected, body)

	-- Refresh Blizzard's macro window so it shows the new icon.
	pcall(function()
		if MacroFrame.SelectMacro then MacroFrame:SelectMacro(index) end
		if MacroFrame.Update then MacroFrame:Update() end
	end)
	M.Say("set the icon of \"" .. name .. "\" to " .. DisplayName(selected) .. ".")
end

-- Applying an icon to an equipment set (character window > Equipment Manager).
local function GearPopup()
	return GearManagerPopupFrame
end

local function EquipmentPane()
	return PaperDollFrame and PaperDollFrame.EquipmentManagerPane
end

local function GetSelectedSetID()
	local popup = GearPopup()
	local pane = EquipmentPane()
	return (popup and popup:IsShown() and (popup.setID or popup.selectedSetID))
		or (pane and pane.selectedSetID)
end

local function ApplyToSet()
	if not selected then return M.Say("pick an icon first.") end
	if not C_EquipmentSet then return M.Say("this client has no equipment sets.") end
	local setID = GetSelectedSetID()
	if not setID then return M.Say("open the character window > Equipment Manager and select a set first.") end
	if InCombatLockdown() then return M.Say("can't change equipment sets in combat.") end
	local name = C_EquipmentSet.GetEquipmentSetInfo(setID)
	if not name then return M.Say("that equipment set no longer exists.") end
	C_EquipmentSet.ModifyEquipmentSet(setID, name, TexturePath(selected))

	-- Refresh Blizzard's equipment manager list and the open popup, if any.
	pcall(function()
		local pane = EquipmentPane()
		if pane and pane.Update then pane:Update() end
		local popup = GearPopup()
		if popup and popup:IsShown() then
			popup.selectedIcon = TexturePath(selected)
			local area = popup.BorderBox and popup.BorderBox.SelectedIconArea
			if area and area.SelectedIconButton and area.SelectedIconButton.SetIconTexture then
				area.SelectedIconButton:SetIconTexture(TexturePath(selected))
			end
		end
	end)
	M.Say("set the icon of equipment set \"" .. name .. "\" to " .. DisplayName(selected) .. ".")
end

local function CreateIconButton(index)
	local btn = CreateFrame("Button", nil, frame)
	btn:SetSize(ICON_SIZE, ICON_SIZE)

	btn.selected = S.Texture(btn, "BACKGROUND", -2)
	btn.selected:SetVertexColor(S.ACCENT[1], S.ACCENT[2], S.ACCENT[3], 1)
	btn.selected:SetPoint("TOPLEFT", -2, 2)
	btn.selected:SetPoint("BOTTOMRIGHT", 2, -2)
	btn.selected:Hide()

	local edge = S.Texture(btn, "BACKGROUND", -1)
	edge:SetVertexColor(0, 0, 0, 1)
	edge:SetPoint("TOPLEFT", -1, 1)
	edge:SetPoint("BOTTOMRIGHT", 1, -1)

	btn.tex = btn:CreateTexture(nil, "ARTWORK")
	btn.tex:SetAllPoints()
	btn.tex:SetTexCoord(0.06, 0.94, 0.06, 0.94)

	local hl = btn:CreateTexture(nil, "HIGHLIGHT")
	hl:SetTexture("Interface\\Buttons\\WHITE8x8")
	hl:SetAllPoints()
	hl:SetVertexColor(1, 1, 1, 0.18)
	hl:SetBlendMode("ADD")

	local col, row = (index - 1) % COLS, math.floor((index - 1) / COLS)
	btn:SetPoint("TOPLEFT", frame, "TOPLEFT", S.PAD + 2 + col * CELL, GRID_TOP - row * CELL)

	btn:SetScript("OnClick", function(self) Select(self.icon) end)
	btn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(DisplayName(self.icon), 1, 1, 1)
		if type(self.icon) == "number" and names[self.icon] then
			GameTooltip:AddLine(names[self.icon], 0.7, 0.7, 0.7, true)
		end
		GameTooltip:Show()
	end)
	btn:SetScript("OnLeave", GameTooltip_Hide)
	return btn
end

local function CreateWindow()
	local width = S.PAD + 2 + COLS * CELL + 16 + S.PAD
	local height = -GRID_TOP + ROWS * CELL + BOTTOM_H

	frame = S.Window({ name = "PredUIIconSearch", title = "Icon Search", width = width, height = height })
	frame:SetPoint("CENTER")

	searchBox = S.EditBox(frame, width - S.PAD * 2, 22)
	searchBox:SetPoint("TOPLEFT", S.PAD, -S.TITLE_H - 10)
	local hintText = S.Text(searchBox, 11)
	hintText:SetPoint("LEFT", 7, 0)
	hintText:SetTextColor(0.5, 0.5, 0.5)
	hintText:SetText("Search by spell name or file ID...")
	local token = 0
	searchBox:SetScript("OnTextChanged", function(self)
		hintText:SetShown(self:GetText() == "")
		-- Debounce: only search once typing pauses.
		token = token + 1
		local mine = token
		C_Timer.After(0.15, function()
			if mine == token then RunSearch() end
		end)
	end)

	countText = S.Text(frame, 11)
	countText:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", 1, -5)
	countText:SetTextColor(0.8, 0.8, 0.8)

	for i = 1, COLS * ROWS do
		buttons[i] = CreateIconButton(i)
	end

	scrollBar = S.ScrollBar(frame, SetOffset)
	scrollBar:SetPoint("TOPRIGHT", -S.PAD, GRID_TOP)
	scrollBar:SetHeight(ROWS * CELL - SPACING)

	frame:EnableMouseWheel(true)
	frame:SetScript("OnMouseWheel", function(_, delta)
		scrollBar:SetValue(math.max(0, math.min(MaxOffset(), offset - delta * 2)))
	end)

	S.Divider(frame, GRID_TOP - ROWS * CELL - 4)

	-- Selected icon: preview, copyable name/ID, apply buttons.
	local previewFrame = CreateFrame("Frame", nil, frame)
	previewFrame:SetSize(44, 44)
	previewFrame:SetPoint("BOTTOMLEFT", S.PAD + 2, 18)
	S.Body(previewFrame, { 0, 0, 0, 1 }, S.ACCENT)
	previewTex = previewFrame:CreateTexture(nil, "ARTWORK")
	previewTex:SetPoint("TOPLEFT", 1, -1)
	previewTex:SetPoint("BOTTOMRIGHT", -1, 1)
	previewTex:SetTexCoord(0.06, 0.94, 0.06, 0.94)
	previewTex:SetTexture(134400) -- question mark

	selectedBox = S.EditBox(frame, 180, 22)
	selectedBox:SetPoint("TOPLEFT", previewFrame, "TOPRIGHT", 10, 0)
	selectedBox:SetScript("OnTextChanged", function(self, userInput)
		-- Read-only: put the text back if someone types in it.
		if userInput then self:SetText(selected and DisplayName(selected) or "") end
	end)

	local hint = S.Text(frame, 10)
	hint:SetPoint("TOPLEFT", selectedBox, "BOTTOMLEFT", 1, -6)
	hint:SetTextColor(0.6, 0.6, 0.6)
	hint:SetText("Ctrl+C copies the name / file ID")

	local applyButton = S.Button(frame, "Apply to macro", 140, 22)
	applyButton:SetPoint("BOTTOMRIGHT", -S.PAD, 42)
	applyButton:SetScript("OnClick", ApplyToMacro)
	applyButton.tooltip = "Sets this icon on the macro selected in the macro window (/macro)."

	local setButton = S.Button(frame, "Apply to equip. set", 140, 22)
	setButton:SetPoint("TOP", applyButton, "BOTTOM", 0, -4)
	setButton:SetScript("OnClick", ApplyToSet)
	setButton.tooltip = "Sets this icon on the equipment set selected in the character window's Equipment Manager."
	if not C_EquipmentSet then setButton:Hide() end

	frame:SetScript("OnShow", RunSearch)

	local throttled
	OnIndexProgress = function()
		-- Don't re-run the search every frame; just refresh the counter now and then.
		if frame:IsShown() and not throttled then
			throttled = true
			C_Timer.After(1, function()
				throttled = nil
				if frame:IsShown() then Update() end
			end)
		end
	end
end

local function ShowWindow(anchorTo)
	if not frame then CreateWindow() end
	if anchorTo and not frame:IsShown() and anchorTo:IsShown() then
		frame:ClearAllPoints()
		frame:SetPoint("TOPLEFT", anchorTo, "TOPRIGHT", 12, 0)
	end
	frame:Show()
	searchBox:SetFocus()
end

local function ToggleFrom(anchor)
	if frame and frame:IsShown() then frame:Hide() else ShowWindow(anchor) end
end

--------------------------------------------------------------------------------
-- "Search Icons" buttons under the macro window and the equipment set picker
--------------------------------------------------------------------------------

local macroButton, gearButton

local function AttachButtons()
	if not db.buttons then return end
	if not macroButton and MacroFrame then
		macroButton = S.Button(MacroFrame, "Search Icons", 110, 22)
		macroButton:SetPoint("TOPRIGHT", MacroFrame, "BOTTOMRIGHT", 0, -2)
		macroButton:SetScript("OnClick", function() ToggleFrom(MacroFrame) end)
	end
	local popup = GearPopup()
	if not gearButton and popup then
		gearButton = S.Button(popup, "Search Icons", 110, 22)
		gearButton:SetPoint("TOPRIGHT", popup, "BOTTOMRIGHT", 0, -2)
		gearButton:SetScript("OnClick", function() ToggleFrom(popup) end)
	end
end

local function UpdateButtons()
	AttachButtons()
	if macroButton then macroButton:SetShown(db.buttons) end
	if gearButton then gearButton:SetShown(db.buttons) end
end

function M:OnAddonLoaded(name)
	if name == "Blizzard_MacroUI" or name == "Blizzard_UIPanels_Game" then AttachButtons() end
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

function M.Open()
	ShowWindow()
end

M.launcher = {
	{ icon = "Interface\\Icons\\INV_Misc_Spyglass_03", label = "Icon Search", hint = "Search every icon by name (/iconsearch).", func = M.Open },
}

local function OnSlash(msg)
	msg = strtrim(msg)
	if msg == "options" then
		ns.OpenSettings(M)
		return
	end
	ShowWindow()
	if msg ~= "" then searchBox:SetText(msg) end
end

M.options = {
	{ type = "button", label = "Icon search window", button = "Open", tooltip = "Open the search window. Also /iconsearch [text].", func = function() M.Open() end },
	{ type = "checkbox", key = "buttons", label = "Search Icons buttons", tooltip = "Show a Search Icons button under the macro window and the equipment set icon picker.", onChange = UpdateButtons },
}

--------------------------------------------------------------------------------
-- Start-up
--------------------------------------------------------------------------------

function M:Enable()
	db = self.db
	local build = select(4, GetBuildInfo())

	-- A new game build can add spells and icons: start the index over.
	if db.build ~= build or db.maxId ~= MAX_SPELL_ID or type(db.names) ~= "table" then
		db.build, db.maxId = build, MAX_SPELL_ID
		db.names, db.nextId, db.complete = {}, 1, false
	end
	names = db.names
	nextId = db.nextId or 1
	indexProgress = db.complete and 1 or math.min(1, nextId / MAX_SPELL_ID)

	local events = CreateFrame("Frame")
	events:RegisterEvent("PLAYER_LOGIN")
	events:RegisterEvent("PLAYER_ENTERING_WORLD")
	events:SetScript("OnEvent", function(self, event)
		if event == "PLAYER_LOGIN" then
			LoadIcons()
			if not db.complete then
				-- Let the login rush finish before we start burning frame time.
				C_Timer.After(15, function() indexer:Show() end)
			end
		else
			AttachButtons()
			self:UnregisterEvent(event)
		end
	end)
	AttachButtons()
end

SLASH_PREDUIICON1, SLASH_PREDUIICON2, SLASH_PREDUIICON3 = "/iconsearch", "/isearch", "/macroicons"
SlashCmdList.PREDUIICON = ns.SlashHandler(M, OnSlash)
