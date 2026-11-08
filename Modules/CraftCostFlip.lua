--------------------------------------------------------------------------------
-- Craft Cost, part 3: the Flipping window. What can you make and sell on the
-- AH for more than the materials cost?
--
--   * Uses the recipes Craft Cost has saved and Auctionator's last scan, so it
--     makes no AH searches and works anywhere.
--   * Cost is always market price, ignoring your bags, because materials you
--     hold could be sold instead. Each material is at its cheapest: bought, or
--     crafted if that's less.
--   * Profit is the sell price after the AH cut, minus the cost. The AH deposit
--     isn't counted, and nothing here can tell how quickly an item sells.
--   * Items with no AH price, or a material with no price, are left out and
--     counted in the footer.
--------------------------------------------------------------------------------

local _, ns = ...
local S = ns.Style
local M = ns.byKey.craftcost

local WIN_W, WIN_H = 660, 500
local NUM_ROWS, ROW_H = 14, 26
local TOP_H, COLUMN_H = 40, 20
local ADD_W, PERCENT_W, MONEY_W = 40, 56, 96
local MAX_AMOUNT = 9999
local DEFAULT_POINT = { "CENTER", "CENTER", 0, 40 }

local db
local win
local offset = 0
local sortKey = "profit"
local amount = 1

local function Money(copper)
	if copper < 0 then return "-" .. M.Coins(-copper) end
	return M.Coins(copper)
end

local function Sorted()
	local rows, skipped = M.FlipData()
	local shown, losses = {}, 0
	for _, row in ipairs(rows) do
		if row.profit > 0 or db.flipLosses then
			shown[#shown + 1] = row
		else
			losses = losses + 1
		end
	end
	table.sort(shown, function(a, b)
		if a[sortKey] ~= b[sortKey] then return a[sortKey] > b[sortKey] end
		return a.id < b.id
	end)
	return shown, skipped, losses
end

local function Draw()
	if not win then return end
	local data, skipped, losses = Sorted()
	win.data = data

	local maxOffset = math.max(0, #data - NUM_ROWS)
	offset = math.min(offset, maxOffset)
	win.scroll:SetMinMaxValues(0, maxOffset)
	win.scroll:SetShown(maxOffset > 0)

	for i = 1, NUM_ROWS do
		local row, d = win.rows[i], data[i + offset]
		row.data = d
		if d then
			local color = d.profit > 0 and S.GOOD or S.BAD
			row.icon:SetTexture(ns.Try(C_Item.GetItemIconByID, d.id))
			row.name:SetText(d.name)
			row.cost:SetText(M.Coins(d.cost))
			row.sell:SetText((d.stale and (S.WARN .. "old|r ") or "") .. M.Coins(d.sell))
			row.profit:SetText(color .. Money(d.profit) .. "|r")
			row.percent:SetText(color .. math.floor(d.percent + 0.5) .. "%|r")
			row:Show()
		else
			row:Hide()
		end
	end

	win.empty:SetShown(#data == 0)
	win.sortProfit.label:SetText((sortKey == "profit" and S.GOLD or S.DIM) .. "Profit|r")
	win.sortPercent.label:SetText((sortKey == "percent" and S.GOLD or S.DIM) .. "%|r")
	win.lossButton.label:SetText(db.flipLosses and "Hide losses" or "Show losses")

	local known = M.KnownProfessions()
	win.footerText = ("Using: %s.  %d can't be priced, %d %s.  Prices are from your last AH scan."):format(
		known ~= "" and known or "no professions yet", skipped, losses, db.flipLosses and "at a loss" or "hidden as losses")
	win.footer:SetText(S.DIM .. win.footerText .. "|r")
end

local function ShowRowTooltip(row)
	local d = row.data
	if not d then return end
	GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
	GameTooltip:SetItemByID(d.id)
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Materials, per item:", 1, 0.82, 0)
	for _, p in ipairs(d.parts) do
		GameTooltip:AddDoubleLine(("%.3g x %s"):format(p.qty, p.name),
			M.Coins(p.cost) .. (p.crafted and " (crafted)" or ""), 1, 1, 1, 1, 1, 1)
	end
	GameTooltip:AddDoubleLine("After AH cut", M.Coins(d.net), 0.7, 0.7, 0.7, 1, 1, 1)
	GameTooltip:Show()
end

local function RightText(row, anchor, gap, width)
	local fs = S.Text(row, 12)
	fs:SetPoint("RIGHT", anchor, anchor == row and "RIGHT" or "LEFT", gap, 0)
	fs:SetWidth(width)
	fs:SetJustifyH("RIGHT")
	return fs
end

local function CreateRow(i)
	local row = CreateFrame("Button", nil, win)
	row:SetHeight(ROW_H)
	local y = -S.TITLE_H - TOP_H - COLUMN_H - (i - 1) * ROW_H
	row:SetPoint("TOPLEFT", S.PAD, y)
	row:SetPoint("TOPRIGHT", -S.PAD - 12, y)
	S.RowHighlight(row)
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(20, 20)
	row.icon:SetPoint("LEFT", 2, 0)
	row.add = S.Button(row, "Add", ADD_W, 20)
	row.add:SetPoint("RIGHT", -2, 0)
	row.add.tooltip = "Add the materials for the Amount above to your shopping list, using the cheapest way to make it."
	row.add:SetScript("OnClick", function()
		if row.data then M.AddBestRoute(row.data.recipe, amount) end
	end)
	row.percent = RightText(row, row.add, -6, PERCENT_W)
	row.profit = RightText(row, row.percent, -4, MONEY_W)
	row.sell = RightText(row, row.profit, -4, MONEY_W + 24)
	row.cost = RightText(row, row.sell, -4, MONEY_W)
	row.name = S.Text(row, 12)
	row.name:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
	row.name:SetPoint("RIGHT", row.cost, "LEFT", -6, 0)
	row.name:SetJustifyH("LEFT")
	row:SetScript("OnEnter", ShowRowTooltip)
	row:SetScript("OnLeave", function() GameTooltip_Hide() end)
	return row
end

local function SetSort(key)
	sortKey = key
	offset = 0
	win.scroll:SetValue(0)
	Draw()
end

local function SetLosses(on)
	db.flipLosses = on
	Draw()
end

local function SortHeader(x, width, key)
	local b = CreateFrame("Button", nil, win)
	b:SetSize(width, COLUMN_H)
	b:SetPoint("TOPRIGHT", x, -S.TITLE_H - TOP_H)
	b.label = S.Text(b, 11)
	b.label:SetPoint("RIGHT", -2, 0)
	b:SetScript("OnClick", function() SetSort(key) end)
	return b
end

local function Heading(x, text, right)
	local label = S.Text(win, 11)
	label:SetPoint(right and "TOPRIGHT" or "TOPLEFT", x, -S.TITLE_H - TOP_H - 4)
	label:SetText(S.GOLD .. text .. "|r")
end

local function CreateWindow()
	win = S.Window({
		name = "PredUIFlipWindow", title = "Flipping", width = WIN_W, height = WIN_H,
		onMoved = function(self) S.SavePoint(self, db, "flipPoint") end,
	})
	S.RestorePoint(win, db, "flipPoint", DEFAULT_POINT)

	local hint = S.Text(win, 11)
	hint:SetPoint("TOPLEFT", S.PAD, -S.TITLE_H - 14)
	hint:SetText(S.DIM .. "What you can craft and sell for more than it costs.|r")

	local box = S.EditBox(win, 52, 20)
	box:SetPoint("TOPRIGHT", -S.PAD, -S.TITLE_H - 10)
	box:SetNumeric(true)
	box:SetMaxLetters(4)
	box:SetText("1")
	box:SetJustifyH("CENTER")
	box:SetScript("OnTextChanged", function(self)
		amount = math.max(1, math.min(MAX_AMOUNT, math.floor(tonumber(self:GetText()) or 1)))
	end)
	box:SetScript("OnEnterPressed", box.ClearFocus)
	local label = S.Text(win, 11)
	label:SetPoint("RIGHT", box, "LEFT", -6, 0)
	label:SetText("Amount")

	win.lossButton = S.Button(win, "Show losses", 90, 20)
	win.lossButton:SetPoint("RIGHT", label, "LEFT", -12, 0)
	win.lossButton:SetScript("OnClick", function() SetLosses(not db.flipLosses) end)

	local right = -S.PAD - 12 - 2 - ADD_W - 6
	win.sortPercent = SortHeader(right, PERCENT_W, "percent")
	right = right - PERCENT_W - 4
	win.sortProfit = SortHeader(right, MONEY_W, "profit")
	right = right - MONEY_W - 4
	Heading(right - 2, "Sells for", true)
	right = right - MONEY_W - 24 - 4
	Heading(right - 2, "Cost", true)
	Heading(S.PAD + 30, "Item")

	win.rows = {}
	for i = 1, NUM_ROWS do win.rows[i] = CreateRow(i) end

	win.empty = S.Text(win, 12)
	win.empty:SetPoint("CENTER", 0, 20)
	win.empty:SetText(S.DIM .. "Nothing to flip. Open your professions, and scan the AH with Auctionator.|r")

	win.scroll = S.ScrollBar(win, function(value)
		offset = value
		Draw()
	end)
	win.scroll:SetPoint("TOPRIGHT", -S.PAD, -S.TITLE_H - TOP_H - COLUMN_H)
	win.scroll:SetHeight(NUM_ROWS * ROW_H)
	win:EnableMouseWheel(true)
	win:SetScript("OnMouseWheel", function(_, delta)
		win.scroll:SetValue(win.scroll:GetValue() - delta)
	end)

	win.footer = S.Text(win, 10)
	win.footer:SetPoint("BOTTOMLEFT", S.PAD, 10)
	win.footer:SetPoint("BOTTOMRIGHT", -S.PAD, 10)
	win.footer:SetJustifyH("LEFT")
	win.footerText = ""

	win:SetScript("OnShow", Draw)
	win:SetScript("OnHide", function() GameTooltip_Hide() end)

	-- For the scenario test.
	win.Draw, win.SetSort, win.SetLosses = Draw, SetSort, SetLosses
end

function M.ToggleFlip()
	if not win then return end
	win:SetShown(not win:IsShown())
end

function M.RefreshFlip()
	if win and win:IsShown() then Draw() end
end

function M.EnableFlip()
	db = M.db
	CreateWindow()
end

M.launcher = {
	{
		icon = "Interface\\Icons\\INV_Misc_Coin_02", label = "Flipping",
		hint = "What you can craft and sell at a profit.",
		func = function() M.ToggleFlip() end,
	},
}

SLASH_PREDUIFLIP1 = "/flip"
SlashCmdList.PREDUIFLIP = ns.SlashHandler(M, function(msg)
	if msg:lower():match("^%s*reset%s*$") then
		db.flipPoint = nil
		S.RestorePoint(win, db, "flipPoint", DEFAULT_POINT)
		M.Say("Flipping window position reset.")
	else
		M.ToggleFlip()
	end
end)
