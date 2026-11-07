--------------------------------------------------------------------------------
-- Mail Ledger: tracks what you collect from the mailbox. Built for bank alts.
--
-- This file: mail classification, accounting, saved data and events.
-- MailLedgerUI.lua: the panel beside the mailbox, and its PredUI minimap button lines.
-- MailSubject.lua: fills in the subject of money-only mail.
-- MailSend.lua: opens on Send Mail, addressed to your default alt.
-- MailSendList.lua: the "Worth sending" list left of the mailbox.
--
-- Accounting rule: gold only counts once the character's money has really
-- changed by the amount of a mail that was taken. Taking a mail just queues an
-- expectation; PLAYER_MONEY confirms it. Failed or repeated takes therefore
-- never inflate the totals, and unrelated money changes are never counted.
--------------------------------------------------------------------------------

local _, ns = ...

local L = ns.NewModule("mail", {
	title = "Mail Ledger",
	notes = "Shows how much gold you looted from the mailbox, where it came from, and what is still waiting.",
})

local ITEM_COMMIT_DELAY = 2.5  -- seconds to wait for a failure before counting items
local PENDING_TIMEOUT = 30     -- seconds before an unconfirmed money take is dropped
local LOG_LIMIT = 500          -- log rows kept per character
local MAX_ATTACHMENTS = ATTACHMENTS_MAX_RECEIVE or 16
local SECONDS_PER_DAY = 86400

L.INCOME_CATEGORIES = { "sale", "refund", "player", "cod", "other" }

L.DEFAULT_SETTINGS = {
	autoShow = true,     -- open the panel with the mailbox
	chatSummary = true,  -- print a summary when leaving the mailbox
	warnDays = 5,        -- warn at login about mail expiring within this many days
	autoSubject = true,  -- fill the subject of money-only mail
	openSend = false,    -- open the mailbox on the Send Mail tab
	sendList = true,     -- show the "Worth sending" list with the mailbox
	closeWithMail = true, -- hide the ledger and the list when the mailbox closes
	listSort = "value",  -- sort that list by "value" (stack gold) or "percent" (over vendor)
	-- sendTo = { [realm] = "Alt" }: the default recipient, set per realm
}

local pendingMoney, pendingCod, pendingItems, pendingSend = {}, {}, {}, nil
local lastMoney

---------------------------------------------------------------------------
-- Formatting
---------------------------------------------------------------------------

L.Print = L.Say

-- "1,234g 56s 7c", leaving out empty denominations.
function L.Money(copper)
	copper = math.floor(copper or 0)
	local sign = ""
	if copper < 0 then
		sign, copper = "-", -copper
	end
	local gold = math.floor(copper / 10000)
	local silver = math.floor(copper / 100) % 100
	local bronze = copper % 100
	local parts = {}
	if gold > 0 then
		local text = BreakUpLargeNumbers and BreakUpLargeNumbers(gold) or tostring(gold)
		parts[#parts + 1] = text .. "|cffffd100g|r"
	end
	if silver > 0 then parts[#parts + 1] = silver .. "|cffc7c7cfs|r" end
	if bronze > 0 or #parts == 0 then parts[#parts + 1] = bronze .. "|cffeda55fc|r" end
	return sign .. table.concat(parts, " ")
end

function L.Plural(count, noun)
	return count .. " " .. noun .. (count == 1 and "" or "s")
end

function L.Duration(seconds)
	if seconds <= 0 then return "expired?" end
	local days = math.floor(seconds / SECONDS_PER_DAY)
	local hours = math.floor(seconds / 3600) % 24
	if days > 0 then return days .. "d " .. hours .. "h" end
	local minutes = math.floor(seconds / 60) % 60
	if hours > 0 then return hours .. "h " .. minutes .. "m" end
	return math.max(minutes, 1) .. "m"
end

---------------------------------------------------------------------------
-- Saved data
---------------------------------------------------------------------------

local function NewBucket()
	return {
		sale = 0, refund = 0, player = 0, cod = 0, other = 0, -- gold received
		fee = 0,      -- auction house cut already deducted from sales
		codPaid = 0,  -- COD paid to other players
		sent = 0,     -- gold attached to outgoing mail
		postage = 0,
		mails = 0, items = 0, stacks = 0, won = 0, unsold = 0,
	}
end

function L.Income(bucket)
	local total = 0
	for _, category in ipairs(L.INCOME_CATEGORIES) do
		total = total + (bucket[category] or 0)
	end
	return total
end

function L.Setting(key)
	local settings = type(L.db.settings) == "table" and L.db.settings or {}
	local value = settings[key]
	if value == nil then return L.DEFAULT_SETTINGS[key] end
	return value
end

local function Today()
	return date("%Y-%m-%d")
end

local function InitDB()
	L.db.version = 1
	L.db.settings = type(L.db.settings) == "table" and L.db.settings or {}
	L.db.chars = type(L.db.chars) == "table" and L.db.chars or {}
end

local function InitCharacter()
	local name, realm = UnitName("player"), GetRealmName()
	local key = name .. "-" .. realm
	local char = L.db.chars[key] or {}
	L.db.chars[key] = char
	char.name, char.realm = name, realm
	-- Forever gives the player's surname as UnitName's second value.
	char.surname = ns.PublicString(select(2, UnitName("player"))) or char.surname
	char.class = select(2, UnitClass("player"))
	char.days = char.days or {}
	char.log = char.log or {}
	char.gold = GetMoney()
	L.char = char
end

-- Sums this character's daily buckets from `daysBack` days ago up to today
-- (nil = all time).
function L.History(daysBack)
	local total = NewBucket()
	local first = daysBack and date("%Y-%m-%d", time() - daysBack * SECONDS_PER_DAY)
	for day, bucket in pairs(L.char.days) do
		if not first or day >= first then
			for field, value in pairs(bucket) do
				total[field] = (total[field] or 0) + value
			end
		end
	end
	return total
end

-- "First Last" on Forever, where characters have surnames. A character only
-- has its surname saved once it has logged in with this version.
L.SURNAME_SEPARATOR = Constants and Constants.CharacterNameSeparatorConsts
	and Constants.CharacterNameSeparatorConsts.CHARACTERNAME_SURNAME_SEPARATOR or " "

function L.FullName(char)
	if char.surname and char.surname ~= "" then
		return char.name .. L.SURNAME_SEPARATOR .. char.surname
	end
	return char.name
end

-- Characters on the current realm, richest first.
function L.RealmCharacters()
	local list, realm = {}, GetRealmName()
	for _, char in pairs(L.db.chars) do
		if char.realm == realm then list[#list + 1] = char end
	end
	table.sort(list, function(a, b) return (a.gold or 0) > (b.gold or 0) end)
	return list
end

---------------------------------------------------------------------------
-- Recording
---------------------------------------------------------------------------

local function StartVisit()
	L.visit = NewBucket()
	L.visitStartMoney = GetMoney()
	L.visitStartTime = time()
end

local function Add(field, amount)
	if not L.visit then StartVisit() end
	L.visit[field] = (L.visit[field] or 0) + amount
	local today = Today()
	local bucket = L.char.days[today]
	if not bucket then
		bucket = NewBucket()
		L.char.days[today] = bucket
	end
	bucket[field] = (bucket[field] or 0) + amount
end

local function Log(entry)
	entry.t = time()
	local log = L.char.log
	log[#log + 1] = entry
	if #log > LOG_LIMIT then table.remove(log, 1) end
	if L.OnLogEntry then L.OnLogEntry(entry) end
end

local function CommitMoney(entry)
	Add(entry.category, entry.amount)
	if entry.fee and entry.fee > 0 then Add("fee", entry.fee) end
	if entry.final then Add("mails", 1) end
	Log({ c = entry.category, m = entry.amount, s = entry.who, i = entry.item, n = entry.count })
	L.RequestRefresh()
end

local function CommitCod(entry)
	Add("codPaid", entry.amount)
	Log({ c = "codPaid", m = entry.amount, s = entry.who, i = entry.item })
	L.RequestRefresh()
end

local function CommitItems(entry)
	if entry.committed then return end
	entry.committed = true
	for i, pending in ipairs(pendingItems) do
		if pending == entry then
			table.remove(pendingItems, i)
			break
		end
	end
	if #entry.items == 0 then return end
	for _, item in ipairs(entry.items) do
		Add("items", item.count)
		Add("stacks", 1)
		if entry.kind == "won" then Add("won", item.count) end
		if entry.kind == "unsold" then Add("unsold", item.count) end
		Log({ c = "item", s = entry.who, i = item.link or item.name, n = item.count, k = entry.kind })
	end
	if entry.final then Add("mails", 1) end
	L.RequestRefresh()
end

---------------------------------------------------------------------------
-- Reading mail
---------------------------------------------------------------------------

-- Turns a Blizzard format string ("Auction successful: %s") into a pattern
-- that captures the %s part.
local function SubjectPattern(format)
	if not format then return nil end
	local escaped = format:gsub("([%(%)%.%+%-%*%?%[%]%^%$%%])", "%%%1")
	escaped = escaped:gsub("%%%%s", "(.+)")
	return "^" .. escaped .. "$"
end

local SOLD = SubjectPattern(AUCTION_SOLD_MAIL_SUBJECT)
local OUTBID = SubjectPattern(AUCTION_OUTBID_MAIL_SUBJECT)
local WON = SubjectPattern(AUCTION_WON_MAIL_SUBJECT)
local EXPIRED = SubjectPattern(AUCTION_EXPIRED_MAIL_SUBJECT)
local REMOVED = SubjectPattern(AUCTION_REMOVED_MAIL_SUBJECT)
local COD_PAYMENT_SUBJECT = SubjectPattern(COD_PAYMENT or "COD Payment: %s")

local function Matches(subject, pattern)
	if not subject or not pattern then return nil end
	return subject:match(pattern)
end

-- Everything needed to account for one mail. Read at take time, because the
-- mail's contents disappear from the inbox once the server has processed it.
local function ReadMail(index)
	local _, _, sender, subject, money, cod, daysLeft, itemCount, _, _, _, canReply, isGM =
		GetInboxHeaderInfo(index)
	if money == nil then return nil end

	local invoiceType, invoiceItem, invoicePlayer, bid, _, deposit, consignment, _, _, _, invoiceCount =
		GetInboxInvoiceInfo(index)

	local mail = {
		index = index,
		sender = sender,
		subject = subject,
		money = money or 0,
		cod = cod or 0,
		daysLeft = daysLeft,
		itemCount = itemCount or 0,
		who = sender,
		category = "other",
	}

	local soldName = Matches(subject, SOLD)
	local codName = Matches(subject, COD_PAYMENT_SUBJECT)

	if invoiceType == "seller" or soldName then
		mail.category = "sale"
		mail.item = invoiceItem or soldName
		mail.count = invoiceCount
		mail.who = invoicePlayer or sender
		mail.fee = consignment or 0
	elseif invoiceType == "seller_temp_invoice" then
		mail.category = "sale"
		mail.item = invoiceItem
		mail.count = invoiceCount
		mail.ahPending = (bid or 0) + (deposit or 0) - (consignment or 0)
	elseif codName then
		mail.category = "cod"
		mail.item = codName
	elseif Matches(subject, OUTBID) then
		mail.category = "refund"
		mail.item = Matches(subject, OUTBID)
	elseif invoiceType == "buyer" or Matches(subject, WON) then
		-- Money on a purchase mail is change coming back to you.
		mail.category = "refund"
		mail.kind = "won"
		mail.item = invoiceItem or Matches(subject, WON)
		mail.who = invoicePlayer or sender
	elseif Matches(subject, EXPIRED) or Matches(subject, REMOVED) then
		mail.category = "refund"
		mail.kind = "unsold"
	elseif canReply and not isGM then
		mail.category = "player"
	end
	return mail
end

---------------------------------------------------------------------------
-- Tracking takes
---------------------------------------------------------------------------

local function PurgeStale(queue)
	local cutoff = GetTime() - PENDING_TIMEOUT
	for i = #queue, 1, -1 do
		if queue[i].at < cutoff then table.remove(queue, i) end
	end
end

local function QueueMoney(mail, final)
	if mail.money <= 0 then return end
	PurgeStale(pendingMoney)
	for _, entry in ipairs(pendingMoney) do
		if entry.index == mail.index and entry.amount == mail.money and entry.subject == mail.subject then
			return -- the same take was requested again before the server answered
		end
	end
	pendingMoney[#pendingMoney + 1] = {
		at = GetTime(),
		index = mail.index,
		subject = mail.subject,
		amount = mail.money,
		category = mail.category,
		fee = mail.fee,
		who = mail.who,
		item = mail.item,
		count = mail.count,
		final = final,
	}
end

local function QueueCod(mail)
	if mail.cod <= 0 then return end
	PurgeStale(pendingCod)
	for _, entry in ipairs(pendingCod) do
		if entry.index == mail.index and entry.amount == mail.cod and entry.subject == mail.subject then
			return
		end
	end
	pendingCod[#pendingCod + 1] = {
		at = GetTime(),
		index = mail.index,
		subject = mail.subject,
		amount = mail.cod,
		who = mail.sender,
		item = mail.subject,
	}
end

local function ItemCount(itemID)
	return C_Item.GetItemCount(itemID) or 0
end

local function QueueItems(mail, firstAttachment, lastAttachment, final)
	local items = {}
	for attachment = firstAttachment, lastAttachment do
		local name, itemID, _, count = GetInboxItem(mail.index, attachment)
		if name then
			local link = GetInboxItemLink(mail.index, attachment)
			local key = mail.index .. ":" .. attachment .. ":" .. (link or name)
			local duplicate = false
			for _, entry in ipairs(pendingItems) do
				for _, item in ipairs(entry.items) do
					if item.key == key then duplicate = true end
				end
			end
			if not duplicate then
				items[#items + 1] = {
					key = key,
					name = name,
					link = link,
					id = itemID,
					count = count or 1,
					before = itemID and ItemCount(itemID) or 0,
				}
			end
		end
	end
	if #items == 0 then return end

	local entry = { items = items, kind = mail.kind, who = mail.who, final = final }
	pendingItems[#pendingItems + 1] = entry
	C_Timer.After(ITEM_COMMIT_DELAY, function() CommitItems(entry) end)
end

local function OnTakeMoney(index)
	local mail = L.char and ReadMail(index)
	if not mail then return end
	QueueMoney(mail, mail.itemCount == 0)
end

local function OnTakeItem(index, attachment)
	local mail = L.char and ReadMail(index)
	if not mail then return end
	QueueCod(mail)
	QueueItems(mail, attachment, attachment, mail.itemCount <= 1 and mail.money == 0)
end

-- Takes both the gold and every attachment.
local function OnAutoLoot(index)
	local mail = L.char and ReadMail(index)
	if not mail then return end
	QueueCod(mail)
	QueueMoney(mail, mail.itemCount == 0)
	QueueItems(mail, 1, MAX_ATTACHMENTS, true)
end

local function OnSendMail(recipient)
	if not L.char then return end
	pendingSend = {
		who = recipient,
		money = GetSendMailMoney and GetSendMailMoney() or 0,
		postage = GetSendMailPrice and GetSendMailPrice() or 0,
	}
end

-- Finds the queued entry a money change belongs to and commits it.
local function Settle(queue, delta, commit)
	PurgeStale(queue)
	if #queue == 0 then return end
	for i, entry in ipairs(queue) do
		if entry.amount == delta then
			table.remove(queue, i)
			commit(entry)
			return
		end
	end
	-- Several takes can land in one money update.
	local sum = 0
	for _, entry in ipairs(queue) do sum = sum + entry.amount end
	if sum == delta then
		for _, entry in ipairs(queue) do commit(entry) end
		for i = #queue, 1, -1 do queue[i] = nil end
	end
end

-- A take failed (bags full, for example). Attachments that did not reach the
-- bags are removed before they get counted.
local function OnTakeFailed()
	for _, entry in ipairs(pendingItems) do
		for i = #entry.items, 1, -1 do
			local item = entry.items[i]
			if not item.id or ItemCount(item.id) <= item.before then
				table.remove(entry.items, i)
				entry.final = false
			end
		end
	end
end

---------------------------------------------------------------------------
-- Inbox snapshot
---------------------------------------------------------------------------

local function ScanInbox()
	if not L.char then return end
	local shown, total = GetInboxNumItems()
	local inbox = {
		shown = shown or 0,
		total = total or shown or 0,
		money = 0, ahPending = 0, codDue = 0, attachments = 0, expiring = 0,
		checked = time(),
	}
	local warnAfter = L.Setting("warnDays")
	for index = 1, inbox.shown do
		local mail = ReadMail(index)
		if mail then
			inbox.money = inbox.money + mail.money
			inbox.codDue = inbox.codDue + mail.cod
			inbox.attachments = inbox.attachments + mail.itemCount
			inbox.ahPending = inbox.ahPending + (mail.ahPending or 0)
			if mail.daysLeft then
				local expires = time() + mail.daysLeft * SECONDS_PER_DAY
				if not inbox.soonest or expires < inbox.soonest then inbox.soonest = expires end
				if mail.daysLeft <= warnAfter then inbox.expiring = inbox.expiring + 1 end
			end
		end
	end
	L.char.inbox = inbox
	L.RequestRefresh()
end

local scanQueued = false
local function QueueScan()
	if scanQueued then return end
	scanQueued = true
	C_Timer.After(0.1, function()
		scanQueued = false
		ScanInbox()
	end)
end

---------------------------------------------------------------------------
-- Reports
---------------------------------------------------------------------------

function L.PrintVisitSummary(visit, startMoney)
	local income = L.Income(visit)
	if income == 0 and visit.items == 0 and visit.codPaid == 0 and visit.sent == 0 then return end
	L.Print(string.format("looted %s from %s, plus %s (gold change %s).",
		L.Money(income), L.Plural(visit.mails, "mail"), L.Plural(visit.items, "item"),
		L.Money(GetMoney() - startMoney)))
	local inbox = L.char.inbox
	if inbox and (inbox.total > 0 or inbox.money > 0) then
		if inbox.total > inbox.shown then
			-- WoW only lists part of an overfull inbox, so the gold is a minimum.
			L.Print(string.format("still in the mailbox: %s in the %s listed, %d in total.",
				L.Money(inbox.money), L.Plural(inbox.shown, "mail"), inbox.total))
		else
			L.Print(string.format("still in the mailbox: %s in %s.", L.Money(inbox.money), L.Plural(inbox.total, "mail")))
		end
	end
end

function L.PrintAlts()
	local totalGold, totalWaiting = 0, 0
	L.Print("characters on " .. GetRealmName() .. ":")
	for _, char in ipairs(L.RealmCharacters()) do
		local inbox = char.inbox
		local line = "  " .. char.name .. ": " .. L.Money(char.gold)
		totalGold = totalGold + (char.gold or 0)
		if inbox and inbox.total > 0 then
			totalWaiting = totalWaiting + inbox.money
			line = line .. string.format(" | %s, %s waiting", L.Plural(inbox.total, "mail"), L.Money(inbox.money))
			if inbox.soonest then
				line = line .. ", expires in " .. L.Duration(inbox.soonest - time())
			end
		end
		print(line)
	end
	L.Print("total " .. L.Money(totalGold) .. " plus " .. L.Money(totalWaiting) .. " waiting in mailboxes.")
end

function L.PrintHistory()
	local function Line(label, bucket)
		print(string.format("  %s: %s | sales %s | AH cut %s | %s",
			label, L.Money(L.Income(bucket)), L.Money(bucket.sale), L.Money(bucket.fee), L.Plural(bucket.mails, "mail")))
	end
	L.Print("mail income for " .. L.char.name .. ":")
	Line("Today", L.History(0))
	Line("7 days", L.History(6))
	Line("30 days", L.History(29))
	Line("All time", L.History(nil))
end

local function WarnExpiring()
	local warnDays = L.Setting("warnDays")
	for _, char in ipairs(L.RealmCharacters()) do
		local inbox = char.inbox
		if inbox and inbox.soonest and inbox.total > 0 then
			local remaining = inbox.soonest - time()
			if remaining < warnDays * SECONDS_PER_DAY then
				L.Print(string.format("|cffff8040%s has mail expiring: %s left.|r", char.name, L.Duration(remaining)))
			end
		end
	end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local function HookIfPresent(name, handler)
	if type(_G[name]) == "function" then hooksecurefunc(name, handler) end
end

local handlers = {}

function handlers.PLAYER_LOGIN()
	InitCharacter()
	lastMoney = GetMoney()
	L.BuildUI()
	WarnExpiring()
end

function handlers.MAIL_SHOW()
	StartVisit()
	if CheckInbox then CheckInbox() end
	L.OnMailShow()
	L.BuildSendSubject()
	L.OnMailShowSend()
	L.OnMailShowList()
	L.RequestRefresh()
end

function handlers.MAIL_INBOX_UPDATE()
	QueueScan()
end

function handlers.MAIL_CLOSED()
	if L.Setting("closeWithMail") then
		L.OnMailClosed()
		L.OnMailClosedList()
	end
	if not L.visit or L.visitSummarised == L.visit then return end
	L.visitSummarised = L.visit
	if L.Setting("chatSummary") then
		-- Late confirmations still land in this visit, so wait for them.
		local visit, startMoney = L.visit, L.visitStartMoney
		C_Timer.After(ITEM_COMMIT_DELAY + 0.5, function() L.PrintVisitSummary(visit, startMoney) end)
	end
end

function handlers.PLAYER_MONEY()
	local money = GetMoney()
	local delta = money - (lastMoney or money)
	lastMoney = money
	if L.char then L.char.gold = money end
	if delta > 0 then
		Settle(pendingMoney, delta, CommitMoney)
	elseif delta < 0 then
		Settle(pendingCod, -delta, CommitCod)
	end
	L.RequestRefresh()
end

function handlers.MAIL_SEND_SUCCESS()
	L.OnMailSentRefill()
	if not pendingSend then return end
	local sent = pendingSend
	pendingSend = nil
	Add("sent", sent.money)
	Add("postage", sent.postage)
	if sent.money > 0 then Log({ c = "sent", m = sent.money, s = sent.who }) end
	L.RequestRefresh()
end

function handlers.MAIL_FAILED()
	pendingSend = nil
	OnTakeFailed()
end

function handlers.UI_ERROR_MESSAGE(_, message)
	if message and (message == ERR_INV_FULL or message == ERR_ITEM_MAX_COUNT) then
		OnTakeFailed()
	end
end

function L:Enable()
	InitDB()
	HookIfPresent("TakeInboxMoney", OnTakeMoney)
	HookIfPresent("TakeInboxItem", OnTakeItem)
	HookIfPresent("AutoLootMailItem", OnAutoLoot)
	HookIfPresent("SendMail", OnSendMail)

	local eventFrame = CreateFrame("Frame")
	for event in pairs(handlers) do eventFrame:RegisterEvent(event) end
	eventFrame:SetScript("OnEvent", function(_, event, ...) handlers[event](...) end)
end

---------------------------------------------------------------------------
-- Commands (slash and settings menu)
---------------------------------------------------------------------------

local function ToggleSetting(key, label)
	L.db.settings[key] = not L.Setting(key)
	L.Print(label .. " " .. (L.Setting(key) and "on" or "off") .. ".")
end

local function SetSendTo(name)
	L.SetSendTarget(name)
	local target = L.SendTargetSetting()
	if target then
		L.Print("default recipient on " .. GetRealmName() .. ": " .. target .. ".")
	else
		L.Print("no default recipient on " .. GetRealmName() .. ".")
	end
end

local function OnSlash(input)
	local command = input:lower():match("^%s*(%S*)")
	local rest = input:match("^%s*%S+%s+(.-)%s*$") or ""
	if command == "" then
		L.TogglePanel()
	elseif command == "alts" then
		L.PrintAlts()
	elseif command == "history" then
		L.PrintHistory()
	elseif command == "chat" then
		ToggleSetting("chatSummary", "chat summary")
	elseif command == "auto" then
		ToggleSetting("autoShow", "open with mailbox")
	elseif command == "minimap" then
		ns.ToggleMinimapButton()
	elseif command == "list" then
		L.ToggleSendList()
	elseif command == "sort" then
		L.db.settings.listSort = L.Setting("listSort") == "percent" and "value" or "percent"
		L.Print("worth-sending list sorted by " .. (L.Setting("listSort") == "percent" and "% over vendor" or "gold value") .. ".")
		L.RefreshSendList()
	elseif command == "send" then
		ToggleSetting("openSend", "open on Send Mail")
	elseif command == "sendto" then
		SetSendTo(rest)
	elseif command == "subject" then
		ToggleSetting("autoSubject", "subject autofill")
	elseif command == "resetpos" then
		L.ResetPosition()
		L.ResetSendListPosition()
		L.Print("panels re-attached to the mailbox.")
	elseif command == "options" then
		ns.OpenSettings(L)
	else
		L.Print("/mledger: show or hide the panel")
		print("  /mledger history: income today, 7 days, 30 days, all time")
		print("  /mledger alts: gold and waiting mail on every character on this realm")
		print("  /mledger chat: toggle the summary when you leave the mailbox")
		print("  /mledger auto: toggle opening the panel with the mailbox")
		print("  /mledger list: show or hide the worth-sending list")
		print("  /mledger sort: sort that list by gold value or by % over vendor")
		print("  /mledger send: toggle opening the mailbox on Send Mail")
		print("  /mledger sendto <name>: default recipient on this realm (no name clears it)")
		print("  /mledger minimap: show or hide the PredUI minimap button")
		print("  /mledger subject: toggle filling the subject of money-only mail")
		print("  /mledger resetpos: re-attach the panels after dragging them")
		print("  /mledger options: open the settings")
	end
end

-- Settings live in db.settings (as in the old addon), so they get get/set here.
local function SettingOption(kind, key, label, tooltip, extra)
	local opt = {
		type = kind, key = "mail_" .. key, label = label, tooltip = tooltip,
		default = L.DEFAULT_SETTINGS[key],
		get = function() return L.Setting(key) end,
		set = function(value)
			if type(L.db.settings) ~= "table" then L.db.settings = {} end
			L.db.settings[key] = value
		end,
	}
	for k, v in pairs(extra or {}) do opt[k] = v end
	return opt
end

L.options = {
	SettingOption("checkbox", "autoShow", "Open with the mailbox", "Show the panel whenever you open a mailbox."),
	SettingOption("checkbox", "closeWithMail", "Close with the mailbox", "Close the Mail Ledger panel and the worth-sending list when you close the mailbox. Off: they stay open until you close them."),
	SettingOption("checkbox", "chatSummary", "Chat summary", "Print what you looted when you leave the mailbox."),
	SettingOption("checkbox", "autoSubject", "Fill money-only subjects", "When a mail only carries gold, put the amount in the subject."),
	SettingOption("checkbox", "openSend", "Open on Send Mail", "Open the mailbox on the Send Mail tab instead of the Inbox. Not on the default recipient itself, which is the one collecting."),
	SettingOption("checkbox", "sendList", "Worth-sending list", "Left of the mailbox: items in your bags worth sending to your bank alt, by AH value (Auctionator), most valuable first. Click one to attach it."),
	SettingOption("dropdown", "listSort", "Sort worth-sending by", "Gold value: the whole stack's AH value, so a valuable stack beats a valuable single item. % over vendor: how far the AH price is above the vendor price; items that can't be vendored go first.", {
		values = function() return { { "value", "Gold value" }, { "percent", "% over vendor" } } end,
		onChange = function() L.RefreshSendList() end,
	}),
	SettingOption("dropdown", "sendTo", "Default recipient", "Filled in as the recipient whenever Send Mail is empty, and again after each send. Set per realm; /mledger sendto <name> takes any name.", {
		default = "",
		get = function() return L.SendTargetSetting() or "" end,
		set = function(value) L.SetSendTarget(value) end,
		values = function() return L.SendTargetChoices() end,
	}),
	SettingOption("slider", "warnDays", "Expiry warning (days)", "At login, warn about mail that expires within this many days.", { min = 1, max = 30, step = 1 }),
	{ type = "button", label = "Panel", button = "Show / hide", tooltip = "Show or hide the Mail Ledger panel.", func = function() L.TogglePanel() end },
	{ type = "button", label = "Panel position", button = "Re-attach", tooltip = "Put the panel back beside the mailbox after dragging it.", func = function() L.ResetPosition() end },
	{ type = "button", label = "Reports", button = "Income history", tooltip = "Print income for today, 7 days, 30 days and all time.", func = function() L.PrintHistory() end },
	{ type = "button", label = "", button = "Alts on realm", tooltip = "Print gold and waiting mail for every character on this realm.", func = function() L.PrintAlts() end },
}

SLASH_PREDUIMAIL1, SLASH_PREDUIMAIL2 = "/mailledger", "/mledger"
SlashCmdList.PREDUIMAIL = ns.SlashHandler(L, OnSlash)
