--------------------------------------------------------------------------------
-- AddonCheck scenario for Invite Whispers (Modules/InviteWhispers.lua).
-- node "D:/Games/World of Warcraft/AddonCheck/check.js" PredUI --scenario PredUI/Tools/checks/invite-whispers.lua

local function Whisper(text, author, guid)
	Fire("CHAT_MSG_WHISPER", text, author, "", "", author, "", 0, 0, "", 0, 1, guid or "Player-1-0001", 0, false, false, false, false, {})
end

-- A guild member with a known level.
rawset(G, "IsInGuild", function() return true end)
rawset(G, "GetNumGuildMembers", function() return 1 end)
rawset(G, "GetGuildRosterInfo", function(i)
	if i == 1 then return "Tank Guy", "Member", 3, 32, "Warrior", "Wetlands", "", "", true, 0, "WARRIOR" end
end)
rawset(G, "GetPlayerInfoByGUID", function() return "Mage", "MAGE", "Human", "Human", 2, "Frost", "" end)
local sentWho = {}
rawset(G.C_FriendList, "SendWho", function(filter) sentWho[#sentWho + 1] = filter end)

-- The load test opened the list with /invwhisper; start closed and empty.
local frame = G.PredUIInviteWhispers
G.SlashCmdList.PREDUIINVWHISPER("clear")
if frame then frame:Hide() end

Whisper("hey whats up", "Chatty")
expect(not (frame and frame:IsShown()), "a normal whisper shouldn't open the list")

Whisper("I have an invisibility potion", "Rogue")
expect(not (frame and frame:IsShown()), "'invisibility' isn't an invite request")

-- Surname separator differs ("Tank-Guy" in chat, "Tank Guy" in the guild list).
Whisper("inv pls", "Tank-Guy")
frame = G.PredUIInviteWhispers
expect(frame ~= nil and frame:IsShown(), "an invite whisper should open the list")
if not frame then return end
local row = frame.rows[1]
expect(row and row.level:GetText() and row.level:GetText():find("32"), "guild level should show, got " .. tostring(row and row.level:GetText()))
expect(row and not row.who:IsShown(), "no Who button when the level is known")

-- A stranger: level unknown, Who looks it up from a click.
Whisper("Invite?", "Frost Bolt")
row = frame.rows[1]
expect(row.name:GetText():find("Frost Bolt"), "newest request should be on top, got " .. tostring(row.name:GetText()))
expect(row.level:GetText():find("?", 1, true), "unknown level should show ?, got " .. tostring(row.level:GetText()))
expect(row.who:IsShown(), "unknown level should offer Who")
row.who:GetScript("OnClick")(row.who, "LeftButton")
expect(#sentWho == 1 and sentWho[1]:find("Frost", 1, true), "Who should send an exact /who, got " .. tostring(sentWho[1]))

Fire("CHAT_MSG_SYSTEM", "|Hplayer:Frost-Bolt|h[Frost Bolt]|h: Level 27 Human Mage - Elwynn Forest")
expect(row.level:GetText():find("27"), "the /who answer should fill in the level, got " .. tostring(row.level:GetText()))

-- (The chat tag filter is registered with ChatFrameUtil, a stand-in here: not run.)

-- A /who nobody answers.
Whisper("inv", "Ghost Person")
row = frame.rows[1]
row.who:GetScript("OnClick")(row.who, "LeftButton")
Tick(7)
expect(row.level:GetText():find("not found"), "an unanswered /who should say not found, got " .. tostring(row.level:GetText()))

-- Secret whisper is ignored.
Whisper(Secret(), "Hidden")
expect(frame.rows[1].name:GetText():find("Ghost"), "a secret whisper shouldn't add a row")

G.SlashCmdList.PREDUIINVWHISPER("test")
G.SlashCmdList.PREDUIINVWHISPER("clear")
expect(not frame.rows[1]:IsShown(), "clear should empty the list")
