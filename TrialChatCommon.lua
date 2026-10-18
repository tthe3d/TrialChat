TrialChatCommon = {}

local playerName
local playerRealm
local fullPlayerName
local normalizedPlayerRealm
local playerClass
local linkInputs = {}
local linkInsertHooked = false

function TrialChatCommon.RefreshPlayerIdentity()
    playerName = UnitName("player")
    fullPlayerName, playerRealm = UnitFullName("player")
    normalizedPlayerRealm = GetNormalizedRealmName and GetNormalizedRealmName()
    _, playerClass = UnitClass("player")
    if fullPlayerName and playerRealm and playerRealm ~= "" then
        fullPlayerName = fullPlayerName .. "-" .. playerRealm
    end
end

function TrialChatCommon.GetPlayerName()
    return playerName
end

function TrialChatCommon.GetPlayerFullName()
    return fullPlayerName or playerName
end

function TrialChatCommon.GetPlayerClass()
    return playerClass
end

function TrialChatCommon.GetPlayerRealm()
    return playerRealm
end

function TrialChatCommon.NormalizeName(name)
    return name and strlower(name) or nil
end

function TrialChatCommon.ShortName(name)
    return string.match(name or "", "^([^-]+)") or name
end

function TrialChatCommon.NormalizeCharacterName(name)
    local normalized = TrialChatCommon.NormalizeName(name)
    if not normalized then return nil end

    local shortName, realm = string.match(name, "^([^-]+)%-(.+)$")
    if shortName then
        return TrialChatCommon.NormalizeName(shortName) .. "-"
            .. TrialChatCommon.NormalizeRealm(realm)
    end
    if playerRealm and playerRealm ~= "" then
        return normalized .. "-" .. TrialChatCommon.NormalizeRealm(playerRealm)
    end
    return normalized
end

function TrialChatCommon.NormalizeRealm(realm)
    return TrialChatCommon.NormalizeName((string.gsub(realm or "", "[%s']", "")))
end

---------------------------------------------------------------------------
-- Whispering players who aren't online
--
-- An addon whisper to a player who isn't online makes the game print "No
-- player named X is currently playing." TrialChat whispers in the background
-- all the time (connecting to groups, the group heartbeat, nearby listeners,
-- whisper presence pings), which filled the chat with those lines. So it
-- notes who it whispers, hides the line for them, and tells the rest of the
-- addon they're offline. A whisper you type yourself keeps its line.
---------------------------------------------------------------------------
local OFFLINE_NOTICE_SECONDS = 10
local addonWhisperedAt = {}
local typedWhisperAt = {}
local offlineHandlers = {}
local notFoundPattern

-- The game's (translated) "No player named '%s' is currently playing." as a
-- pattern that captures the name, or false when it can't be made one.
local function getNotFoundPattern()
    if notFoundPattern == nil then
        local template = ERR_CHAT_PLAYER_NOT_FOUND_S
        if type(template) == "string" and string.find(template, "%s", 1, true) then
            local escaped = string.gsub(template, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
            notFoundPattern = "^" .. string.gsub(escaped, "%%%%s", "(.+)", 1) .. "$"
        else
            notFoundPattern = false
        end
    end
    return notFoundPattern
end

-- The player a "not currently playing" line is about, when it is one.
local function getNotFoundName(message)
    if canaccessvalue and not canaccessvalue(message) then return nil end
    if type(message) ~= "string" then return nil end
    local pattern = getNotFoundPattern()
    return pattern and string.match(message, pattern) or nil
end

local function whisperedRecently(times, name)
    local key = TrialChatCommon.NormalizeCharacterName(name)
    local at = key and times[key]
    return at ~= nil and GetTime() - at <= OFFLINE_NOTICE_SECONDS
end

-- Sends an addon message to one player, noting it so the game's "not
-- currently playing" line for them is hidden and the addon hears that
-- they're offline (see OnPlayerOffline).
function TrialChatCommon.SendAddonWhisper(prefix, message, target)
    local key = TrialChatCommon.NormalizeCharacterName(target)
    if key then addonWhisperedAt[key] = GetTime() end
    return C_ChatInfo.SendAddonMessage(prefix, message, "WHISPER", target)
end

-- handler(name) runs when a player TrialChat just whispered turns out not to
-- be online.
function TrialChatCommon.OnPlayerOffline(handler)
    offlineHandlers[#offlineHandlers + 1] = handler
end

local offlineFrame = CreateFrame("Frame")
offlineFrame:RegisterEvent("CHAT_MSG_SYSTEM")
offlineFrame:SetScript("OnEvent", function(_, _, message)
    local name = getNotFoundName(message)
    if not name or not whisperedRecently(addonWhisperedAt, name) then return end
    for _, handler in ipairs(offlineHandlers) do
        handler(name)
    end
end)

-- Hides the line when it's about a TrialChat whisper. When you whispered the
-- player yourself just now too, it stays: it may be about yours.
local function hideAddonWhisperNotice(_, _, message)
    local name = getNotFoundName(message)
    return name ~= nil and whisperedRecently(addonWhisperedAt, name)
        and not whisperedRecently(typedWhisperAt, name)
end

if ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter then
    ChatFrameUtil.AddMessageEventFilter("CHAT_MSG_SYSTEM", hideAddonWhisperNotice)
elseif ChatFrame_AddMessageEventFilter then
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SYSTEM", hideAddonWhisperNotice)
end

if C_ChatInfo and C_ChatInfo.SendChatMessage and hooksecurefunc then
    hooksecurefunc(C_ChatInfo, "SendChatMessage", function(_, chatType, _, target)
        if chatType ~= "WHISPER" or type(target) ~= "string" then return end
        local key = TrialChatCommon.NormalizeCharacterName(target)
        if key then typedWhisperAt[key] = GetTime() end
    end)
end

-- Data that belongs to this character only, not the whole account: whispers
-- and the saved groups they've chosen to join. It lives in
-- TrialChatCharacterDB (see the .toc), which the game keeps per character.
function TrialChatCommon.GetCharacterDB()
    TrialChatCharacterDB = TrialChatCharacterDB or {}
    return TrialChatCharacterDB
end

function TrialChatCommon.IsSelf(sender)
    if not sender or sender == "" then return false end

    local senderKey = TrialChatCommon.NormalizeName(sender)
    if senderKey == TrialChatCommon.NormalizeName(fullPlayerName) then
        return true
    end

    local senderShort, senderRealm = string.match(sender, "^([^-]+)%-(.+)$")
    if not senderShort then
        return senderKey == TrialChatCommon.NormalizeName(playerName)
    end
    if TrialChatCommon.NormalizeName(senderShort)
        ~= TrialChatCommon.NormalizeName(playerName) then
        return false
    end

    local currentRealm = normalizedPlayerRealm or playerRealm
    if not currentRealm or currentRealm == "" then return false end
    return TrialChatCommon.NormalizeRealm(senderRealm)
        == TrialChatCommon.NormalizeRealm(currentRealm)
end

function TrialChatCommon.NamesMatch(left, right)
    if TrialChatCommon.NormalizeName(left) == TrialChatCommon.NormalizeName(right) then
        return true
    end
    if string.find(left or "", "-", 1, true)
        and string.find(right or "", "-", 1, true) then
        return false
    end

    local leftShort = string.match(left or "", "^([^-]+)")
    local rightShort = string.match(right or "", "^([^-]+)")
    return leftShort ~= nil
        and TrialChatCommon.NormalizeName(leftShort)
            == TrialChatCommon.NormalizeName(rightShort)
end

function TrialChatCommon.GetClassColor(classFile)
    local classColor = classFile and RAID_CLASS_COLORS[classFile]
    if not classColor then return nil end
    if classColor.colorStr then
        return "|c" .. classColor.colorStr
    end

    return string.format("|cff%02x%02x%02x",
        math.floor(classColor.r * 255),
        math.floor(classColor.g * 255),
        math.floor(classColor.b * 255))
end

TrialChatCommon.RefreshPlayerIdentity()

-- Classes of other TrialChat users, so names and avatars keep their class
-- color. Classes learned from nameplates are only kept for this session;
-- ones of people you chat with are saved.
local MAX_SAVED_CLASSES = 2000
local knownClasses = {}

local function getSavedClasses()
    TrialChatDB = TrialChatDB or {}
    if type(TrialChatDB.classes) ~= "table" then
        TrialChatDB.classes = {}
        TrialChatDB.classCount = 0
    end
    return TrialChatDB.classes
end

function TrialChatCommon.RememberClass(name, classFile, keep)
    if not name or name == "" or not classFile or not RAID_CLASS_COLORS[classFile] then
        return
    end
    local key = TrialChatCommon.NormalizeCharacterName(name)
    knownClasses[key] = classFile
    if not keep then return end

    local savedClasses = getSavedClasses()
    if savedClasses[key] == nil then
        if (TrialChatDB.classCount or 0) >= MAX_SAVED_CLASSES then return end
        TrialChatDB.classCount = (TrialChatDB.classCount or 0) + 1
    end
    savedClasses[key] = classFile
end

function TrialChatCommon.GetKnownClass(name)
    if not name or name == "" then return nil end
    if TrialChatCommon.IsSelf(name) then return playerClass end

    local key = TrialChatCommon.NormalizeCharacterName(name)
    local savedClasses = TrialChatDB and type(TrialChatDB.classes) == "table"
        and TrialChatDB.classes
    return knownClasses[key] or (savedClasses and savedClasses[key])
end

-- In instances the game hides other players' names and looks from addons.
local function isSecret(...)
    if not issecretvalue then return false end
    for index = 1, select("#", ...) do
        if issecretvalue((select(index, ...))) then return true end
    end
    return false
end
TrialChatCommon.IsSecret = isSecret

function TrialChatCommon.GetUnitFullName(unit)
    local name, realm = UnitFullName(unit)
    if not name or isSecret(name, realm) then return nil end
    if realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

-- Race and gender of other TrialChat users, for a race portrait when the
-- game can't draw theirs. Kept like classes: saved for people you chat with.
local MAX_SAVED_LOOKS = 2000
local knownLooks = {}

function TrialChatCommon.RememberLook(name, raceFile, sex, keep)
    sex = tonumber(sex)
    if not name or name == "" or type(raceFile) ~= "string"
        or not string.match(raceFile, "^%a+$") or (sex ~= 2 and sex ~= 3) then
        return
    end
    local key = TrialChatCommon.NormalizeCharacterName(name)
    local look = raceFile .. ":" .. sex
    knownLooks[key] = look
    if not keep then return end

    TrialChatDB = TrialChatDB or {}
    if type(TrialChatDB.looks) ~= "table" then
        TrialChatDB.looks = {}
        TrialChatDB.lookCount = 0
    end
    if TrialChatDB.looks[key] == nil then
        if (TrialChatDB.lookCount or 0) >= MAX_SAVED_LOOKS then return end
        TrialChatDB.lookCount = (TrialChatDB.lookCount or 0) + 1
    end
    TrialChatDB.looks[key] = look
end

function TrialChatCommon.RememberUnitLook(unit, fullName, keep)
    local _, raceFile = UnitRace(unit)
    local sex = UnitSex(unit)
    if not isSecret(raceFile, sex) then
        TrialChatCommon.RememberLook(fullName, raceFile, sex, keep)
    end
end

-- Returns the race file name (like "NightElf") and sex (2 male, 3 female).
function TrialChatCommon.GetKnownLook(name)
    if not name or name == "" then return nil end
    if TrialChatCommon.IsSelf(name) then
        local _, raceFile = UnitRace("player")
        return raceFile, UnitSex("player")
    end

    local key = TrialChatCommon.NormalizeCharacterName(name)
    local look = knownLooks[key]
        or (TrialChatDB and type(TrialChatDB.looks) == "table" and TrialChatDB.looks[key])
    if type(look) ~= "string" then return nil end
    local raceFile, sex = string.match(look, "^(%a+):([23])$")
    return raceFile, tonumber(sex)
end

-- The game can only draw a player's portrait while it knows them as a unit:
-- you, your party or raid, your target or focus, or a visible nameplate.
local MAX_NAMEPLATES = 40
local UNIT_INDEX_SECONDS = 2
local unitsByName = {}
local unitsIndexedAt

-- Look again as soon as who the game knows changes.
local unitWatcher = CreateFrame("Frame")
for _, event in ipairs({
    "GROUP_ROSTER_UPDATE", "NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED",
    "PLAYER_TARGET_CHANGED", "PLAYER_FOCUS_CHANGED",
}) do
    unitWatcher:RegisterEvent(event)
end
unitWatcher:SetScript("OnEvent", function()
    unitsIndexedAt = nil
end)

local function indexUnit(unit)
    if not UnitExists(unit) or not UnitIsPlayer(unit) then return end
    local name = TrialChatCommon.GetUnitFullName(unit)
    local key = name and TrialChatCommon.NormalizeCharacterName(name)
    if key and not unitsByName[key] then
        unitsByName[key] = unit
    end
end

local function indexUnits()
    unitsByName = {}
    unitsIndexedAt = GetTime()
    for index = 1, 4 do indexUnit("party" .. index) end
    for index = 1, 40 do indexUnit("raid" .. index) end
    indexUnit("target")
    indexUnit("focus")
    for index = 1, MAX_NAMEPLATES do indexUnit("nameplate" .. index) end
end

function TrialChatCommon.FindUnit(name)
    if not name or name == "" then return nil end
    if TrialChatCommon.IsSelf(name) then return "player" end

    local key = TrialChatCommon.NormalizeCharacterName(name)
    local function stillThem(unit)
        local unitName = unit and TrialChatCommon.GetUnitFullName(unit)
        return unitName and TrialChatCommon.NormalizeCharacterName(unitName) == key
    end
    if stillThem(unitsByName[key]) then return unitsByName[key] end
    if not unitsIndexedAt or GetTime() - unitsIndexedAt > UNIT_INDEX_SECONDS then
        indexUnits()
        if stillThem(unitsByName[key]) then return unitsByName[key] end
    end
    return nil
end

-- Shift-clicked links go into the TrialChat box you're typing in. The game
-- only knows its own chat box, which makes two cases need care:
-- - For an item link in chat it offers the link twice in one click (the
--   second time because the first "wasn't taken"), so each click inserts
--   at most one link.
-- - Its own box stays the active one while it holds unsent text, and then
--   it takes the link and the keyboard even while you type in TrialChat; the
--   link is moved back to you, and its box keeps the rest of its text.
local lastLinkInput
local lastLinkInputLostFocusAt
local lastLinkInsertedAt

local function getFocusedLinkInput()
    for input in pairs(linkInputs) do
        if input:IsVisible() and input:HasFocus() then
            return input
        end
    end
end

local function removeLastLink(editBox, link)
    local text = editBox:GetText() or ""
    local first, last
    local from = 1
    while true do
        local linkStart, linkEnd = string.find(text, link, from, true)
        if not linkStart then break end
        first, last = linkStart, linkEnd
        from = linkStart + 1
    end
    if first then
        editBox:SetText(string.sub(text, 1, first - 1) .. string.sub(text, last + 1))
    end
end

local function onInsertLink(link)
    if not link or link == "" then return end
    local now = GetTime()
    if lastLinkInsertedAt == now then return end

    local target = getFocusedLinkInput()
    local gameBox = ChatFrameUtil.GetActiveWindow and ChatFrameUtil.GetActiveWindow()
    local takenFromYou = not target and lastLinkInputLostFocusAt == now
        and lastLinkInput and lastLinkInput:IsVisible()
        and gameBox and gameBox:HasFocus()
    if takenFromYou then
        target = lastLinkInput
        removeLastLink(gameBox, link)
    end
    if not target then return end

    lastLinkInsertedAt = now
    target:Insert(link)
    if takenFromYou then
        target:SetFocus()
    end
end

function TrialChatCommon.RegisterLinkInput(input)
    linkInputs[input] = true

    input:HookScript("OnEditFocusGained", function(self)
        lastLinkInput = self
        if ChatFrameUtil and ChatFrameUtil.SetChatFocusOverride then
            ChatFrameUtil.SetChatFocusOverride(self)
        end
    end)
    local function clearChatFocusOverride(self)
        if ChatFrameUtil
            and ChatFrameUtil.GetChatFocusOverride
            and ChatFrameUtil.GetChatFocusOverride() == self
            and ChatFrameUtil.ClearChatFocusOverride then
            ChatFrameUtil.ClearChatFocusOverride()
        end
    end
    input:HookScript("OnEditFocusLost", function(self)
        lastLinkInput = self
        lastLinkInputLostFocusAt = GetTime()
        clearChatFocusOverride(self)
    end)
    input:HookScript("OnHide", clearChatFocusOverride)

    if linkInsertHooked or not ChatFrameUtil or not ChatFrameUtil.InsertLink then
        return
    end
    hooksecurefunc(ChatFrameUtil, "InsertLink", onInsertLink)
    linkInsertHooked = true
end

function TrialChatCommon.NormalizeMessageMarkup(text)
    text = string.gsub(text, "||([cChHrRtT])", "|%1")
    text = string.gsub(text, "\\124([cChHrRtT])", "|%1")

    local isPastedScript = string.match(text, "^%s*/script%s+")
        or string.find(text, "DEFAULT_CHAT_FRAME:AddMessage(", 1, true)
    if isPastedScript then
        local itemLink = string.match(text,
            "|cnIQ%d+:|Hitem:[^|]+|h[^|]*|h|r")
            or string.match(text,
                "|c%x%x%x%x%x%x%x%x|Hitem:[^|]+|h[^|]*|h|r")
        if itemLink then
            return itemLink
        end
    end

    return text
end

function TrialChatCommon.EncodeMessageMarkup(text)
    text = string.gsub(text, "~", "~~")
    return (string.gsub(text, "|", "~p"))
end

function TrialChatCommon.DecodeMessageMarkup(text)
    return (string.gsub(text, "~.", function(escape)
        if escape == "~~" then
            return "~"
        elseif escape == "~p" then
            return "|"
        end
        return escape
    end))
end

-- A reply carries a little of the message it answers with it, so other
-- TrialChat users can see what is being replied to. It rides at the front
-- of the message's encoded text as "R|" who "|" what "|" and then the
-- message. Encoding never leaves a plain "|" in encoded text, so those
-- separators can never be confused with something the sender typed.
-- Readers on an older TrialChat simply see the quote as plain text.
local REPLY_MARKER = "R|"
local REPLY_QUOTE_LIMIT = 140

-- Quoted replies are trimmed, so a reply stays small on the wire.
function TrialChatCommon.ReplyQuoteText(text)
    text = string.match(text or "", "^%s*(.-)%s*$") or ""
    if #text > REPLY_QUOTE_LIMIT then
        return string.sub(text, 1, REPLY_QUOTE_LIMIT) .. "..."
    end
    return text
end

-- Encodes a reply ({ sender, text }) to go in front of a message.
function TrialChatCommon.EncodeReplyPrefix(reply)
    if not reply or (reply.sender or "") == "" then return "" end
    return REPLY_MARKER
        .. TrialChatCommon.EncodeMessageMarkup(reply.sender or "")
        .. "|" .. TrialChatCommon.EncodeMessageMarkup(
            TrialChatCommon.ReplyQuoteText(reply.text))
        .. "|"
end

-- Takes a reply off the front of encoded message text. Returns the reply
-- (or nil), and the rest of the text, still encoded.
function TrialChatCommon.SplitReplyPrefix(text)
    if string.sub(text, 1, #REPLY_MARKER) ~= REPLY_MARKER then
        return nil, text
    end
    local sender, quoted, rest =
        string.match(text, "^R|([^|]*)|([^|]*)|(.*)$")
    if not sender then return nil, text end
    return {
        sender = TrialChatCommon.DecodeMessageMarkup(sender),
        text = TrialChatCommon.DecodeMessageMarkup(quoted),
    }, rest
end

-- A quoted reply is drawn as a link, so clicking it can jump back to the
-- message it quotes.
TrialChatCommon.REPLY_LINK_NAME = "tcreply"

function TrialChatCommon.ReplyLink(text)
    return "|H" .. TrialChatCommon.REPLY_LINK_NAME .. "|h" .. text .. "|h|r"
end

-- The visible text of a message or quote: player links are reduced to the
-- name they show and the edges are trimmed, for comparing the two.
local function visibleText(text)
    text = TrialChatCommon.RemovePlayerLinks(text or "")
    return (string.match(text, "^%s*(.-)%s*$")) or ""
end

-- Whether a history entry is the message a reply quotes, so clicking the
-- quoted line can jump back to it. Quotes are trimmed and cut short at
-- REPLY_QUOTE_LIMIT characters, so a cut quote only matches at its start.
function TrialChatCommon.ReplyQuotesEntry(reply, entry)
    if type(entry) ~= "table" or entry.isEmote then return false end
    if type(reply) ~= "table" or not reply.sender or not entry.sender then
        return false
    end
    if not TrialChatCommon.NamesMatch(entry.sender, reply.sender) then
        return false
    end
    local quote = visibleText(reply.text)
    if quote == "" then return false end
    local message = visibleText(entry.message)
    if message == quote then return true end
    if string.sub(quote, -3) == "..." then
        local head = string.sub(quote, 1, -4)
        return #head > 0 and string.sub(message, 1, #head) == head
    end
    return false
end

-- Messages longer than one addon message (255 bytes) are sent in numbered
-- parts and put back together by the receiver.
local MAX_MESSAGE_PARTS = 16
local MAX_PENDING_PER_SENDER = 4
local PART_TIMEOUT_SECONDS = 30

function TrialChatCommon.SplitIntoParts(text, partBytes)
    local parts = {}
    for start = 1, #text, partBytes do
        parts[#parts + 1] = string.sub(text, start, start + partBytes - 1)
    end
    return parts
end

function TrialChatCommon.NewPartId()
    return string.format("%06x", math.random(0, 0xffffff))
end

function TrialChatCommon.NewPartCollector()
    local pendingBySender = {}
    local lastSweepAt = 0
    local collector = {}

    local function sweepExpired(now)
        lastSweepAt = now
        for senderKey, pending in pairs(pendingBySender) do
            for id, message in pairs(pending) do
                if now - message.startedAt > PART_TIMEOUT_SECONDS then
                    pending[id] = nil
                end
            end
            if not next(pending) then
                pendingBySender[senderKey] = nil
            end
        end
    end

    -- Returns the whole text once every part has arrived, otherwise nil.
    function collector:Add(senderKey, partId, index, count, chunk)
        if not senderKey or not partId or not index or not count or not chunk
            or count < 2 or count > MAX_MESSAGE_PARTS
            or index < 1 or index > count then
            return nil
        end

        local now = GetTime()
        if now - lastSweepAt > PART_TIMEOUT_SECONDS then
            sweepExpired(now)
        end
        local pending = pendingBySender[senderKey] or {}
        pendingBySender[senderKey] = pending
        local oldestId, oldestTime, pendingCount = nil, nil, 0
        for id, message in pairs(pending) do
            if now - message.startedAt > PART_TIMEOUT_SECONDS then
                pending[id] = nil
            else
                pendingCount = pendingCount + 1
                if not oldestTime or message.startedAt < oldestTime then
                    oldestId, oldestTime = id, message.startedAt
                end
            end
        end

        local message = pending[partId]
        if not message then
            if pendingCount >= MAX_PENDING_PER_SENDER then
                pending[oldestId] = nil
            end
            message = { count = count, chunks = {}, received = 0, startedAt = now }
            pending[partId] = message
        elseif message.count ~= count then
            pending[partId] = nil
            return nil
        end

        if not message.chunks[index] then
            message.chunks[index] = chunk
            message.received = message.received + 1
        end
        if message.received < count then return nil end

        pending[partId] = nil
        if not next(pending) then
            pendingBySender[senderKey] = nil
        end
        return table.concat(message.chunks)
    end

    return collector
end

local function encodeLinkPayload(text)
    return (string.gsub(text, ".", function(char)
        return string.format("%02x", string.byte(char))
    end))
end

local function decodeLinkPayload(text)
    if #text % 2 ~= 0 or string.find(text, "[^%x]") then return nil end

    return (string.gsub(text, "%x%x", function(byte)
        return string.char(tonumber(byte, 16))
    end))
end

local function makeURLLink(url)
    local encodedURL = encodeLinkPayload(url)
    return "|cff00ccff|Htcurl:" .. encodedURL .. "|h" .. url .. "|h|r"
end

local function findHyperlinkEnd(text, position)
    local targetEnd = string.find(text, "|h", position + 2, true)
    if not targetEnd then return nil end

    local displayEnd = targetEnd + 2
    while true do
        local linkEnd = string.find(text, "|h", displayEnd, true)
        if not linkEnd then return nil end
        if string.sub(text, linkEnd - 1, linkEnd - 1) ~= "|" then
            return linkEnd + 1
        end
        displayEnd = linkEnd + 2
    end
end

function TrialChatCommon.FormatMessageText(text)
    local result = {}
    local position = 1

    while position <= #text do
        local namedColorLinkStart, namedColorLinkEnd =
            string.find(text, "^|cn[%a]+%d+:|H[^|]+|h[^|]*|h|r", position)
        if namedColorLinkStart ~= position then
            namedColorLinkStart = nil
        end

        if namedColorLinkStart then
            result[#result + 1] =
                string.sub(text, namedColorLinkStart, namedColorLinkEnd)
            position = namedColorLinkEnd + 1
        elseif string.sub(text, position, position + 1) == "|T" then
            -- An inline texture: the picture an emoticon shortcut stands for.
            -- Only textures from our own emoji folder are let through whole;
            -- any other "|T" a player typed is escaped like before.
            local marker = TrialChatCommon.EmojiDirectory
                and ("|T" .. TrialChatCommon.EmojiDirectory) or nil
            if marker
                and string.sub(text, position, position + #marker - 1) == marker then
                local textureEnd = string.find(text, "|t", position + 2, true)
                if textureEnd then
                    result[#result + 1] = string.sub(text, position, textureEnd + 1)
                    position = textureEnd + 2
                else
                    result[#result + 1] = "||"
                    position = position + 1
                end
            else
                result[#result + 1] = "||"
                position = position + 1
            end
        else
            local colorEnd = string.sub(text, position, position + 1) == "|c"
                and position + 9
                or nil
            if colorEnd and string.match(
                string.sub(text, position + 2, colorEnd),
                "^%x%x%x%x%x%x%x%x$") then
                result[#result + 1] = string.sub(text, position, colorEnd)
                position = colorEnd + 1
            elseif string.sub(text, position, position + 1) == "|r" then
                result[#result + 1] = "|r"
                position = position + 2
            elseif string.sub(text, position, position + 1) == "||" then
                result[#result + 1] = "||"
                position = position + 2
            else
                local url = string.match(text, "^https?://[^%s<>\"|]+", position)
                if url then
                    url = string.gsub(url, "[.,!?;:)]+$", "")
                end
                local linkStart, linkEnd
                if url and #url > 0 then
                    result[#result + 1] = makeURLLink(url)
                    position = position + #url
                else
                    linkEnd = findHyperlinkEnd(text, position)
                    if linkEnd then
                        linkStart = position
                    end
                end
                if not url and linkStart == position then
                    result[#result + 1] = string.sub(text, linkStart, linkEnd)
                    position = linkEnd + 1
                elseif not url then
                    local char = string.sub(text, position, position)
                    result[#result + 1] = char == "|" and "||" or char
                    position = position + 1
                end
            end
        end
    end

    return table.concat(result)
end

-- "/say" refuses a message that holds a "|" which doesn't begin a valid escape
-- sequence, so a raw shortcut like ":-)" or "8-|" can't be echoed as it is.
-- Double every such "|"; the game reads "||" back as a single "|". Real
-- colours, hyperlinks and emoticon textures are passed through untouched.
function TrialChatCommon.EscapeChatPipes(text)
    if not text or not string.find(text, "|", 1, true) then return text end

    local result = {}
    local position = 1
    while position <= #text do
        local char = string.sub(text, position, position)
        if char ~= "|" then
            result[#result + 1] = char
            position = position + 1
        else
            local nextChar = string.sub(text, position + 1, position + 1)
            local color = string.match(
                string.sub(text, position + 2, position + 9),
                "^%x%x%x%x%x%x%x%x$")
            if nextChar == "c" and color then
                result[#result + 1] = string.sub(text, position, position + 9)
                position = position + 10
            elseif nextChar == "H" then
                local linkEnd = findHyperlinkEnd(text, position)
                if linkEnd then
                    result[#result + 1] = string.sub(text, position, linkEnd)
                    position = linkEnd + 1
                else
                    result[#result + 1] = "||"
                    position = position + 1
                end
            elseif nextChar == "T" then
                local textureEnd = string.find(text, "|t", position + 2, true)
                if textureEnd then
                    result[#result + 1] =
                        string.sub(text, position, textureEnd + 1)
                    position = textureEnd + 2
                else
                    result[#result + 1] = "||"
                    position = position + 1
                end
            elseif nextChar == "r" or nextChar == "n" then
                result[#result + 1] = string.sub(text, position, position + 1)
                position = position + 2
            else
                result[#result + 1] = "||"
                position = position + 1
            end
        end
    end

    return table.concat(result)
end

local copyDialog

-- WoW addons can't write to the clipboard, so copying shows the text in a
-- box that is already selected: the player presses Ctrl+C.
local function showCopyDialog(text, title, instructions)
    if not copyDialog then
        copyDialog = CreateFrame("Frame", "TrialChatURLDialog", UIParent, "BackdropTemplate")
        copyDialog:SetSize(460, 130)
        copyDialog:SetPoint("CENTER")
        copyDialog:SetFrameStrata("DIALOG")
        copyDialog:SetFrameLevel(200)
        copyDialog:SetMovable(true)
        copyDialog:EnableMouse(true)
        copyDialog:RegisterForDrag("LeftButton")
        copyDialog:SetScript("OnDragStart", copyDialog.StartMoving)
        copyDialog:SetScript("OnDragStop", copyDialog.StopMovingOrSizing)
        copyDialog:SetBackdrop({
            bgFile = "Interface/Tooltips/UI-Tooltip-Background",
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        copyDialog:SetBackdropColor(0.04, 0.04, 0.04, 0.95)

        copyDialog.title = copyDialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        copyDialog.title:SetPoint("TOP", copyDialog, "TOP", 0, -14)

        copyDialog.instructions =
            copyDialog:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        copyDialog.instructions:SetPoint("TOP", copyDialog.title, "BOTTOM", 0, -8)
        copyDialog.instructions:SetWidth(424)
        copyDialog.instructions:SetJustifyH("CENTER")

        copyDialog.input = CreateFrame("EditBox", nil, copyDialog, "InputBoxTemplate")
        copyDialog.input:SetPoint("TOPLEFT", copyDialog, "TOPLEFT", 18, -62)
        copyDialog.input:SetPoint("RIGHT", copyDialog, "RIGHT", -18, 0)
        copyDialog.input:SetHeight(24)
        copyDialog.input:SetAutoFocus(false)
        copyDialog.input:SetMaxLetters(2048)

        local closeButton = CreateFrame("Button", nil, copyDialog, "UIPanelButtonTemplate")
        closeButton:SetSize(70, 22)
        closeButton:SetPoint("BOTTOM", copyDialog, "BOTTOM", 0, 10)
        closeButton:SetText(CLOSE)
        closeButton:SetScript("OnClick", function()
            copyDialog:Hide()
        end)
        copyDialog:Hide()
    end

    copyDialog.title:SetText(title or "Copy")
    copyDialog.instructions:SetText(instructions
        or "Press Ctrl+C to copy.")
    copyDialog.input:SetText(text)
    copyDialog:Show()
    copyDialog.input:SetFocus()
    copyDialog.input:HighlightText()
end

function TrialChatCommon.ShowCopyDialog(text, title)
    if not text or text == "" then return end
    showCopyDialog(text, title or "Copy text", "Press Ctrl+C to copy.")
end

local function showURLCopyDialog(url)
    showCopyDialog(url, "Copy this URL",
        "WoW does not allow addons to open arbitrary websites. Press Ctrl+C to copy.")
end

function TrialChatCommon.HandleHyperlinkClick(link, text, button)
    local encodedPlayerName = string.match(link or "", "^tcplayer:(%x+)$")
    if encodedPlayerName then
        local playerName = decodeLinkPayload(encodedPlayerName)
        TrialChatCommon.ShowPlayerOptions(playerName, text, button)
        return
    end

    local encodedURL = string.match(link or "", "^tcurl:(%x+)$")
    local url = encodedURL and decodeLinkPayload(encodedURL)
    if url and string.match(url, "^https?://") and not string.find(url, "[%c|]") then
        showURLCopyDialog(url)
        return
    end

    SetItemRef(link, text, button, DEFAULT_CHAT_FRAME)
end

function TrialChatCommon.ShowPlayerOptions(playerName, displayName, button)
    if not playerName or playerName == ""
        or string.find(playerName, "[%c|]") then
        return
    end

    SetItemRef("player:" .. playerName, displayName or playerName,
        button or "LeftButton", DEFAULT_CHAT_FRAME)
end

function TrialChatCommon.RemovePlayerLinks(text)
    text = string.gsub(text, "|Htcplayer:%x+|h(.-)|h", "%1", 1)
    return (string.gsub(text, "|Hplayer:[^|]+|h(.-)|h", "%1", 1))
end

-- Musician song links you post name no player, because the song is yours.
-- In normal chat, Musician's own chat filter adds the sender as the song's
-- owner when the message arrives; TrialChat messages never go through that
-- filter, so without this, clicking the link asks the wrong player (the one
-- clicking) for the song and the import fails.
local SONG_LINK_WITHOUT_OWNER = "|HmusicianSong|h"

local function setSongLinkOwner(text, owner)
    return (string.gsub(text, SONG_LINK_WITHOUT_OWNER, function()
        return "|HmusicianSong:" .. owner .. "|h"
    end))
end

-- For received messages: links without an owner belong to the sender, and
-- with Musician installed, typed [Music: Title] text becomes a link too.
function TrialChatCommon.AddSongLinkOwner(text, sender)
    if not text or not sender or sender == ""
        or TrialChatCommon.IsSelf(sender) then
        return text
    end
    text = setSongLinkOwner(text, sender)
    local songLinks = Musician and Musician.SongLinks
    if songLinks and songLinks.ChatLinksToHyperlinks then
        text = songLinks.ChatLinksToHyperlinks(text, sender)
    end
    return text
end

-- For sent messages: name yourself as the owner, so players on older
-- TrialChat versions that don't add it get working links as well.
function TrialChatCommon.AddOwnSongLinkOwner(text)
    local playerFullName = TrialChatCommon.GetPlayerFullName()
    if not text or not playerFullName then return text end
    return setSongLinkOwner(text, playerFullName)
end

-- Sound emote audio lives in Media/SoundEmotes. TrialChatSoundEmotes.lua maps
-- a sound emote's name to its file there; names missing from the map fall back
-- to "<name>.mp3", so dropping a correctly named file is enough on its own.
local SOUND_EMOTE_DIRECTORY =
    "Interface\\AddOns\\TrialChat\\Media\\SoundEmotes\\"

-- The game's sound API has no volume control, so to make sound emotes louder
-- the same file is played on every channel listed here at once. The mixer sums
-- them, which makes it noticeably louder than a single channel. Add or remove
-- channels to taste ("SFX", "Dialog", "Ambience", "Music"); each extra channel
-- is louder but can also clip an already-loud file.
TrialChatCommon.SoundEmoteChannels = { "Master", "SFX", "Dialog" }

-- Sound emotes never play over each other. On its own the game happily plays
-- addon sounds on top of whatever is already going, so a new sound emote would
-- start while an earlier one is still playing (and the earlier one can even be
-- cut off once the game runs out of sound slots). Instead a sound emote waits
-- for the one playing to finish and then plays; a few can wait in line, and any
-- beyond that are dropped.
--
-- How long a file plays comes from TrialChatCommon.SoundEmoteDurations (in
-- TrialChatSoundEmotes.lua); files without an entry use the default below.
-- The small tail keeps one sound from cutting off the one before it.
TrialChatCommon.SoundEmoteDefaultDuration = 3.0
local SOUND_EMOTE_TAIL = 0.15
local SOUND_EMOTE_MAX_QUEUE = 2

local soundEmoteBusyUntil = 0
local soundEmoteQueue = {}
local soundEmoteQueueTimer

function TrialChatCommon.GetSoundEmoteFile(name)
    local files = TrialChatCommon.SoundEmotes
    local file = files and files[name]
    if file and file ~= "" then
        return file
    end
    return name .. ".mp3"
end

local function getSoundEmoteDuration(name)
    local durations = TrialChatCommon.SoundEmoteDurations
    local duration = durations and durations[TrialChatCommon.GetSoundEmoteFile(name)]
    return duration or TrialChatCommon.SoundEmoteDefaultDuration
end

-- The sounds of the sound emote playing now, so muting can stop it.
local playingSoundHandles = {}

-- Starts a sound emote right now and reserves the sound until it is over.
local function startSoundEmote(name)
    local path = SOUND_EMOTE_DIRECTORY .. TrialChatCommon.GetSoundEmoteFile(name)
    local channels = TrialChatCommon.SoundEmoteChannels or { "Master" }
    local played = false
    playingSoundHandles = {}
    for _, channel in ipairs(channels) do
        local willPlay, handle = PlaySoundFile(path, channel)
        if willPlay then
            played = true
            playingSoundHandles[#playingSoundHandles + 1] = handle
        end
    end
    if played then
        soundEmoteBusyUntil = GetTime() + getSoundEmoteDuration(name) + SOUND_EMOTE_TAIL
    end
    return played
end

local scheduleSoundEmoteQueue
local function drainSoundEmoteQueue()
    soundEmoteQueueTimer = nil
    if soundEmoteBusyUntil > GetTime() then
        scheduleSoundEmoteQueue()
        return
    end
    local name = table.remove(soundEmoteQueue, 1)
    if not name or TrialChatCommon.AreSoundEmotesMuted() then return end
    startSoundEmote(name)
    if soundEmoteQueue[1] then
        scheduleSoundEmoteQueue()
    end
end

scheduleSoundEmoteQueue = function()
    if soundEmoteQueueTimer then return end
    local delay = soundEmoteBusyUntil - GetTime()
    if delay < 0 then delay = 0 end
    soundEmoteQueueTimer = C_Timer.After(delay, drainSoundEmoteQueue)
end

-- Whether this client's game sound is on at all. With sound disabled,
-- PlaySoundFile returns false, which isn't "file not found", so callers use
-- this to avoid a misleading notice.
function TrialChatCommon.IsGameSoundEnabled()
    if not GetCVar then return true end
    if GetCVar("Sound_EnableAllSound") == "0" then return false end
    if GetCVar("Sound_MasterVolume") == "0" then return false end
    return true
end

-- "Mute sound emotes" in Options: no sound emote plays, yours or anyone's.
-- Yours still go out to the players around you, who hear them unless they
-- muted them too.
function TrialChatCommon.AreSoundEmotesMuted()
    return TrialChatDB ~= nil and TrialChatDB.soundEmotesMuted == true
end

function TrialChatCommon.SetSoundEmotesMuted(muted)
    TrialChatDB = TrialChatDB or {}
    TrialChatDB.soundEmotesMuted = muted == true or nil
    if not muted then return end
    -- Muting stops the one playing and drops the ones waiting.
    for _, handle in ipairs(playingSoundHandles) do
        if StopSound then StopSound(handle) end
    end
    playingSoundHandles = {}
    soundEmoteQueue = {}
    soundEmoteBusyUntil = 0
end

-- Whether a sound emote that doesn't play means its file is missing: not
-- when the game's sound is off or sound emotes are muted.
function TrialChatCommon.CanHearSoundEmotes()
    return TrialChatCommon.IsGameSoundEnabled()
        and not TrialChatCommon.AreSoundEmotesMuted()
end

-- Plays a sound emote's audio file, after any sound emote that is already
-- playing. A missing file quietly does not play. Returns whether the sound
-- started now, and whether one was already playing (then this one is waiting
-- its turn, or was dropped if too many are queued).
function TrialChatCommon.PlaySoundEmote(name)
    if not name or name == "" or not PlaySoundFile
        or TrialChatCommon.AreSoundEmotesMuted() then
        return false, false
    end
    if soundEmoteBusyUntil > GetTime() then
        if #soundEmoteQueue < SOUND_EMOTE_MAX_QUEUE then
            soundEmoteQueue[#soundEmoteQueue + 1] = name
            scheduleSoundEmoteQueue()
        end
        return false, true
    end
    return startSoundEmote(name), false
end

-- Plays a sound emote someone else triggered. Only the name travels over
-- the wire, so this plays your own copy of the same file; a name you don't
-- have a file for simply doesn't play. The name comes from another player,
-- so it is checked before it goes near the file system.
--
-- The same trigger can reach you twice (nearby chat and a group both carry
-- it, and one person can be in both), and one person repeating a sound
-- within a second is read as the same trigger arriving again rather than a
-- new one, so nobody hears it twice.
local SOUND_EMOTE_REPEAT_SECONDS = 1
local recentReceivedSoundEmotes = {}
local lastReceivedSoundSweepAt = 0

function TrialChatCommon.PlayReceivedSoundEmote(sender, name)
    if type(name) ~= "string" or not string.match(name, "^[%w_]+$") then
        return false
    end

    local now = GetTime()
    if now - lastReceivedSoundSweepAt > SOUND_EMOTE_REPEAT_SECONDS then
        lastReceivedSoundSweepAt = now
        for key, receivedAt in pairs(recentReceivedSoundEmotes) do
            if now - receivedAt > SOUND_EMOTE_REPEAT_SECONDS then
                recentReceivedSoundEmotes[key] = nil
            end
        end
    end

    local key = (TrialChatCommon.NormalizeCharacterName(sender) or "")
        .. "\0" .. name
    local receivedAt = recentReceivedSoundEmotes[key]
    if receivedAt and now - receivedAt <= SOUND_EMOTE_REPEAT_SECONDS then
        return false
    end
    recentReceivedSoundEmotes[key] = now

    return (TrialChatCommon.PlaySoundEmote(name))
end

-- Handles the "//name [target]" sound emote syntax used instead of "/name".
-- Returns nil when the message is not a sound emote. Otherwise returns true
-- plus, for a sound emote that is also a normal emote, the emote message to
-- send ("/name target"); the second value is nil for a sound-only emote (then
-- only the sound plays). The third value says whether the sound started now;
-- the fourth says whether an earlier sound emote was still playing, so this
-- one is waiting its turn (or was dropped when too many are waiting). The
-- fifth is the sound emote's name, for sending it on to the TrialChat
-- players around you: they play their own copy of the same file, so only the
-- name needs to travel.
function TrialChatCommon.ParseSoundEmote(message)
    local name, argument = string.match(message, "^//%s*([%w_]+)%s*(.-)%s*$")
    if not name then
        -- A bare "//" is not a usable sound emote, but consume it so it is
        -- never sent as a literal chat message.
        if string.sub(message, 1, 2) == "//" then
            return true, nil, false, false
        end
        return nil
    end
    name = string.lower(name)

    local played, waiting = TrialChatCommon.PlaySoundEmote(name)

    -- A sound emote that is also a normal emote sends that emote as well, so
    -- everyone else sees it. Either way the sound's name goes out with it
    -- (see the callers), so everyone else hears it too; the name is the last
    -- value returned.
    if TrialChatCommon.EmoteDescriptions[name] then
        local emote = "/" .. name
        if argument ~= "" then
            emote = emote .. " " .. argument
        end
        return true, emote, played, waiting, name
    end

    return true, nil, played, waiting, name
end

function TrialChatCommon.ParseEmote(message)
    message = TrialChatCommon.NormalizeMessageMarkup(message)
    local command, argument = string.match(message, "^/([%a]+)%s*(.-)%s*$")
    if not command then
        return message, false
    end

    command = string.lower(command)
    if command == "e" or command == "em" or command == "emote" or command == "me" then
        if argument == "" then
            return nil
        end
        return argument, true, nil, nil
    end

    local description = TrialChatCommon.EmoteDescriptions[command]
    if not description then
        return message, false
    end

    local target = argument
    if target == "" and UnitExists("target") then
        target = UnitName("target") or ""
    end

    if target ~= "" then
        local targetedDescription =
            TrialChatCommon.TargetedEmoteDescriptions[command]
        if targetedDescription then
            description = string.gsub(targetedDescription,
                "%[playername%]", function() return target end)
        end
    end

    local token = _G.hash_EmoteTokenList
        and _G.hash_EmoteTokenList["/" .. string.upper(command)]
    -- Pass a name to the emote only when one was actually typed. With no name,
    -- leave the target out so the game aims the emote at whatever you have
    -- selected: a name (or unit token) is not honoured for NPCs, but omitting
    -- it targets them, and players, correctly.
    return description, true, token, argument ~= "" and argument or nil
end

function TrialChatCommon.PerformEmote(token, target)
    if not token then return end
    -- A unit name/token is not honoured for NPC targets, so only pass one when
    -- the player actually typed it. With no name, leave the argument off
    -- entirely (do not pass nil) so the game aims the emote at whatever is
    -- currently selected, which is the form that works for NPCs and players.
    if target and target ~= "" then
        C_ChatInfo.PerformEmote(token, target)
    else
        C_ChatInfo.PerformEmote(token)
    end
end

---------------------------------------------------------------------------
-- Group icons
--
-- A group's icon is one of the icons macros have, chosen by the group's
-- creator and shared with the members, like the group's name. It's stored as
-- the icon list's own entry: a file ID as digits, or an icon name.
---------------------------------------------------------------------------

-- The icons macros have, from the same API the macro icon picker builds its
-- grid from: the loose icons, then every spell and item icon. Cached, as the
-- lists don't change while the game runs.
local macroIconList

-- Turns a stored icon into something SetTexture understands.
function TrialChatCommon.GetIconTexture(icon)
    if type(icon) == "number" then return icon end
    if type(icon) ~= "string" or icon == "" then return nil end
    local fileID = tonumber(icon)
    if fileID then return fileID end
    if string.find(icon, "\\", 1, true) then return icon end
    return "Interface\\Icons\\" .. icon
end

function TrialChatCommon.GetMacroIconList()
    if macroIconList then return macroIconList end

    local icons, seen = {}, {}
    local function addAll(list)
        for index = 1, #list do
            local icon = list[index]
            if icon ~= nil then
                local key = tostring(icon)
                if key ~= "" and not seen[key] then
                    seen[key] = true
                    icons[#icons + 1] = key
                end
            end
        end
    end

    local spell, item = {}, {}
    if GetLooseMacroIcons then GetLooseMacroIcons(spell) end
    if GetMacroIcons then GetMacroIcons(spell) end
    if GetLooseMacroItemIcons then GetLooseMacroItemIcons(item) end
    if GetMacroItemIcons then GetMacroItemIcons(item) end
    addAll(spell)
    addAll(item)

    macroIconList = icons
    return icons
end

-- The icon a group falls back to when its creator hasn't picked one: a
-- distinct icon from the list, chosen by the group's name so it stays the
-- same for everyone and across sessions.
function TrialChatCommon.GetDefaultGroupIcon(name)
    local icons = TrialChatCommon.GetMacroIconList()
    if #icons == 0 then return nil end
    local hash = 0
    local key = TrialChatCommon.NormalizeName(name or "")
    for index = 1, #key do
        hash = (hash * 31 + string.byte(key, index)) % 2147483647
    end
    return icons[hash % #icons + 1]
end

local FADE_IN_PER_SECOND = 4
local FADE_OUT_PER_SECOND = 1.5
local fadingFrames = {}
local fadeDriver = CreateFrame("Frame")
fadeDriver:Hide()
fadeDriver:SetScript("OnUpdate", function(self, elapsed)
    for frame, targetAlpha in pairs(fadingFrames) do
        local alpha = frame:GetAlpha()
        if alpha < targetAlpha then
            alpha = math.min(targetAlpha, alpha + elapsed * FADE_IN_PER_SECOND)
        else
            alpha = math.max(targetAlpha, alpha - elapsed * FADE_OUT_PER_SECOND)
        end
        frame:SetAlpha(alpha)
        if alpha == targetAlpha then
            fadingFrames[frame] = nil
        end
    end
    if not next(fadingFrames) then
        self:Hide()
    end
end)

local HOVER_CHECK_SECONDS = 0.05

-- OnEnter/OnLeave are missed when the cursor moves quickly onto or off a
-- child that takes the mouse (like a chat log), so while the frame is shown
-- also re-check whether the cursor is over it a few times a second.
function TrialChatCommon.WatchHover(frame, update)
    local sinceLastCheck = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        sinceLastCheck = sinceLastCheck + elapsed
        if sinceLastCheck >= HOVER_CHECK_SECONDS then
            sinceLastCheck = 0
            update()
        end
    end)
end

-- Fades a frame towards the given alpha instead of jumping to it: quickly
-- when it becomes more visible, more gently when it fades back.
function TrialChatCommon.FadeTo(frame, targetAlpha)
    if frame:GetAlpha() == targetAlpha then
        fadingFrames[frame] = nil
        return
    end
    fadingFrames[frame] = targetAlpha
    fadeDriver:Show()
end
