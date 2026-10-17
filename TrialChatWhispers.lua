-- One-on-one whisper conversations, alongside nearby chat and your groups.
-- A whisper uses the game's own whisper chat ("WHISPER"), so it reaches the
-- other player in the normal chat whether or not they run TrialChat. This
-- module only keeps a per-player history, an unread count and the window's
-- list entry, so the conversation shows in the sidebar with the player's
-- portrait. Group messages never land here: they travel as addon messages,
-- which never fire CHAT_MSG_WHISPER.
TrialChatWhispers = {}
local Whispers = TrialChatWhispers

local normalizeName = TrialChatCommon.NormalizeName
local shortName = TrialChatCommon.ShortName
local isSelf = TrialChatCommon.IsSelf

-- A whisper is a normal chat message, so it keeps the game's own limit.
local MAX_MESSAGE_BYTES = 255
local MAX_HISTORY = 500
local MAX_CONVERSATIONS = 60
Whispers.MAX_MESSAGE_BYTES = MAX_MESSAGE_BYTES
Whispers.MAX_HISTORY = MAX_HISTORY

local PREFIX = "whisper:"

local conversations -- id -> { id, name, history = { entries } }, loaded lazily
local changeHandler
local viewedId

local function notifyChange(kind, id, ...)
    if changeHandler then
        changeHandler(kind, id, ...)
    end
end

local function getSavedWhispers()
    TrialChatDB = TrialChatDB or {}
    if type(TrialChatDB.whispers) ~= "table" then
        TrialChatDB.whispers = {}
    end
    return TrialChatDB.whispers
end

local function ensureLoaded()
    if conversations then return end
    conversations = {}
    for id, entry in pairs(getSavedWhispers()) do
        if type(entry) == "table" and type(entry.name) == "string" then
            conversations[id] = {
                id = id,
                name = entry.name,
                history = type(entry.history) == "table" and entry.history or {},
            }
        end
    end
end

local function saveConversation(conversation)
    if not conversation then return end
    getSavedWhispers()[conversation.id] = {
        name = conversation.name,
        history = conversation.history,
    }
end

local function getWhisperId(name)
    return PREFIX .. normalizeName(name)
end

function Whispers:IsWhisper(id)
    return type(id) == "string" and string.sub(id, 1, #PREFIX) == PREFIX
end

local function countUnread(conversation)
    local count = 0
    for _, entry in ipairs(conversation.history or {}) do
        if type(entry) == "table" and not entry.read and not isSelf(entry.sender) then
            count = count + 1
        end
    end
    return count
end

local function markRead(conversation)
    for _, entry in ipairs(conversation.history or {}) do
        if type(entry) == "table" then
            entry.read = true
        end
    end
end

-- A new conversation, or an existing one kept up to date with the name the
-- game reports (which carries the realm on a cross-realm whisper).
local function ensureConversation(name)
    ensureLoaded()
    local id = getWhisperId(name)
    local conversation = conversations[id]
    if not conversation then
        conversation = { id = id, name = name, history = {} }
        conversations[id] = conversation
        -- Most recent first, and never unbounded in SavedVariables.
        local ordered = {}
        for _, other in pairs(conversations) do
            local last = other.history[#other.history]
            ordered[#ordered + 1] = {
                conversation = other,
                timestamp = last and tonumber(last.timestamp) or 0,
            }
        end
        table.sort(ordered, function(a, b) return a.timestamp > b.timestamp end)
        for index = MAX_CONVERSATIONS + 1, #ordered do
            conversations[ordered[index].conversation.id] = nil
            getSavedWhispers()[ordered[index].conversation.id] = nil
        end
    elseif name ~= conversation.name then
        conversation.name = name
    end
    return conversation
end

local function addEntry(conversation, sender, message, isEmote, reply, fromSelf)
    local entry = {
        sender = sender,
        message = message,
        isEmote = isEmote or nil,
        timestamp = GetServerTime(),
        reply = reply or nil,
        -- Your own message, or one in the conversation you're reading now,
        -- starts off read.
        read = fromSelf or viewedId == conversation.id or nil,
    }
    conversation.history[#conversation.history + 1] = entry
    while #conversation.history > MAX_HISTORY do
        table.remove(conversation.history, 1)
    end
    saveConversation(conversation)
    return entry
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------
-- A whisper is sent as the game's own whisper, so it shows up in the normal
-- chat for both players and needs no addon on the other side.
function Whispers:SendMessage(id, message, reply)
    ensureLoaded()
    local conversation = id and conversations[id]
    if not conversation then return end

    message = strtrim(message or "")
    if message == "" then return end

    local isEmote, emoteToken, emoteTarget
    message, isEmote, emoteToken, emoteTarget = TrialChatCommon.ParseEmote(message)
    if not message then
        print("|cffa335eeTrialChat:|r Enter the text for your emote.")
        return
    end
    if #message > MAX_MESSAGE_BYTES then
        print("|cffa335eeTrialChat:|r Whispers are limited to "
            .. MAX_MESSAGE_BYTES .. " bytes.")
        return
    end
    if isEmote then
        -- An emote is not a message, so it never answers one.
        reply = nil
        TrialChatCommon.PerformEmote(emoteToken, emoteTarget)
    end

    local entry = addEntry(
        conversation, TrialChatCommon.GetPlayerFullName(),
        message, isEmote, reply, true)
    notifyChange("message", id, entry, true)

    -- Pipes would be read back as markup, so they're doubled for the wire.
    SendChatMessage(TrialChatCommon.EscapeChatPipes(message), "WHISPER", nil,
        conversation.name)
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------
local function onWhisper(message, sender)
    if type(sender) ~= "string" or sender == "" then return end
    if isSelf(sender) then return end
    message = strtrim(message or "")
    if message == "" then return end

    local conversation = ensureConversation(sender)
    local entry = addEntry(conversation, sender, message, false, nil, false)
    notifyChange("message", conversation.id, entry, true)
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("CHAT_MSG_WHISPER")
eventFrame:SetScript("OnEvent", function(_, _, message, sender)
    onWhisper(message, sender)
end)

---------------------------------------------------------------------------
-- What the window reads
---------------------------------------------------------------------------
function Whispers:SetChangeHandler(handler)
    changeHandler = handler
end

function Whispers:GetConversations()
    ensureLoaded()
    local list = {}
    for id, conversation in pairs(conversations) do
        local last = conversation.history[#conversation.history]
        list[#list + 1] = {
            id = id,
            name = conversation.name,
            state = "online",
            unread = countUnread(conversation),
            meta = shortName(conversation.name),
            timestamp = last and tonumber(last.timestamp) or 0,
        }
    end
    table.sort(list, function(a, b)
        if a.timestamp ~= b.timestamp then
            return a.timestamp > b.timestamp
        end
        return strlower(a.name) < strlower(b.name)
    end)
    return list
end

function Whispers:GetInfo(id)
    if not self:IsWhisper(id) then return nil end
    ensureLoaded()
    local conversation = conversations[id]
    if not conversation then return nil end
    return {
        id = id,
        name = conversation.name,
        displayName = shortName(conversation.name),
        unread = countUnread(conversation),
    }
end

function Whispers:GetHistory(id)
    ensureLoaded()
    local conversation = id and conversations[id]
    return conversation and conversation.history or {}
end

function Whispers:GetTotalUnreadCount()
    ensureLoaded()
    local count = 0
    for _, conversation in pairs(conversations) do
        count = count + countUnread(conversation)
    end
    return count
end

function Whispers:SetViewed(id)
    viewedId = id
    if not id then return end
    ensureLoaded()
    local conversation = conversations[id]
    if conversation then
        markRead(conversation)
        saveConversation(conversation)
        notifyChange("unread", id)
    end
end

-- Open a whisper conversation with a player (from a right-click menu).
function Whispers:OpenConversation(name)
    if not name or name == "" then return nil end
    local conversation = ensureConversation(name)
    saveConversation(conversation)
    notifyChange("open", conversation.id)
    return conversation.id
end

function Whispers:ClearHistory(id)
    ensureLoaded()
    local conversation = id and conversations[id]
    if not conversation then return end
    conversation.history = {}
    saveConversation(conversation)
    notifyChange("unread", id)
end

function Whispers:RemoveConversation(id)
    ensureLoaded()
    if not conversations[id] then return end
    conversations[id] = nil
    getSavedWhispers()[id] = nil
    if viewedId == id then viewedId = nil end
    notifyChange("unread", id)
end

-- Adds the whisper entry to a player menu (the game's player menus, and the
-- member list's menu in the window).
function Whispers:AddPlayerMenu(rootDescription, name)
    if not rootDescription or type(name) ~= "string" or name == ""
        or isSelf(name) then
        return
    end
    rootDescription:CreateDivider()
    rootDescription:CreateButton("Whisper in TrialChat", function()
        Whispers:OpenConversation(name)
    end)
end
