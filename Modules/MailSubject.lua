-- Mail Ledger: fills in the subject when a mail only carries money.
--
-- The subject becomes the amount ("1,234g 50s") and follows it while it is
-- edited. Anything you typed yourself is left alone, and nothing changes while
-- the subject box has focus, so clearing it to write your own still works.

local _, ns = ...
local L = ns.byKey.mail

local UPDATE_INTERVAL = 0.15

local watcher
local lastFilled
local warned = false

-- Mail subjects reject colour codes, so the amount has to be plain text.
local function PlainMoney(copper)
	local text = L.Money(copper)
	text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
	text = text:gsub("|r", "")
	return text
end

local function FirstAttachmentName()
	for slot = 1, ATTACHMENTS_MAX_SEND or 12 do
		if HasSendMailItem(slot) then
			return (GetSendMailItem(slot))
		end
	end
	return nil
end

local function MoneyToSend()
	if not SendMailSendMoneyButton:GetChecked() then return 0 end
	return MoneyInputFrame_GetCopper(SendMailMoney) or 0
end

function L.UpdateSendSubject()
	if not L.Setting("autoSubject") then return end
	local box = SendMailSubjectEditBox
	if box:HasFocus() then return end

	local current = box:GetText() or ""
	local attachment = FirstAttachmentName()
	local copper = MoneyToSend()

	if current == "" then
		lastFilled = nil
		if not attachment and copper > 0 then
			lastFilled = PlainMoney(copper)
			box:SetText(lastFilled)
		end
	elseif current == lastFilled then
		if attachment then
			-- Now an item mail: use the item name, as the game normally would.
			lastFilled = nil
			box:SetText(attachment)
		elseif copper > 0 then
			lastFilled = PlainMoney(copper)
			if lastFilled ~= current then box:SetText(lastFilled) end
		else
			lastFilled = nil
			box:SetText("")
		end
	end
end

-- Runs at each mailbox visit until the send frame is available.
function L.BuildSendSubject()
	if watcher then return end
	if not (SendMailFrame and SendMailSubjectEditBox and SendMailMoney and SendMailSendMoneyButton
		and MoneyInputFrame_GetCopper and HasSendMailItem and GetSendMailItem) then
		if not warned then
			warned = true
			L.Print("subject autofill is unavailable: the send mail frame was not found on this client.")
		end
		return
	end

	-- A child of the send frame: it only runs while that tab is open.
	watcher = CreateFrame("Frame", nil, SendMailFrame)
	local elapsed = 0
	watcher:SetScript("OnUpdate", function(_, delta)
		elapsed = elapsed + delta
		if elapsed < UPDATE_INTERVAL then return end
		elapsed = 0
		L.UpdateSendSubject()
	end)
end
