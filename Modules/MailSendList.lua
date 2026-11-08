-- Mail Ledger: "Worth sending", a list left of the mailbox of the items in
-- your bags worth sending to your bank alt, most valuable stack first.
--
--   * Value is Auctionator's price x stack count. Items with no AH price are
--     left out. Without Auctionator the list just says it needs it.
--   * Beside it: how far the AH price is above (or below) the vendor price,
--     coloured like Bank Alt's coins: green, blue from +100%, purple from
--     +300%, orange from +1000%, red when the vendor pays more. "AH only" when
--     the item can't be vendored.
--   * When Bank Alt is on, its rules decide what counts (not soulbound, not
--     ignored, not needed for a quest, above its Min AH price), so the two
--     always agree. When it's off: any unbound item with an AH price.
--   * Sorted by stack value (a valuable stack beats a valuable single item),
--     or, with the "Sort by" setting, by % over vendor. Items that can't be
--     vendored (no % to compare) go first then, by value.
--   * Click an item to attach it to the mail (switches to Send Mail first).
--     "Attach top N" fills the free attachment slots. Attaching is pick up +
--     ClickSendMailItemButton(), the same call as dropping an item on the
--     mail. Attached items are locked in your bags, so they drop off the list.
--   * Not opened on the bank alt itself (the default recipient).
--   * Ctrl+Alt+right-click an item to never suggest it: the same ignore list
--     as Bank Alt (db.ignored, per item ID). Ignoring in your bags updates the
--     list straight away, through Bank Alt's ignoreListeners.

local _, ns = ...
local L = ns.byKey.mail
local S = ns.Style

local WIDTH = 330
local PERCENT_W = 52
local ROW_H = 20
local ROWS = 14
local ICON = 16
local PAD = S.PAD
local LIST_TOP = -S.TITLE_H - 8
local MAX_SEND = ATTACHMENTS_MAX_SEND or 12

local panel, scrollBar, summary, attachButton, emptyText
local rows = {}
local items = {}
local offset = 0
local refreshQueued = false

---------------------------------------------------------------------------
-- Scanning
---------------------------------------------------------------------------

-- Same tiers as Bank Alt's coin colours.
local TIERS = {
	{ min = 1000, color = "|cffff8c1a" },
	{ min = 300,  color = "|cffcc73ff" },
	{ min = 100,  color = "|cff59a6ff" },
	{ min = 0,    color = "|cff59ff59" },
}

-- % the AH price is over the vendor price, or nil when it can't be vendored.
local function VendorPercent(info, stackValue)
	if info.hasNoValue then return nil end
	local sellPrice = ns.PublicNumber(select(11, C_Item.GetItemInfo(info.hyperlink)))
	if not sellPrice or sellPrice <= 0 then return nil end
	local unit = stackValue / (info.stackCount or 1)
	return (unit - sellPrice) / sellPrice * 100
end

local function PercentText(percent)
	if not percent then return S.DIM .. "AH only|r" end
	if percent < 0 then return S.BAD .. ("%d%%"):format(math.ceil(percent - 0.5)) .. "|r" end
	for _, tier in ipairs(TIERS) do
		if percent >= tier.min then
			return tier.color .. ("+%d%%"):format(math.floor(percent + 0.5)) .. "|r"
		end
	end
end

local IGNORE_HINT = "Ctrl+Alt+right-click"

local function ItemID(link)
	return ns.PublicNumber((C_Item.GetItemInfoInstant(link)))
end

-- Bank Alt's ignore list, also read when that module is off (its saved table
-- is there either way).
local function IgnoredTable()
	local bankAlt = ns.byKey.bankalt
	local db = bankAlt and bankAlt.db
	if not db then return nil end
	if type(db.ignored) ~= "table" then db.ignored = {} end
	return db.ignored
end

local function IsIgnored(link)
	local ignored, id = IgnoredTable(), ItemID(link)
	return ignored ~= nil and id ~= nil and ignored[id] == true
end

local function IsIgnoreClick(mouseButton)
	return mouseButton == "RightButton" and IsControlKeyDown() and IsAltKeyDown() and not IsShiftKeyDown()
end

-- Stack value and % over vendor, or nil when the item isn't listed.
local function Candidate(info, bag, slot)
	local bankAlt = ns.byKey.bankalt
	local value, percent
	if bankAlt and bankAlt.enabled and bankAlt.SendCandidate then
		value, percent = bankAlt.SendCandidate(info.hyperlink, info.isBound, info.stackCount, info.hasNoValue, bag, slot)
		if not value then return nil end
		return value, percent or VendorPercent(info, value)
	end
	if info.isBound or IsIgnored(info.hyperlink) then return nil end
	local price = ns.AuctionPrice(info.hyperlink)
	if not price or price <= 0 then return nil end
	value = price * (info.stackCount or 1)
	return value, VendorPercent(info, value)
end

local function Scan()
	wipe(items)
	if not ns.HasAuctionator() then return end
	for bag = 0, NUM_BAG_SLOTS or 4 do
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info and info.hyperlink and not info.isLocked then
				local value, percent = Candidate(info, bag, slot)
				if value then
					items[#items + 1] = {
						bag = bag, slot = slot, link = info.hyperlink, icon = info.iconFileID,
						count = info.stackCount or 1, value = value, percent = percent,
					}
				end
			end
		end
	end
	local byPercent = L.Setting("listSort") == "percent"
	table.sort(items, function(a, b)
		if byPercent and a.percent ~= b.percent then
			if not a.percent then return true end
			if not b.percent then return false end
			return a.percent > b.percent
		end
		if a.value ~= b.value then return a.value > b.value end
		if a.bag ~= b.bag then return a.bag < b.bag end
		return a.slot < b.slot
	end)
end

---------------------------------------------------------------------------
-- Attaching
---------------------------------------------------------------------------

local function SendFrameReady()
	return MailFrame and MailFrame:IsShown() and SendMailFrame and ClickSendMailItemButton and HasSendMailItem
end

local function FreeAttachmentSlots()
	local free = 0
	for i = 1, MAX_SEND do
		if not HasSendMailItem(i) then free = free + 1 end
	end
	return free
end

local function OpenSendTab()
	if not SendMailFrame:IsShown() and MailFrameTab_OnClick then
		MailFrameTab_OnClick(nil, 2)
	end
	return SendMailFrame:IsShown()
end

local function Attach(item)
	local info = C_Container.GetContainerItemInfo(item.bag, item.slot)
	-- The bags changed since the list was drawn: don't attach the wrong item.
	if not info or info.hyperlink ~= item.link or info.isLocked then return false end
	ClearCursor()
	C_Container.PickupContainerItem(item.bag, item.slot)
	ClickSendMailItemButton()
	if GetCursorInfo() then
		ClearCursor()
		return false
	end
	return true
end

local function AttachItem(item)
	if not SendFrameReady() then return end
	if not OpenSendTab() then return end
	if FreeAttachmentSlots() == 0 then
		L.Print("the mail is full (" .. MAX_SEND .. " attachments).")
		return
	end
	Attach(item)
end

local function AttachTop()
	if not SendFrameReady() or not OpenSendTab() then return end
	local free = FreeAttachmentSlots()
	if free == 0 then
		L.Print("the mail is full (" .. MAX_SEND .. " attachments).")
		return
	end
	local attached = 0
	for _, item in ipairs(items) do
		if attached >= free then break end
		if Attach(item) then attached = attached + 1 end
	end
end

---------------------------------------------------------------------------
-- Drawing
---------------------------------------------------------------------------

local function MaxOffset()
	return math.max(0, #items - ROWS)
end

local function Draw()
	if not panel then return end
	offset = math.min(offset, MaxOffset())
	for i, row in ipairs(rows) do
		local item = items[offset + i]
		row.item = item
		if item then
			row.icon:SetTexture(item.icon)
			row.name:SetText(item.link .. (item.count > 1 and (S.DIM .. " x" .. item.count .. "|r") or ""))
			row.value:SetText(L.Money(item.value))
			row.percent:SetText(PercentText(item.percent))
			row:Show()
		else
			row:Hide()
		end
	end
	scrollBar:SetMinMaxValues(0, MaxOffset())
	scrollBar:SetValue(offset)
	scrollBar:SetShown(MaxOffset() > 0)

	local total = 0
	for _, item in ipairs(items) do total = total + item.value end
	if not ns.HasAuctionator() then
		emptyText:SetText("Needs Auctionator for AH prices.")
	else
		emptyText:SetText("Nothing worth sending.")
	end
	emptyText:SetShown(#items == 0)
	summary:SetText(#items == 0 and "" or (L.Plural(#items, "item") .. ", " .. L.Money(total)))

	local free = SendFrameReady() and FreeAttachmentSlots() or MAX_SEND
	attachButton:SetText("Attach top " .. math.max(1, math.min(free, #items)))
	attachButton:SetEnabled(#items > 0 and free > 0)

	local target = L.SendTarget and L.SendTarget()
	panel.title:SetText(target and ("Send to " .. target) or "Worth sending")
end

function L.RefreshSendList()
	if not panel or not panel:IsShown() then return end
	Scan()
	Draw()
end

local function QueueRefresh()
	if refreshQueued or not panel or not panel:IsShown() then return end
	refreshQueued = true
	C_Timer.After(0.1, function()
		refreshQueued = false
		L.RefreshSendList()
	end)
end

-- Uses Bank Alt's own toggle when it's on, so its bag marks update too.
local function ToggleIgnore(link)
	local bankAlt = ns.byKey.bankalt
	if bankAlt and bankAlt.enabled and bankAlt.ToggleIgnore then
		bankAlt.ToggleIgnore(link)   -- its listeners refresh this list
		return
	end
	local ignored, id = IgnoredTable(), ItemID(link)
	if not (ignored and id) then return end
	if ignored[id] then
		ignored[id] = nil
		L.Print(link .. " will be suggested again.")
	else
		ignored[id] = true
		L.Print("won't suggest " .. link .. " any more. " .. IGNORE_HINT .. " it in this list again to undo.")
	end
	L.RefreshSendList()
end

local function ShowRowTooltip(row)
	local item = row.item
	if not item then return end
	GameTooltip:SetOwner(row, "ANCHOR_LEFT")
	GameTooltip:SetBagItem(item.bag, item.slot)
	GameTooltip:AddLine("Click to attach to the mail.", 0.5, 0.5, 0.5)
	GameTooltip:AddLine(IGNORE_HINT .. " to never suggest it.", 0.5, 0.5, 0.5)
	GameTooltip:Show()
end

local function BuildRow(index)
	local row = CreateFrame("Button", nil, panel)
	row:SetHeight(ROW_H)
	row:SetPoint("TOPLEFT", PAD, LIST_TOP - (index - 1) * ROW_H)
	row:SetPoint("TOPRIGHT", -PAD - 12, LIST_TOP - (index - 1) * ROW_H)
	S.RowHighlight(row)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(ICON, ICON)
	row.icon:SetPoint("LEFT", 2, 0)
	row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

	row.value = S.Text(row, 11)
	row.value:SetPoint("RIGHT", -2, 0)
	row.value:SetJustifyH("RIGHT")

	-- Fixed column, left of the value, so the percentages line up.
	row.percent = S.Text(row, 11)
	row.percent:SetWidth(PERCENT_W)
	row.percent:SetPoint("RIGHT", row, "RIGHT", -98, 0)
	row.percent:SetJustifyH("RIGHT")

	row.name = S.Text(row, 11)
	row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
	row.name:SetPoint("RIGHT", row.percent, "LEFT", -6, 0)
	row.name:SetJustifyH("LEFT")

	row:SetScript("OnClick", function(self, mouseButton)
		if not self.item then return end
		if IsIgnoreClick(mouseButton) then
			ToggleIgnore(self.item.link)
		elseif mouseButton == "LeftButton" then
			AttachItem(self.item)
		end
	end)
	row:SetScript("OnEnter", ShowRowTooltip)
	row:SetScript("OnLeave", function() GameTooltip:Hide() end)
	return row
end

local function ApplyPosition()
	panel:ClearAllPoints()
	local saved = L.db.settings.listPosition
	if saved then
		panel:SetPoint(saved.point, UIParent, saved.relativePoint, saved.x, saved.y)
	elseif MailFrame and MailFrame:IsShown() then
		panel:SetPoint("TOPRIGHT", MailFrame, "TOPLEFT", -6, 0)
	else
		panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	end
end

local function Build()
	if panel then return end
	panel = S.Window({
		name = "PredUIMailSendList", title = "Worth sending", width = WIDTH,
		onMoved = function(self)
			local point, _, relativePoint, x, y = self:GetPoint()
			L.db.settings.listPosition = { point = point, relativePoint = relativePoint, x = x, y = y }
		end,
	})

	for i = 1, ROWS do rows[i] = BuildRow(i) end

	scrollBar = S.ScrollBar(panel, function(value)
		if value ~= offset then
			offset = value
			Draw()
		end
	end)
	scrollBar:SetPoint("TOPRIGHT", -PAD, LIST_TOP)
	scrollBar:SetHeight(ROWS * ROW_H)
	panel:EnableMouseWheel(true)
	panel:SetScript("OnMouseWheel", function(_, delta)
		scrollBar:SetValue(math.max(0, math.min(MaxOffset(), offset - delta * 3)))
	end)

	emptyText = S.Text(panel, 11)
	emptyText:SetPoint("TOP", 0, LIST_TOP - 20)
	emptyText:SetTextColor(0.6, 0.6, 0.6)

	local footerY = LIST_TOP - ROWS * ROW_H - 6
	S.Divider(panel, footerY)

	summary = S.Text(panel, 11)
	summary:SetPoint("TOPLEFT", PAD, footerY - 10)

	attachButton = S.Button(panel, "Attach top " .. MAX_SEND, 110, 22)
	attachButton:SetPoint("TOPRIGHT", -PAD, footerY - 5)
	attachButton.tooltip = "Attach the most valuable items to the mail, filling its free slots."
	attachButton:SetScript("OnClick", AttachTop)

	local hint = S.Text(panel, 10)
	hint:SetPoint("TOPLEFT", PAD, footerY - 34)
	hint:SetTextColor(0.5, 0.5, 0.5)
	hint:SetText("Click to attach. " .. IGNORE_HINT .. " to never suggest.")

	panel:SetHeight(-(footerY - 34) + 14 + PAD)
	panel:SetScript("OnShow", function()
		offset = 0
		Scan()
		Draw()
	end)

	local events = CreateFrame("Frame", nil, panel)
	events:RegisterEvent("BAG_UPDATE_DELAYED")
	events:RegisterEvent("MAIL_SEND_INFO_UPDATE")
	events:RegisterEvent("GET_ITEM_INFO_RECEIVED")
	events:RegisterEvent("MAIL_SEND_SUCCESS")
	events:SetScript("OnEvent", QueueRefresh)

	-- Ignoring an item in your bags (Bank Alt) updates the list too.
	local bankAlt = ns.byKey.bankalt
	if bankAlt and bankAlt.ignoreListeners then
		table.insert(bankAlt.ignoreListeners, QueueRefresh)
	end
end

---------------------------------------------------------------------------
-- Showing
---------------------------------------------------------------------------

function L.ToggleSendList()
	Build()
	if panel:IsShown() then
		panel:Hide()
	else
		ApplyPosition()
		panel:Show()
	end
end

L.launcher = L.launcher or {}
L.launcher[#L.launcher + 1] = {
	icon = "Interface\\Icons\\INV_Crate_04", label = "Worth sending", hint = "Items in your bags worth mailing to another character.",
	func = L.ToggleSendList,
}

function L.ResetSendListPosition()
	L.db.settings.listPosition = nil
	if panel and panel:IsShown() then ApplyPosition() end
end

-- From MAIL_SHOW.
function L.OnMailShowList()
	if not L.Setting("sendList") or L.IsSendTargetSelf() then return end
	Build()
	ApplyPosition()
	panel:Show()
end

-- From MAIL_CLOSED.
function L.OnMailClosedList()
	if panel then panel:Hide() end
end
