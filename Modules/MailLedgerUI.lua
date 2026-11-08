-- Mail Ledger: the panel shown beside the mailbox, and its lines on the
-- PredUI minimap button.

local _, ns = ...
local L = ns.byKey.mail
local S = ns.Style

local WIDTH = 300
local PADDING = S.PAD
local ROW_HEIGHT = 15
local LOG_HEIGHT = 96
local LOG_PREFILL = 40
local SALE_ROWS = 5
local SALE_NAME_WIDTH = 165

local DIM, GOOD, BAD, WARN = S.DIM, S.GOOD, S.BAD, S.WARN

local panel
local rows = {}
local labels = {}
local refreshQueued = false

---------------------------------------------------------------------------
-- Layout helpers
---------------------------------------------------------------------------

local cursorY

local function AddHeading(text)
	cursorY = cursorY - 8
	S.Heading(panel, text, cursorY)
	cursorY = cursorY - ROW_HEIGHT - 3
end

local function AddRow(key, label)
	local left = S.Text(panel, 11)
	left:SetPoint("TOPLEFT", PADDING + 6, cursorY)
	left:SetTextColor(0.85, 0.85, 0.85)
	left:SetText(label)
	local right = S.Text(panel, 11)
	right:SetPoint("TOPRIGHT", -PADDING, cursorY)
	right:SetJustifyH("RIGHT")
	rows[key] = right
	labels[key] = left
	cursorY = cursorY - ROW_HEIGHT
end

local function SetValue(key, text)
	rows[key]:SetText(text)
end

-- Grey when zero, so the rows that matter stand out.
local function SetMoney(key, copper, color)
	if copper == 0 then
		SetValue(key, DIM .. "0|r")
	elseif color then
		SetValue(key, color .. (copper > 0 and "+" or "") .. "|r" .. L.Money(copper))
	else
		SetValue(key, L.Money(copper))
	end
end

---------------------------------------------------------------------------
-- Activity log
---------------------------------------------------------------------------

local CATEGORY_LABELS = {
	sale = "Sold",
	refund = "Refund",
	player = "From",
	cod = "COD for",
	other = "Mail",
	codPaid = "COD paid",
	sent = "Sent to",
}

local function FormatLogEntry(entry)
	local clock = DIM .. date("%H:%M", entry.t) .. "|r "
	if entry.c == "item" then
		local count = (entry.n and entry.n > 1) and (" x" .. entry.n) or ""
		local suffix = ""
		if entry.k == "won" then
			suffix = DIM .. " (won)|r"
		elseif entry.k == "unsold" then
			suffix = DIM .. " (unsold)|r"
		end
		return clock .. tostring(entry.i) .. count .. suffix
	end
	local outgoing = entry.c == "codPaid" or entry.c == "sent"
	local amount = (outgoing and (BAD .. "-|r") or (GOOD .. "+|r")) .. L.Money(entry.m)
	local label = CATEGORY_LABELS[entry.c] or entry.c
	if entry.c == "sale" then
		local count = (entry.n and entry.n > 1) and (" x" .. entry.n) or ""
		return clock .. amount .. " " .. label .. " " .. tostring(entry.i or "item") .. count
	elseif entry.c == "cod" then
		return clock .. amount .. " " .. label .. " " .. tostring(entry.i or "item")
	end
	return clock .. amount .. " " .. label .. " " .. tostring(entry.s or "?")
end

function L.OnLogEntry(entry)
	if panel then panel.log:AddMessage(FormatLogEntry(entry)) end
end

local function BuildLog()
	local log = CreateFrame("ScrollingMessageFrame", nil, panel)
	log:SetPoint("BOTTOMLEFT", PADDING, PADDING)
	log:SetPoint("BOTTOMRIGHT", -PADDING, PADDING)
	log:SetHeight(LOG_HEIGHT)
	log:SetFontObject(GameFontHighlightSmall)
	log:SetJustifyH("LEFT")
	log:SetFading(false)
	log:SetMaxLines(500)
	log:EnableMouseWheel(true)
	log:SetHyperlinksEnabled(true)
	log:SetScript("OnMouseWheel", function(self, delta)
		if delta > 0 then self:ScrollUp() else self:ScrollDown() end
	end)
	log:SetScript("OnHyperlinkEnter", function(self, link)
		GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
		GameTooltip:SetHyperlink(link)
		GameTooltip:Show()
	end)
	log:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)
	panel.log = log

	local entries = L.char.log
	for i = math.max(1, #entries - LOG_PREFILL + 1), #entries do
		log:AddMessage(FormatLogEntry(entries[i]))
	end
end

---------------------------------------------------------------------------
-- Refresh
---------------------------------------------------------------------------

-- Sold auctions whose mail is on its way: up to SALE_ROWS rows, then a total.
local function RefreshSales()
	local list, total = L.RealmIncomingAuctions()
	for i = 1, SALE_ROWS do
		local key, row = "sale" .. i, list[i]
		if row then
			local sale = row.sale
			local count = (sale.count and sale.count > 1) and (" x" .. sale.count) or ""
			labels[key]:SetText(L.SaleOwnerPrefix(row) .. tostring(sale.item) .. count)
			local net = L.SaleNet(sale)
			local when = L.SaleWhen(sale)
			if L.SaleArrival(sale) <= time() then when = GOOD .. when .. "|r" end
			SetValue(key, (net and L.Money(net) or (DIM .. "?|r")) .. DIM .. " · |r" .. when)
		elseif i == 1 then
			labels[key]:SetText(DIM .. "Nothing sold yet|r")
			SetValue(key, "")
		else
			labels[key]:SetText("")
			SetValue(key, "")
		end
	end
	if #list > SALE_ROWS then
		labels.saleMore:SetText(DIM .. "and " .. (#list - SALE_ROWS) .. " more (/mledger sales)|r")
	else
		labels.saleMore:SetText("")
	end
	SetMoney("saleTotal", total)
end

local function Refresh()
	if not panel or not panel:IsShown() then return end

	local visit = L.visit
	if visit then
		panel.total:SetText(L.Money(L.Income(visit)))
		SetMoney("sale", visit.sale)
		SetMoney("fee", visit.fee)
		SetMoney("refund", visit.refund)
		SetMoney("player", visit.player)
		SetMoney("cod", visit.cod)
		SetMoney("other", visit.other)
		SetMoney("spent", -(visit.codPaid + visit.sent + visit.postage))
		SetValue("opened", L.Plural(visit.mails, "mail") .. ", " .. L.Plural(visit.items, "item"))
		SetValue("returns", visit.won .. " won, " .. visit.unsold .. " unsold")
		local change = GetMoney() - L.visitStartMoney
		SetMoney("change", change, change > 0 and GOOD or BAD)
	else
		panel.total:SetText(DIM .. "Open a mailbox|r")
		for _, key in ipairs({ "sale", "fee", "refund", "player", "cod", "other", "spent", "change" }) do
			SetMoney(key, 0)
		end
		SetValue("opened", DIM .. "0|r")
		SetValue("returns", DIM .. "0|r")
	end

	local inbox = L.char.inbox
	if inbox then
		SetMoney("waiting", inbox.money)
		SetMoney("ahPending", inbox.ahPending)
		SetMoney("codDue", inbox.codDue)
		if inbox.total > inbox.shown then
			SetValue("mailCount", WARN .. inbox.shown .. " shown of " .. inbox.total .. "|r")
		else
			SetValue("mailCount", inbox.total .. ", " .. L.Plural(inbox.attachments, "attachment"))
		end
		if inbox.soonest and inbox.total > 0 then
			local remaining = inbox.soonest - time()
			local text = L.Duration(remaining)
			local urgent = remaining < L.Setting("warnDays") * 86400
			SetValue("expires", urgent and (WARN .. text .. "|r") or text)
		else
			SetValue("expires", DIM .. "none|r")
		end
	else
		for _, key in ipairs({ "waiting", "ahPending", "codDue" }) do SetValue(key, DIM .. "?|r") end
		SetValue("mailCount", DIM .. "not checked yet|r")
		SetValue("expires", DIM .. "?|r")
	end

	RefreshSales()

	SetMoney("today", L.Income(L.History(0)))
	SetMoney("week", L.Income(L.History(6)))
	SetMoney("month", L.Income(L.History(29)))
	SetMoney("allTime", L.Income(L.History(nil)))

	SetValue("gold", L.Money(GetMoney()))
	local realmGold, characters = 0, L.RealmCharacters()
	for _, char in ipairs(characters) do realmGold = realmGold + (char.gold or 0) end
	SetValue("realmGold", L.Money(realmGold))
	labels.realmGold:SetText("Realm total (" .. #characters .. " chars)")
end

-- Bursts of mail events collapse into one redraw.
function L.RequestRefresh()
	if refreshQueued or not panel then return end
	refreshQueued = true
	C_Timer.After(0.1, function()
		refreshQueued = false
		Refresh()
	end)
end

---------------------------------------------------------------------------
-- PredUI minimap and floating buttons: tooltip lines and right-click
---------------------------------------------------------------------------

function L.MinimapTooltip()
	if not L.char then return end
	GameTooltip:AddLine("Mail Ledger", 1, 0.82, 0)
	if L.visit then
		GameTooltip:AddDoubleLine("Looted this visit", L.Money(L.Income(L.visit)), 1, 1, 1, 1, 1, 1)
	end
	GameTooltip:AddDoubleLine("Mail income today", L.Money(L.Income(L.History(0))), 1, 1, 1, 1, 1, 1)
	local inbox = L.char.inbox
	if inbox then
		GameTooltip:AddDoubleLine("Gold in the mailbox", L.Money(inbox.money), 1, 1, 1, 1, 1, 1)
	end
	local sales, salesTotal = L.IncomingAuctions()
	if #sales > 0 then
		GameTooltip:AddDoubleLine("Auction gold on its way", L.Money(salesTotal) .. " (next " .. L.SaleWhen(sales[1]) .. ")", 1, 1, 1, 1, 1, 1)
	end

	-- Gold of every character on this realm, richest first (saved at their
	-- last login or money change).
	L.char.gold = ns.PublicNumber(GetMoney()) or L.char.gold
	local characters, total = L.RealmCharacters(), 0
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Gold on " .. ns.RealmLabel(L.char.realm), 1, 0.82, 0)
	for _, char in ipairs(characters) do
		total = total + (char.gold or 0)
		local _, coming = L.IncomingAuctions(char)
		local right = L.Money(char.gold)
		if coming > 0 then right = right .. DIM .. " +" .. L.Money(coming) .. " sold|r" end
		GameTooltip:AddDoubleLine(L.ColoredName(char), right, 1, 1, 1, 1, 1, 1)
	end
	if #characters > 1 then
		GameTooltip:AddDoubleLine("Total", L.Money(total), 1, 0.82, 0, 1, 1, 1)
	end
end

function L.MinimapRightClick()
	if panel then L.TogglePanel() end
end

L.launcher = L.launcher or {}
table.insert(L.launcher, 1, {
	icon = "Interface\\Icons\\INV_Letter_15", label = "Mail Ledger", hint = "Gold and items from the mailbox (/mledger).",
	func = function() if panel then L.TogglePanel() end end,
})

---------------------------------------------------------------------------
-- Panel
---------------------------------------------------------------------------

local function ApplyPosition()
	panel:ClearAllPoints()
	local saved = L.db.settings.position
	if saved then
		panel:SetPoint(saved.point, UIParent, saved.relativePoint, saved.x, saved.y)
	elseif MailFrame and MailFrame:IsShown() then
		panel:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", 6, 0)
	else
		panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end
end

function L.ResetPosition()
	L.db.settings.position = nil
	if panel then ApplyPosition() end
end

function L.TogglePanel()
	if panel:IsShown() then
		panel:Hide()
	else
		ApplyPosition()
		panel:Show()
	end
end

function L.OnMailShow()
	if L.Setting("autoShow") then
		ApplyPosition()
		panel:Show()
	end
end

function L.OnMailClosed()
	panel:Hide()
end

function L.BuildUI()
	panel = S.Window({
		name = "PredUIMailLedger", title = "Mail Ledger", width = WIDTH, height = 200,
		onMoved = function(self)
			local point, _, relativePoint, x, y = self:GetPoint()
			L.db.settings.position = { point = point, relativePoint = relativePoint, x = x, y = y }
		end,
	})
	panel:SetScript("OnShow", Refresh)
	-- Keeps the sale countdowns moving while the panel is open.
	C_Timer.NewTicker(30, function()
		if panel:IsShown() then Refresh() end
	end)

	cursorY = -S.TITLE_H - 8
	local totalLabel = S.Text(panel, 11)
	totalLabel:SetPoint("TOPLEFT", PADDING, cursorY)
	totalLabel:SetTextColor(0.7, 0.7, 0.7)
	totalLabel:SetText("Looted this visit")
	cursorY = cursorY - 15
	panel.total = S.Text(panel, 18)
	panel.total:SetPoint("TOPLEFT", PADDING, cursorY)
	cursorY = cursorY - 26

	AddRow("sale", "Auction sales (after cut)")
	AddRow("fee", DIM .. "AH cut taken|r")
	AddRow("refund", "Auction refunds")
	AddRow("player", "From players")
	AddRow("cod", "COD payments")
	AddRow("other", "Other")
	AddRow("spent", "COD paid, sent, postage")
	AddRow("change", "Your gold change")
	AddRow("opened", "Emptied")
	AddRow("returns", "Auction items")

	AddHeading("Still in the mailbox")
	AddRow("waiting", "Gold to collect (listed mail)")
	AddRow("ahPending", "Pending invoices")
	AddRow("codDue", "COD you would owe")
	AddRow("mailCount", "Mails")
	AddRow("expires", "Next expiry")

	AddHeading("Sold, mail on its way")
	for i = 1, SALE_ROWS do
		AddRow("sale" .. i, "")
		labels["sale" .. i]:SetWidth(SALE_NAME_WIDTH)
		labels["sale" .. i]:SetJustifyH("LEFT")
		labels["sale" .. i]:SetWordWrap(false)
	end
	AddRow("saleMore", "")
	AddRow("saleTotal", "Total after AH cut")

	AddHeading("Mail income")
	AddRow("today", "Today")
	AddRow("week", "Last 7 days")
	AddRow("month", "Last 30 days")
	AddRow("allTime", "All time")

	AddHeading("Gold")
	AddRow("gold", L.char.name)
	AddRow("realmGold", "Realm total")

	AddHeading("Activity")
	panel:SetHeight(-cursorY + LOG_HEIGHT + PADDING + 2)
	BuildLog()
end
