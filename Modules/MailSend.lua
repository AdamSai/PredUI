-- Mail Ledger: opens the mailbox on the Send Mail tab, addressed to your
-- default alt (one per realm).
--
--   * The game always opens the mailbox on the Inbox tab (MailFrame_Show calls
--     MailFrameTab_OnClick(nil, 1)). Whether that runs before or after
--     MAIL_SHOW isn't fixed, so the switch is armed at MAIL_SHOW and done either
--     right after that Inbox click or one frame later, whichever comes first.
--   * The recipient is filled whenever the Send Mail tab shows with an empty
--     "To" box, and again after each send (the game clears the form then).
--     A name already there, such as a reply, is never replaced.
--   * On the alt itself nothing happens: that's the character collecting mail.
--   * Names are full Forever names ("First Last"), since first names can repeat.
--     An alt's surname is saved when it logs in; until then it's looked up in
--     the game's autocomplete list of your own characters (as the "To" box
--     does). If neither knows it, the first name is used as is.

local _, ns = ...
local L = ns.byKey.mail

local switchPending = false
local hooked = false

local function Ready()
	return MailFrame and SendMailFrame and SendMailNameEditBox and MailFrameTab_OnClick and MailFrameTab2
end

-- "First Last" -> "first", "last" (surname nil when there is none).
local function Split(name)
	local sep = L.SURNAME_SEPARATOR:gsub("%p", "%%%0")
	local first, surname = name:match("^%s*(.-)" .. sep .. "+(.-)%s*$")
	if not first or first == "" or surname == "" then
		return name:match("^%s*(.-)%s*$"):lower(), nil
	end
	return first:lower(), surname:lower()
end

-- Same character? First names can repeat on Forever, so surnames are compared
-- whenever both names have one.
local function SameName(a, b)
	local aFirst, aSurname = Split(a)
	local bFirst, bSurname = Split(b)
	if aFirst ~= bFirst then return false end
	return not (aSurname and bSurname) or aSurname == bSurname
end

-- The full name of one of your own characters on this realm, from the game's
-- name autocomplete (the list the mail "To" box uses), or nil when there's no
-- single match. This finds an alt's surname even if that alt hasn't logged in
-- with PredUI since surnames were added.
local function AccountFullName(first)
	local flags = Enum and Enum.AutoCompleteEntryFlag
	if not (C_AutoComplete and C_AutoComplete.GetAutoCompleteResults and flags and flags.AccountCharacter) then return end
	local results = ns.Try(C_AutoComplete.GetAutoCompleteResults, first, 20, #first, true,
		flags.AccountCharacter, flags.Bnet or 0)
	if type(results) ~= "table" then return end

	local consts = Constants and Constants.CharacterNameSeparatorConsts
	local realmSep = consts and consts.CHARACTERNAME_REALMNAME_SEPARATOR or "-"
	local myRealm = (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName() or ""):gsub("[%s%-]", "")
	local wanted = Split(first)
	local found
	for _, result in ipairs(results) do
		local full = type(result) == "table" and ns.PublicString(result.name)
		if full then
			-- Drop "-Realm" when it's ours; other realms aren't this realm's alts.
			local plain, realm = full:match("^(.-)" .. realmSep:gsub("%p", "%%%0") .. "(.+)$")
			if not plain or realm == myRealm then
				plain = plain or full
				local resultFirst, surname = Split(plain)
				if resultFirst == wanted and surname then
					if found and found ~= plain then return end   -- two alts with that first name
					found = plain
				end
			end
		end
	end
	return found
end

-- Saves a surname learned from autocomplete on the matching character, so the
-- dropdown shows the full name too.
local function LearnSurname(fullName)
	local sep = L.SURNAME_SEPARATOR:gsub("%p", "%%%0")
	local first, surname = fullName:match("^%s*(.-)" .. sep .. "+(.-)%s*$")
	if not first or first == "" or not surname or surname == "" then return end
	for _, char in ipairs(L.RealmCharacters()) do
		if (not char.surname or char.surname == "") and char.name:lower() == first:lower() then
			char.surname = surname
		end
	end
end

-- A first name saved before surnames were known becomes the full name: from
-- the saved character when only one has that name, else from autocomplete.
local function Upgrade(name)
	if select(2, Split(name)) then return name end
	local found
	for _, char in ipairs(L.RealmCharacters()) do
		if SameName(char.name, name) then
			if found then found = nil break end
			found = char
		end
	end
	if found and select(2, Split(L.FullName(found))) then return L.FullName(found) end
	local full = AccountFullName(name)
	if full then
		LearnSurname(full)
		return full
	end
	return name
end

-- The saved alt for this realm, even if it's the current character.
function L.SendTargetSetting()
	local list = L.db.settings.sendTo
	local name = type(list) == "table" and list[GetRealmName()]
	if type(name) ~= "string" or name == "" then return nil end
	local full = Upgrade(name)
	if full ~= name then list[GetRealmName()] = full end
	return full
end

local function IsSelf(name)
	return name and L.char and SameName(name, L.FullName(L.char))
end

-- The alt to fill in, or nil (none set, or we are that alt).
function L.SendTarget()
	local name = L.SendTargetSetting()
	if IsSelf(name) then return nil end
	return name
end

function L.SetSendTarget(name)
	if type(L.db.settings.sendTo) ~= "table" then L.db.settings.sendTo = {} end
	name = name and name:match("^%s*(.-)%s*$")
	L.db.settings.sendTo[GetRealmName()] = (name ~= "" and name) or nil
end

local function FillRecipient()
	local name = L.SendTarget()
	if not name or not Ready() or not SendMailFrame:IsShown() then return end
	local box = SendMailNameEditBox
	if (box:GetText() or "") ~= "" then return end
	box:SetText(name)
	-- The game focuses this box after a send; typing would add to the name.
	box:ClearFocus()
	if SendMailFrame_CanSend then SendMailFrame_CanSend() end
end

local function SwitchToSend()
	if not switchPending then return end
	switchPending = false
	if not (Ready() and MailFrame:IsShown() and MailFrameTab2:IsShown()) then return end
	if PanelTemplates_GetSelectedTab and PanelTemplates_GetSelectedTab(MailFrame) == 2 then return end
	MailFrameTab_OnClick(nil, 2)
end

local function Hook()
	if hooked or not Ready() then return end
	hooked = true
	-- Runs after the game's own Inbox click when the mailbox opens.
	hooksecurefunc("MailFrameTab_OnClick", function(_, tabID)
		if tabID == 1 and switchPending then SwitchToSend() end
	end)
	SendMailFrame:HookScript("OnShow", FillRecipient)
end

-- From MAIL_SHOW.
function L.OnMailShowSend()
	Hook()
	if not (L.Setting("openSend") and Ready()) then return end
	if IsSelf(L.SendTargetSetting()) then return end
	switchPending = true
	C_Timer.After(0, SwitchToSend)
end

-- From MAIL_SEND_SUCCESS: the game's reset runs in the same event, so wait.
function L.OnMailSentRefill()
	C_Timer.After(0, FillRecipient)
end

-- Choices for the settings dropdown: none, then this realm's characters.
function L.SendTargetChoices()
	local choices = { { "", "None" } }
	local current = L.SendTargetSetting()
	local seen = false
	for _, char in ipairs(L.RealmCharacters()) do
		if char ~= L.char then
			local full = L.FullName(char)
			choices[#choices + 1] = { full, full }
			if current and full == current then seen = true end
		end
	end
	if current and not seen then
		choices[#choices + 1] = { current, current }
	end
	return choices
end
