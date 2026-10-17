local PREFIX = "TrialChat"
local GROUP_TAG = "TCG1|"
local MAX_GROUP_NAME_BYTES = 24
local MAX_PASSWORD_BYTES = 32
local MAX_GROUP_MESSAGE_BYTES = 1000
local GROUP_PART_BYTES = 180
local MAX_HISTORY_CHUNKS = 16
local HISTORY_PAGE_SIZE = 50
local HISTORY_IDLE_TIMEOUT = 15
local HISTORY_CHECK_SECONDS = 5
local MAX_CHAT_HISTORY = 2000
local MAX_HISTORY_SYNC_MESSAGES = 50
local HISTORY_CHUNK_BYTES = 170
local MEMBER_TIMEOUT = 90
local MEMBER_UPDATE_INTERVAL = 30
local Groups = {}
TrialChatGroups = Groups

local activeGroups = {}
local pendingJoins = {}
local groupParts = TrialChatCommon.NewPartCollector()
local pendingGroupSaves = {}
local GROUP_SAVE_INTERVAL = 5
local selfName = TrialChatCommon.GetPlayerFullName()
local playerClass = TrialChatCommon.GetPlayerClass()

local function refreshIdentity()
    TrialChatCommon.RefreshPlayerIdentity()
    selfName = TrialChatCommon.GetPlayerFullName()
    playerClass = TrialChatCommon.GetPlayerClass()
end

local normalizeName = TrialChatCommon.NormalizeName

local function getSavedGroups()
    TrialChatDB = TrialChatDB or {}
    TrialChatDB.groups = TrialChatDB.groups or {}
    return TrialChatDB.groups
end

local isSelf = TrialChatCommon.IsSelf
local namesMatch = TrialChatCommon.NamesMatch

local function savedGroupIsCreator(group)
    if type(group) ~= "table" then return false end
    if group.creatorName then
        return namesMatch(group.creatorName, selfName)
    end
    if group.isCreator == true then return true end
    return not group.memberName
end

local function getGroupId(name)
    return normalizeName(name)
end

local function showNotice(message)
    print("|cffff7d0a[TrialChat Groups]|r " .. message)
end

local function findMemberKey(session, name)
    for key, member in pairs(session.members) do
        if namesMatch(member.name, name) then
            return key
        end
    end
end

local function hasMember(session, name)
    return findMemberKey(session, name) ~= nil
end

-- A known (offline) member: someone in the group's known list who isn't
-- currently connected. The member list shows them under "Offline".
local function isKnownMember(session, name)
    if not session or not name or not session.knownMembers then return false end
    local key = normalizeName(name)
    if key and session.knownMembers[key] then return true end
    for _, knownName in pairs(session.knownMembers) do
        if namesMatch(knownName, name) then return true end
    end
    return false
end

-- A member of the group, online or a known offline member.
local function isMember(session, name)
    return hasMember(session, name) or isKnownMember(session, name)
end

-- Removed members are remembered so they can't simply reconnect and rejoin.
local function isBanned(session, name)
    if not session or not name or not session.banned then return false end
    local key = normalizeName(name)
    if key and session.banned[key] then return true end
    for _, bannedName in pairs(session.banned) do
        if namesMatch(bannedName, name) then return true end
    end
    return false
end

local function addBanned(session, name)
    if not session or not name or name == "" or isSelf(name) then return end
    session.banned = session.banned or {}
    session.banned[normalizeName(name)] = name
end

local function unban(session, name)
    if not session or not name or not session.banned then return end
    local key = normalizeName(name)
    if key then
        session.banned[key] = nil
    end
    for bannedName, bannedValue in pairs(session.banned) do
        if namesMatch(bannedValue, name) then
            session.banned[bannedName] = nil
        end
    end
end

local persistGroup
local sendHistoryToMember
local getBannedList

local function queueGroupSave(session)
    if not session or activeGroups[session.id] ~= session then return end
    pendingGroupSaves[session.id] = session
end

local function flushGroupSaves()
    for id, session in pairs(pendingGroupSaves) do
        pendingGroupSaves[id] = nil
        if persistGroup then
            persistGroup(session)
        end
    end
end

local saveGroup = queueGroupSave

local changeHandler
local viewedGroupId

local function notifyChange(kind, id, ...)
    if changeHandler then
        changeHandler(kind, id, ...)
    end
end

local function isGroupViewed(session)
    return viewedGroupId == session.id
end

local function markGroupRead(session)
    for _, entry in ipairs(session.history or {}) do
        if type(entry) == "table" then
            entry.read = true
        end
    end
end

local function getUnreadCount(session)
    local count = 0
    for _, entry in ipairs(session.history or {}) do
        if type(entry) == "table" and not entry.read and not isSelf(entry.sender) then
            count = count + 1
        end
    end
    return count
end

local leftMembers = {} -- track members who left while not everyone was online

function Groups:GetLeftMembersInfo(id)
    return leftMembers[id]
end

-- Persist the pending "left while others were offline" notices so they survive
-- a UI reload before the creator next opens the group.
local function persistLeftMembers(id)
    local saved = getSavedGroups()[id]
    if not saved then return end
    local list = {}
    for _, info in pairs(leftMembers[id] or {}) do
        list[#list + 1] = info.name
    end
    table.sort(list, function(a, b)
        return normalizeName(a) < normalizeName(b)
    end)
    saved.leftMembers = #list > 0 and list or nil
end

local function restoreLeftMembers(id, savedGroup)
    if type(savedGroup) ~= "table" or type(savedGroup.leftMembers) ~= "table" then
        return
    end
    leftMembers[id] = leftMembers[id] or {}
    for _, name in ipairs(savedGroup.leftMembers) do
        if type(name) == "string" and name ~= "" then
            local key = normalizeName(name)
            if key and not leftMembers[id][key] then
                leftMembers[id][key] = { name = name, time = 0 }
            end
        end
    end
end

local function recordLeftMember(id, name)
    if not id or not name then return end
    leftMembers[id] = leftMembers[id] or {}
    local key = normalizeName(name)
    if key then
        leftMembers[id][key] = { name = name, time = GetTime() }
    end
    persistLeftMembers(id)
end

local function clearLeftMember(id, name)
    if not id or not name or not leftMembers[id] then return end
    local key = normalizeName(name)
    if key then
        leftMembers[id][key] = nil
        if next(leftMembers[id]) == nil then
            leftMembers[id] = nil
        end
    end
    persistLeftMembers(id)
end

local function addKnownMember(session, name)
    if not name or name == "" or isSelf(name) or isBanned(session, name) then return end
    session.knownMembers = session.knownMembers or {}
    session.knownMembers[normalizeName(name)] = name
    session.reconnectName = name
end

local getClassColor = TrialChatCommon.GetClassColor

local function addMember(session, name, classFile)
    if not name or name == "" or isBanned(session, name) then return end

    addKnownMember(session, name)
    local key = findMemberKey(session, name) or normalizeName(name)
    local existing = session.members[key]
    classFile = classFile or (existing and existing.classFile)
        or (isSelf(name) and playerClass) or TrialChatCommon.GetKnownClass(name)
    session.members[key] = {
        name = name,
        lastSeen = GetTime(),
        classFile = classFile,
    }
    -- If they were recorded as left, clear that record when they rejoin/are seen
    clearLeftMember(session.id, name)
    if activeGroups[session.id] == session and saveGroup then
        saveGroup(session)
    end
    if activeGroups[session.id] == session then
        notifyChange("members", session.id)
    end
end

local function removeMember(session, name, reason)
    if not name or name == "" then return end

    local key = findMemberKey(session, name)
    local wasMember = (key ~= nil)
    if key then session.members[key] = nil end
    -- Also drop them from the known (offline-capable) list when they left for
    -- good (explicit leave or kick), so they don't linger there. A timeout
    -- just means they went quiet; keep them as a possible reconnection path.
    if session.knownMembers and reason ~= "timeout" then
        session.knownMembers[normalizeName(name)] = nil
    end
    if session.reconnectName and namesMatch(session.reconnectName, name) then
        local mostRecentMember
        for _, member in pairs(session.members) do
            if not isSelf(member.name)
                and (not mostRecentMember or member.lastSeen > mostRecentMember.lastSeen) then
                mostRecentMember = member
            end
        end
        if mostRecentMember then
            session.reconnectName = mostRecentMember.name
        else
            -- No one online: reconnect through another known member, if any.
            session.reconnectName = nil
            for _, knownName in pairs(session.knownMembers or {}) do
                if not isSelf(knownName) then
                    session.reconnectName = knownName
                    break
                end
            end
        end
    end
    -- If nobody else was around to see them go (except possibly you), note
    -- that they left so the creator can be told next time they see this
    -- person. A kick isn't a voluntary leave, so it isn't recorded.
    if wasMember and reason ~= "kicked" and not isSelf(name) then
        local now = GetTime()
        local othersOnline = false
        for _, member in pairs(session.members) do
            if not isSelf(member.name)
                and now - (member.lastSeen or 0) <= MEMBER_TIMEOUT then
                othersOnline = true
                break
            end
        end
        if not othersOnline then
            recordLeftMember(session.id, name)
        end
    end
    if activeGroups[session.id] == session and saveGroup then
        saveGroup(session)
    end
    if activeGroups[session.id] == session then
        notifyChange("members", session.id, name, reason)
        notifyChange("memberremoved", session.id, name, reason)
    end
    return wasMember
end

local function sendGroupProtocol(session, kind, target, body)
    if not target then return false end
    -- Message bodies arrive here already encoded (see sendGroupMessage and
    -- sendHistoryEntry): the reply prefix needs its separators to survive
    -- as separators, so the text can't be encoded a second time here.
    local payload = GROUP_TAG .. kind .. "|" .. session.id .. "|" .. (body or "")
    if #payload > 255 then
        showNotice("That group message is too long to send.")
        return false
    end

    local sent, err = pcall(
        C_ChatInfo.SendAddonMessage, PREFIX, payload, "WHISPER", target)
    if not sent then
        showNotice("Could not send a group message to " .. target .. ": " .. err)
    end
    return sent
end

local function sendToMembers(session, kind, body, exceptName)
    local sent = false
    for key, member in pairs(session.members) do
        if not namesMatch(member.name, selfName or UnitName("player"))
            and not (exceptName and namesMatch(member.name, exceptName)) then
            sent = sendGroupProtocol(session, kind, member.name, body) or sent
        end
    end
    return sent
end

-- Your race and gender as "Race:sex" (2 male, 3 female), so members far away
-- can show your race portrait.
local function getOwnLook()
    local _, raceFile = UnitRace("player")
    local sex = UnitSex("player")
    if raceFile and (sex == 2 or sex == 3) then
        return raceFile .. ":" .. sex
    end
end

local function makeMessageId(sender, counter)
    local hash = 5381
    for index = 1, #sender do
        hash = (hash * 33 + string.byte(sender, index)) % 4294967296
    end
    return string.format("%08x-%08x-%04x-%04x",
        hash, GetServerTime(), counter % 65536, math.random(0, 65535))
end

local function ensureHistoryIndex(session)
    if session.historyIds then return end
    session.historyIds = {}
    for _, item in ipairs(session.history or {}) do
        if type(item) == "table" and item.id then
            session.historyIds[item.id] = true
        end
    end
end

local function historyLessThan(left, right)
    local leftTimestamp = type(left) == "table" and left.timestamp or 0
    local rightTimestamp = type(right) == "table" and right.timestamp or 0
    if leftTimestamp ~= rightTimestamp then
        return leftTimestamp < rightTimestamp
    end
    local leftId = type(left) == "table" and left.id or tostring(left)
    local rightId = type(right) == "table" and right.id or tostring(right)
    return leftId < rightId
end

local function insertHistoryEntry(session, entry)
    local history = session.history
    local insertAt = #history + 1
    for index = #history, 1, -1 do
        if not historyLessThan(entry, history[index]) then
            insertAt = index + 1
            break
        end
        insertAt = index
    end
    table.insert(history, insertAt, entry)
    if entry.id then
        session.historyIds[entry.id] = true
    end

    local droppedEntry = false
    while #history > MAX_CHAT_HISTORY do
        local removed = table.remove(history, 1)
        if type(removed) == "table" and removed.id then
            session.historyIds[removed.id] = nil
        end
        if removed == entry then
            droppedEntry = true
        end
        insertAt = insertAt - 1
    end
    if droppedEntry then return nil end
    return insertAt
end

local function addGroupMessage(
    session, sender, message, isEmote, messageId, timestamp, isHistorical,
    shouldNotify, reply)
    if isHistorical then
        addKnownMember(session, sender)
    else
        addMember(session, sender)
    end
    message = TrialChatCommon.NormalizeMessageMarkup(message)
    if reply then
        reply.text = TrialChatCommon.NormalizeMessageMarkup(reply.text or "")
    end
    session.history = type(session.history) == "table" and session.history or {}
    ensureHistoryIndex(session)

    if messageId then
        if session.historyIds[messageId] then
            return false
        end
    else
        session.messageCounter = (session.messageCounter or 0) + 1
        messageId = makeMessageId(sender, session.messageCounter)
    end
    timestamp = timestamp or GetServerTime()

    -- No sound for a group you're already looking at in TrialChat.
    if shouldNotify and not session.muted and not isGroupViewed(session) then
        PlaySound(SOUNDKIT.TELL_MESSAGE)
    end

    local entry = {
        id = messageId,
        sender = sender,
        message = message,
        isEmote = isEmote,
        timestamp = timestamp,
        reply = reply,
    }
    if isSelf(sender) or isGroupViewed(session) then
        entry.read = true
    end
    local insertAt = insertHistoryEntry(session, entry)

    if activeGroups[session.id] == session then
        queueGroupSave(session)
    end
    if insertAt and activeGroups[session.id] == session then
        notifyChange("message", session.id, entry, insertAt == #session.history)
    end
    return insertAt ~= nil, entry
end

local function sendHistoryEntry(session, target, entry, initialDelay)
    local emoteFlag = entry.isEmote and "E" or "M"
    -- The message keeps its reply prefix, and the text stays encoded, so
    -- the receiver can tell the reply's separators apart (see
    -- TrialChatCommon.EncodeReplyPrefix).
    local serialized = table.concat({
        entry.id, tostring(entry.timestamp),
        TrialChatCommon.EncodeMessageMarkup(entry.sender),
        emoteFlag,
        TrialChatCommon.EncodeReplyPrefix(entry.reply)
            .. TrialChatCommon.EncodeMessageMarkup(entry.message),
    }, ":")
    local chunkCount = math.ceil(#serialized / HISTORY_CHUNK_BYTES)
    for index = 1, chunkCount do
        local chunk = string.sub(serialized,
            (index - 1) * HISTORY_CHUNK_BYTES + 1,
            index * HISTORY_CHUNK_BYTES)
        local payload = entry.id .. ":" .. index .. ":" .. chunkCount .. ":" .. chunk
        C_Timer.After((initialDelay or 0) + (index - 1) * 0.1, function()
            sendGroupProtocol(session, "HIST", target, payload)
        end)
    end
    return chunkCount
end

sendHistoryToMember = function(session, target)
    local entries = {}
    for index = #session.history, 1, -1 do
        local item = session.history[index]
        if type(item) == "table" then
            table.insert(entries, 1, item)
            if #entries >= MAX_HISTORY_SYNC_MESSAGES then break end
        end
    end

    local delay = 0
    for _, entry in ipairs(entries) do
        delay = delay + sendHistoryEntry(session, target, entry, delay) * 0.1
    end
end

-- Answers a history page request: up to a page of entries older than the
-- requested cursor (newest page when there is none), then HISTEND with how
-- many were sent and the oldest one, which is the cursor for the next page.
local function sendHistoryPage(session, target, body)
    local targetKey = normalizeName(target)
    session.historyPagesSending = session.historyPagesSending or {}
    if session.historyPagesSending[targetKey] then return end

    local beforeTimestamp, beforeId = string.match(body or "", "^(%d+):([%x%-]+)$")
    local cursor = beforeTimestamp
        and { timestamp = tonumber(beforeTimestamp), id = beforeId }
    local page = {}
    for index = #session.history, 1, -1 do
        local entry = session.history[index]
        if type(entry) == "table" and (not cursor or historyLessThan(entry, cursor)) then
            table.insert(page, 1, entry)
            if #page >= HISTORY_PAGE_SIZE then break end
        end
    end

    local delay = 0
    for _, entry in ipairs(page) do
        delay = delay + sendHistoryEntry(session, target, entry, delay) * 0.1
    end
    local oldest = page[1]
    local endBody = #page .. ":"
        .. (oldest and (oldest.timestamp .. ":" .. oldest.id) or ":")
    session.historyPagesSending[targetKey] = true
    C_Timer.After(delay + 0.1, function()
        session.historyPagesSending[targetKey] = nil
        sendGroupProtocol(session, "HISTEND", target, endBody)
    end)
end

local pendingHistoryChunks = {}

local function receiveHistoryChunk(session, sender, body)
    local messageId, chunkIndex, chunkCount, chunk =
        string.match(body, "^([%x%-]+):(%d+):(%d+):(.*)$")
    chunkIndex = tonumber(chunkIndex)
    chunkCount = tonumber(chunkCount)
    if not messageId or not chunkIndex or not chunkCount
        or chunkCount < 1 or chunkCount > MAX_HISTORY_CHUNKS
        or chunkIndex < 1 or chunkIndex > chunkCount then
        return
    end

    local key = session.id .. "\0" .. normalizeName(sender) .. "\0" .. messageId
    local transfer = pendingHistoryChunks[key]
    if not transfer then
        transfer = { chunks = {}, count = chunkCount }
        pendingHistoryChunks[key] = transfer
    elseif transfer.count ~= chunkCount then
        pendingHistoryChunks[key] = nil
        return
    end
    transfer.chunks[chunkIndex] = chunk

    for index = 1, chunkCount do
        if not transfer.chunks[index] then return end
    end
    pendingHistoryChunks[key] = nil

    local serialized = table.concat(transfer.chunks)
    -- Read the reply before decoding, so its separators still hold.
    local entryId, rawTimestamp, rawSender, emoteFlag, encodedMessage =
        string.match(serialized, "^([%x%-]+):(%d+):([^:]+):([ME]):(.*)$")
    local timestamp = tonumber(rawTimestamp)
    if entryId ~= messageId or not timestamp then return end
    local reply
    reply, encodedMessage = TrialChatCommon.SplitReplyPrefix(encodedMessage)

    return addGroupMessage(session,
        TrialChatCommon.DecodeMessageMarkup(rawSender),
        TrialChatCommon.DecodeMessageMarkup(encodedMessage),
        emoteFlag == "E", entryId, timestamp, true, false, reply)
end

-- Loading the full history: ask one online member for their history a page
-- at a time, newest first, until they have nothing older or ours is full.
-- Walking all of it also fills gaps from times we were offline. Members on
-- older versions don't answer, so after a while without progress the next
-- online member is asked instead.
local requestHistoryPage

local function notifyHistoryProgress(session)
    notifyChange("history", session.id)
end

local function finishHistoryLoad(session, message)
    session.historyLoad = nil
    notifyHistoryProgress(session)
    showNotice(session.name .. ": " .. message)
end

local function useNextHistorySource(session)
    local load = session.historyLoad
    local candidates = {}
    for _, member in pairs(session.members) do
        if not isSelf(member.name) and not load.tried[normalizeName(member.name)] then
            candidates[#candidates + 1] = member.name
        end
    end
    if #candidates == 0 then
        if load.added > 0 then
            finishHistoryLoad(session, "loaded " .. load.added
                .. " messages, but no other member answered for the rest.")
        elseif next(load.tried) then
            finishHistoryLoad(session,
                "no member answered. They may need to update TrialChat.")
        else
            finishHistoryLoad(session, "no other members are online.")
        end
        return
    end

    table.sort(candidates, function(left, right)
        return normalizeName(left) < normalizeName(right)
    end)
    load.source = candidates[1]
    load.tried[normalizeName(load.source)] = true
    load.cursor = nil
    requestHistoryPage(session)
end

requestHistoryPage = function(session)
    local load = session.historyLoad
    load.lastActivity = GetTime()
    local body = load.cursor
        and (load.cursor.timestamp .. ":" .. load.cursor.id) or ""
    sendGroupProtocol(session, "HISTREQ", load.source, body)
end

local function watchHistoryLoad(session, load)
    C_Timer.After(HISTORY_CHECK_SECONDS, function()
        if session.historyLoad ~= load then return end
        if GetTime() - load.lastActivity > HISTORY_IDLE_TIMEOUT then
            useNextHistorySource(session)
        end
        watchHistoryLoad(session, load)
    end)
end

local function startHistoryLoad(session)
    if session.historyLoad or activeGroups[session.id] ~= session then return end
    local load = { added = 0, tried = {} }
    session.historyLoad = load
    notifyHistoryProgress(session)
    useNextHistorySource(session)
    if session.historyLoad == load then
        watchHistoryLoad(session, load)
    end
end

local function receiveHistoryPageEnd(session, sender, body)
    local load = session.historyLoad
    if not load or not namesMatch(load.source, sender) then return end
    load.lastActivity = GetTime()

    local count, timestamp, entryId = string.match(body, "^(%d+):(%d*):([%x%-]*)$")
    count, timestamp = tonumber(count), tonumber(timestamp)
    local cursor = timestamp and { timestamp = timestamp, id = entryId }
    -- With a full history, anything older than our oldest entry would be
    -- dropped again straight away, so there is no point asking for it.
    local oldest = session.history[1]
    local historyFull = cursor and #session.history >= MAX_CHAT_HISTORY
        and type(oldest) == "table" and not historyLessThan(oldest, cursor)
    if not count or count < HISTORY_PAGE_SIZE or not cursor or historyFull then
        finishHistoryLoad(session, load.added > 0
            and ("loaded " .. load.added .. " messages you were missing.")
            or "you already have the full history.")
        return
    end

    load.cursor = cursor
    requestHistoryPage(session)
end

local function sendGroupMessage(session, message, reply)
    message = strtrim(message or "")
    if message == "" then return end

    local isEmote
    local emoteToken
    local emoteTarget
    -- Sound emotes use "//" and play a local file; a sound emote that is also
    -- a normal emote continues below as that emote, a sound-only one stops
    -- here. Either way its name is sent to the group as well, so everyone in
    -- it hears the sound: they play their own copy of the same file.
    local isSoundEmote, soundEmote, soundPlayed, soundWaiting, soundName =
        TrialChatCommon.ParseSoundEmote(message)
    if isSoundEmote then
        if not soundEmote then
            if not soundPlayed and not soundWaiting
                and TrialChatCommon.IsGameSoundEnabled() then
                showNotice("No sound emote found for that command.")
            end
            if soundName then
                sendToMembers(session, "SOUND", soundName)
            end
            return
        end
        message = soundEmote
    end
    message, isEmote, emoteToken, emoteTarget =
        TrialChatCommon.ParseEmote(message)
    if not message then
        showNotice("Enter the text for your emote.")
        return
    end
    if #message > MAX_GROUP_MESSAGE_BYTES then
        showNotice("Group messages are limited to " .. MAX_GROUP_MESSAGE_BYTES .. " bytes.")
        return
    end
    -- An emote isn't a message, so it never answers one.
    if isEmote then reply = nil end
    local sender = selfName or UnitName("player")
    session.messageCounter = (session.messageCounter or 0) + 1
    local messageId = makeMessageId(sender, session.messageCounter)
    local timestamp = GetServerTime()
    local messageKind = isEmote and "EMOTE2" or "MSG2"
    local encodedBody = table.concat({
        messageId, tostring(timestamp), isEmote and "E" or "M",
        TrialChatCommon.EncodeReplyPrefix(reply)
            .. TrialChatCommon.EncodeMessageMarkup(
                TrialChatCommon.AddOwnSongLinkOwner(message)),
    }, ":")
    local payload = GROUP_TAG .. messageKind .. "|" .. session.id .. "|" .. encodedBody

    TrialChatCommon.PerformEmote(emoteToken, emoteTarget)
    local added, entry = addGroupMessage(
        session, sender, message, isEmote, messageId, timestamp, false, false,
        reply)
    if #payload <= 255 then
        sendToMembers(session, messageKind, encodedBody)
    else
        -- Too long for one addon message: send it in parts the members join.
        local parts = TrialChatCommon.SplitIntoParts(encodedBody, GROUP_PART_BYTES)
        for index, part in ipairs(parts) do
            sendToMembers(session, "PART",
                messageId .. ":" .. index .. ":" .. #parts .. ":" .. part)
        end
    end
    -- The sound emote's name rides along with the message, so everyone in
    -- the group hears the sound as well; each plays their own copy of the file.
    if soundName then
        sendToMembers(session, "SOUND", soundName)
    end
    if added and not isEmote then
        TrialChatBubbles.ShowOwnMessage(entry.message, session.name)
    end
end

persistGroup = function(session)
    if not session then return end
    pendingGroupSaves[session.id] = nil
    -- Passwords are a shared room key stored in SavedVariables and sent in HELLO whispers.
    local savedGroups = getSavedGroups()
    for _, member in pairs(session.members or {}) do
        if not isSelf(member.name) then
            session.knownMembers = session.knownMembers or {}
            session.knownMembers[normalizeName(member.name)] = member.name
        end
    end
    local knownMembers = {}
    for _, member in pairs(session.knownMembers or {}) do
        knownMembers[#knownMembers + 1] = member
    end
    table.sort(knownMembers, function(left, right)
        return normalizeName(left) < normalizeName(right)
    end)
    savedGroups[session.id] = {
        name = session.name,
        password = session.password,
        icon = session.icon,
        muted = session.muted == true,
        memberName = session.reconnectName or session.targetName,
        isCreator = session.isCreator == true,
        creatorName = session.creatorName,
        history = session.history or {},
        knownMembers = knownMembers,
        banned = getBannedList(session),
        unreadTracking = true,
    }
    persistLeftMembers(session.id)
end

-- The removed members, as a sorted list of names, for saving.
getBannedList = function(session)
    local list = {}
    for _, name in pairs(session.banned or {}) do
        list[#list + 1] = name
    end
    table.sort(list, function(left, right)
        return normalizeName(left) < normalizeName(right)
    end)
    return #list > 0 and list or nil
end

local function getBanned(savedGroup)
    local banned = {}
    local savedBanned = type(savedGroup and savedGroup.banned) == "table"
        and savedGroup.banned or {}
    for _, name in ipairs(savedBanned) do
        if type(name) == "string" and name ~= "" and not isSelf(name) then
            banned[normalizeName(name)] = name
        end
    end
    return banned
end

local function getKnownMembers(savedGroup)
    local knownMembers = {}
    local savedMembers = type(savedGroup and savedGroup.knownMembers) == "table"
        and savedGroup.knownMembers or {}
    for _, name in ipairs(savedMembers) do
        if type(name) == "string" and name ~= "" and not isSelf(name) then
            knownMembers[normalizeName(name)] = name
        end
    end
    if savedGroup and savedGroup.memberName and not isSelf(savedGroup.memberName) then
        knownMembers[normalizeName(savedGroup.memberName)] = savedGroup.memberName
    end
    return knownMembers
end

local function getJoinCandidates(savedGroup, preferredName)
    local candidates = {}
    local function addCandidate(name)
        if type(name) ~= "string" or name == "" or isSelf(name) then return end
        for _, candidate in ipairs(candidates) do
            if namesMatch(candidate, name) then return end
        end
        candidates[#candidates + 1] = name
    end

    addCandidate(preferredName)
    local knownMembers = getKnownMembers(savedGroup)
    local sortedMembers = {}
    for _, name in pairs(knownMembers) do
        sortedMembers[#sortedMembers + 1] = name
    end
    table.sort(sortedMembers, function(left, right)
        return normalizeName(left) < normalizeName(right)
    end)
    for _, name in ipairs(sortedMembers) do
        addCandidate(name)
    end
    return candidates
end

local function isJoinCandidate(session, name)
    for _, candidate in ipairs(session.joinCandidates or {}) do
        if namesMatch(candidate, name) then return true end
    end
    return false
end

-- Shows a group you just connected to or asked for in TrialChat.
local function showSession(session)
    notifyChange("open", session.id)
end

local function activateGroup(session)
    pendingJoins[session.id] = nil
    activeGroups[session.id] = session
    session.members = session.members or {}
    addMember(session, selfName or UnitName("player"))
    persistGroup(session)
    notifyChange("groups", session.id)
    if not session.autoJoin then
        showSession(session)
    end
end

local function completePendingJoin(session, sender)
    addMember(session, sender)
    activateGroup(session)
    sendToMembers(session, "MEMBER", selfName or UnitName("player"))
    if getOwnLook() then
        sendToMembers(session, "LOOK", getOwnLook())
    end
    sendHistoryToMember(session, sender)
end

local function validateMemberName(name)
    name = strtrim(name or "")
    if name == "" or #name > 64 or string.find(name, "[%c|]") then
        showNotice("Enter the character name of an online group member.")
        return nil
    end
    return name
end

local startJoinAttempt
local openGroupDialog
local createGroup

local function joinGroup(name, password, targetName, savedGroup, autoJoin)
    local id = getGroupId(name)
    local active = activeGroups[id]
    if active then
        showSession(active)
        return
    end
    if pendingJoins[id] then
        showNotice("Already connecting to " .. name .. ".")
        return
    end

    if targetName then
        targetName = validateMemberName(targetName)
        if not targetName then return end
    end

    local joinCandidates = getJoinCandidates(savedGroup, targetName)
    if #joinCandidates == 0 then
        showNotice("Enter the name of an online group member to connect through.")
        return
    end

    local session = {
        id = id,
        name = name,
        password = password,
        members = {},
        targetName = joinCandidates[1],
        icon = savedGroup and savedGroup.icon,
        isCreator = savedGroup and savedGroupIsCreator(savedGroup),
        creatorName = savedGroup and savedGroup.creatorName,
        history = savedGroup and type(savedGroup.history) == "table"
            and savedGroup.history or {},
        muted = savedGroup and savedGroup.muted == true,
        autoJoin = autoJoin == true,
        knownMembers = getKnownMembers(savedGroup),
        banned = getBanned(savedGroup),
        reconnectName = joinCandidates[1],
        joinCandidates = joinCandidates,
        hasSavedGroup = type(savedGroup) == "table",
    }
    -- History saved before unread tracking existed counts as already read.
    if not (savedGroup and savedGroup.unreadTracking) then
        markGroupRead(session)
    end
    restoreLeftMembers(id, savedGroup)
    pendingJoins[id] = session
    notifyChange("groups", id)
    startJoinAttempt(session, 1)
end

startJoinAttempt = function(session, candidateIndex)
    local id = session.id
    local targetName = session.joinCandidates[candidateIndex]
    session.targetName = targetName
    if not sendGroupProtocol(session, "HELLO", targetName, session.password) then
        pendingJoins[id] = nil
        notifyChange("groups", id)
        return
    end

    for retry = 1, 3 do
        C_Timer.After(retry * 2, function()
            if pendingJoins[id] == session and session.targetName == targetName then
                sendGroupProtocol(session, "HELLO", targetName, session.password)
            end
        end)
    end
    C_Timer.After(8, function()
        if pendingJoins[id] ~= session or session.targetName ~= targetName then return end
        local nextCandidate = candidateIndex + 1
        if session.joinCandidates[nextCandidate] then
            startJoinAttempt(session, nextCandidate)
            return
        end

        pendingJoins[id] = nil
        notifyChange("groups", id)
        if session.isCreator or session.hasSavedGroup then
            showNotice("No saved group member replied. Opening your saved group locally.")
            createGroup(session.name, session.password, getSavedGroups()[id] or {
                name = session.name,
                password = session.password,
                icon = session.icon,
                isCreator = session.isCreator == true,
                creatorName = session.creatorName,
                memberName = session.reconnectName,
                history = session.history,
                knownMembers = session.knownMembers,
                muted = session.muted,
                unreadTracking = true,
            }, session.autoJoin)
            return
        end

        showNotice("No saved group member replied. Choose an online member if one is available.")
        openGroupDialog("join", getSavedGroups()[id] or {
            name = session.name,
            password = session.password,
            memberName = targetName,
            knownMembers = session.knownMembers,
        })
    end)
end

createGroup = function(name, password, savedGroup, autoJoin, icon)
    local id = getGroupId(name)
    if activeGroups[id] then
        showSession(activeGroups[id])
        return
    end
    if pendingJoins[id] then
        showNotice("Already connecting to " .. name .. ".")
        return
    end

    local session = {
        id = id,
        name = name,
        password = password,
        members = {},
        icon = icon or (savedGroup and savedGroup.icon)
            or TrialChatCommon.GetDefaultGroupIcon(name),
        isCreator = savedGroup
            and savedGroupIsCreator(savedGroup) or not savedGroup,
        creatorName = savedGroup and savedGroup.creatorName
            or (not savedGroup and (selfName or UnitName("player"))),
        history = savedGroup and type(savedGroup.history) == "table"
            and savedGroup.history or {},
        muted = savedGroup and savedGroup.muted == true,
        autoJoin = autoJoin == true,
        knownMembers = getKnownMembers(savedGroup),
        banned = getBanned(savedGroup),
        reconnectName = savedGroup and savedGroup.memberName,
    }
    if not (savedGroup and savedGroup.unreadTracking) then
        markGroupRead(session)
    end
    restoreLeftMembers(id, savedGroup)
    activateGroup(session)
end

-- Why a group name and password can't be used, or nil when they can.
local function getGroupDetailsProblem(name, password)
    if #name == 0 or #name > MAX_GROUP_NAME_BYTES
        or not string.match(name, "^[%w _]+$") then
        return "Use a group name of 1-" .. MAX_GROUP_NAME_BYTES
            .. " letters, numbers, spaces, or underscores."
    end
    if #password == 0 or #password > MAX_PASSWORD_BYTES
        or string.find(password, "[%c]") then
        return "Enter a password of 1-" .. MAX_PASSWORD_BYTES .. " characters."
    end
end

-- What was entered in the create/join dialog: creates or joins the group,
-- or returns why it can't, for the dialog to show.
local function submitGroupDialog(mode, values, preset)
    local name = strtrim(values.name or "")
    local password = values.password or ""
    local problem = getGroupDetailsProblem(name, password)
    if problem then return problem end

    if mode == "create" then
        createGroup(name, password, preset, nil, values.icon)
        return nil
    end
    local memberName = strtrim(values.memberName or "")
    local id = getGroupId(name)
    if not activeGroups[id] and not pendingJoins[id]
        and (memberName == "" or #memberName > 64 or string.find(memberName, "[%c|]")) then
        return "Enter the character name of an online group member."
    end
    joinGroup(name, password, memberName, preset)
end

-- mode is "create" or "join"; preset fills in a saved group's details.
openGroupDialog = function(mode, preset)
    TrialChatGroupDialog.Show(mode, preset, function(values)
        return submitGroupDialog(mode, values, preset)
    end)
end

local function disconnectSession(id)
    local session = activeGroups[id]
    if not session then return nil end

    persistGroup(session)
    sendToMembers(session, "BYE")
    pendingGroupSaves[id] = nil
    activeGroups[id] = nil
    session.members = {}
    notifyChange("groups", id)
    return session
end

local function disconnectGroup(id)
    local session = disconnectSession(id)
    if not session then return end
    showNotice("Disconnected from " .. session.name
        .. ". It remains in your saved groups.")
end

local function exitGroup(id)
    local savedGroup = getSavedGroups()[id]
    if not savedGroup or savedGroupIsCreator(savedGroup) then
        showNotice("Only non-creator members can exit a saved group.")
        return
    end

    local session = disconnectSession(id)
    pendingJoins[id] = nil
    pendingGroupSaves[id] = nil
    getSavedGroups()[id] = nil
    showNotice("Exited " .. (session and session.name or savedGroup.name)
        .. " and removed it from your saved groups.")
end

local function deleteGroup(id)
    local session = activeGroups[id]
    local savedGroup = getSavedGroups()[id]
    if not (session and session.isCreator)
        and not savedGroupIsCreator(savedGroup) then
        showNotice("Only the group creator can delete this group.")
        return
    end

    if session then
        sendToMembers(session, "DELETE")
        pendingGroupSaves[id] = nil
        activeGroups[id] = nil
        session.members = {}
    end
    pendingGroupSaves[id] = nil
    getSavedGroups()[id] = nil
    notifyChange("groups", id)
    showNotice("Deleted " .. (session and session.name or savedGroup.name) .. ".")
end

-- Any member can invite a player to a connected group. The invite carries
-- the group's name and password, as joining needs them; TrialChat opens on
-- the player's side with the invite in it, and joining goes through whoever
-- invited them. They answer with an INVITEREPLY of "shown", "declined",
-- "member" (already in it) or "busy" (another invite is open). Versions
-- without invites don't answer at all.
local INVITE_SECONDS = 60
local INVITE_ANSWER_SECONDS = 5
-- After declining, the same player's invites to that group are declined
-- without asking for a while.
local INVITE_REPEAT_SECONDS = 60
local sentInvites = {}
local declinedInvites = {}
local shownInvite

local function findSentInvite(id, name)
    for index, invite in ipairs(sentInvites) do
        if invite.id == id and namesMatch(invite.name, name) then
            return invite, index
        end
    end
end

local function answerInvite(invite, answer)
    sendGroupProtocol({ id = invite.id }, "INVITEREPLY", invite.sender, answer)
end

local function getDeclineKey(invite)
    return invite.id .. "\0" .. normalizeName(invite.sender)
end

-- The inviter's name in their class color, with their realm when it isn't yours.
local function getInviterText(sender)
    local name, realm = string.match(sender, "^([^-]+)%-(.+)$")
    local text = sender
    if name and TrialChatCommon.NormalizeRealm(realm)
        == TrialChatCommon.NormalizeRealm(TrialChatCommon.GetPlayerRealm() or "") then
        text = name
    end
    local color = getClassColor(TrialChatCommon.GetKnownClass(sender))
    return color and (color .. text .. "|r") or text
end

local function defineInviteDialog()
    if StaticPopupDialogs.TRIALCHAT_INVITE_PLAYER then return end

    StaticPopupDialogs.TRIALCHAT_INVITE_PLAYER = {
        text = "Invite a player to %s:",
        button1 = "Invite",
        button2 = CANCEL,
        hasEditBox = true,
        maxLetters = 12 + 1 + 64,
        autoCompleteSource = C_AutoComplete and C_AutoComplete.GetAutoCompleteResults,
        autoCompleteArgs = AUTOCOMPLETE_LIST and AUTOCOMPLETE_LIST.WHISPER
            and { AUTOCOMPLETE_LIST.WHISPER.include, AUTOCOMPLETE_LIST.WHISPER.exclude },
        OnShow = function(popup)
            popup:GetEditBox():SetFocus()
        end,
        OnAccept = function(popup, id)
            Groups:Invite(id, popup:GetEditBox():GetText())
        end,
        OnHide = function(popup)
            popup:GetEditBox():SetText("")
        end,
        EditBoxOnEnterPressed = function(editBox, id)
            Groups:Invite(id, editBox:GetText())
            editBox:GetParent():Hide()
        end,
        EditBoxOnEscapePressed = StaticPopup_StandardEditBoxOnEscapePressed,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

local function receiveInvite(id, sender, body)
    local name, password = string.match(body, "^([^:]+):(.*)$")
    if not name or getGroupDetailsProblem(name, password)
        or getGroupId(name) ~= id then
        return
    end
    if C_FriendList and C_FriendList.IsOnIgnoredList
        and C_FriendList.IsOnIgnoredList(sender) then
        return
    end

    local invite = { id = id, name = name, password = password, sender = sender }
    if activeGroups[id] or pendingJoins[id] then
        answerInvite(invite, "member")
        return
    end
    local declinedAt = declinedInvites[getDeclineKey(invite)]
    if declinedAt and GetTime() - declinedAt < INVITE_REPEAT_SECONDS then
        answerInvite(invite, "declined")
        return
    end
    if shownInvite then
        local isSame = shownInvite.id == id and namesMatch(shownInvite.sender, sender)
        answerInvite(invite, isSame and "shown" or "busy")
        return
    end

    shownInvite = invite
    answerInvite(invite, "shown")
    PlaySound(SOUNDKIT.TELL_MESSAGE)
    notifyChange("invite")
    -- Left unanswered, it goes away without telling the inviter.
    C_Timer.After(INVITE_SECONDS, function()
        if shownInvite == invite then
            shownInvite = nil
            notifyChange("invite")
        end
    end)
end

local function receiveInviteReply(id, sender, answer)
    local invite, index = findSentInvite(id, sender)
    if not invite then return end

    invite.answered = true
    if answer == "shown" then return end
    table.remove(sentInvites, index)
    if answer == "declined" then
        showNotice(invite.name .. " declined the invite to " .. invite.groupName .. ".")
    elseif answer == "member" then
        showNotice(invite.name .. " is already in " .. invite.groupName .. ".")
    elseif answer == "busy" then
        showNotice(invite.name .. " has another invite open. Try again in a moment.")
    end
end

local function defineConfirmDialogs()
    if StaticPopupDialogs.TRIALCHAT_CONFIRM_DISCONNECT then return end

    StaticPopupDialogs.TRIALCHAT_CONFIRM_DISCONNECT = {
        text = "Disconnect from group %s? It will remain in your saved groups.",
        button1 = YES,
        button2 = NO,
        OnAccept = function(self)
            disconnectGroup(self.data)
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    StaticPopupDialogs.TRIALCHAT_CONFIRM_EXIT = {
        text = "Exit group %s and remove it from your saved groups?",
        button1 = YES,
        button2 = NO,
        OnAccept = function(self)
            exitGroup(self.data)
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
    StaticPopupDialogs.TRIALCHAT_CONFIRM_DELETE = {
        text = "Permanently delete group %s? Online members will be notified.",
        button1 = YES,
        button2 = NO,
        OnAccept = function(self)
            deleteGroup(self.data)
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

Groups.MAX_MESSAGE_BYTES = MAX_GROUP_MESSAGE_BYTES
Groups.MAX_HISTORY = MAX_CHAT_HISTORY
Groups.MAX_NAME_BYTES = MAX_GROUP_NAME_BYTES
Groups.MAX_PASSWORD_BYTES = MAX_PASSWORD_BYTES

-- The handler is called as handler(kind, groupId, ...) where kind is "groups"
-- (a group connected, went away, or started or stopped connecting), "open"
-- (show this group: you created or joined it, or asked for it again),
-- "members", "unread", "history" (a history load started, progressed or
-- finished), "look" (a member's race or gender came in), "invite" (an
-- invite came in or went away; see GetInvite), or "message" (followed by
-- the history entry and whether it was appended at the end).
function Groups:SetChangeHandler(handler)
    changeHandler = handler
end

local function isValidSavedGroup(group)
    return type(group) == "table" and type(group.name) == "string"
        and type(group.password) == "string"
end

local function countMembers(session)
    local count = 0
    for _ in pairs(session.members) do
        count = count + 1
    end
    return count
end

-- Every group you're in or have saved, sorted by name. state is "online"
-- (connected), "connecting", or "offline" (saved, not connected).
function Groups:GetConversations()
    local conversations = {}
    local function add(id, name, state, session, savedGroup)
        conversations[#conversations + 1] = {
            id = id,
            name = name,
            state = state,
            unread = session and getUnreadCount(session) or 0,
            online = session and countMembers(session) or 0,
            icon = (session and session.icon) or (savedGroup and savedGroup.icon),
            muted = (session and session.muted or savedGroup and savedGroup.muted) == true,
        }
    end

    local savedGroups = getSavedGroups()
    for id, session in pairs(activeGroups) do
        add(id, session.name, "online", session)
    end
    for id, session in pairs(pendingJoins) do
        if not activeGroups[id] then
            add(id, session.name, "connecting", nil, savedGroups[id])
        end
    end
    for id, group in pairs(savedGroups) do
        if not activeGroups[id] and not pendingJoins[id] and isValidSavedGroup(group) then
            add(id, group.name, "offline", nil, group)
        end
    end
    table.sort(conversations, function(left, right)
        return strlower(left.name) < strlower(right.name)
    end)
    return conversations
end

-- Connects to a saved group, or shows it if it's already connected.
function Groups:Connect(id)
    local active = activeGroups[id]
    if active then
        showSession(active)
        return
    end
    local group = getSavedGroups()[id]
    if pendingJoins[id] or not isValidSavedGroup(group) then return end

    if #getJoinCandidates(group) > 0 then
        joinGroup(group.name, group.password, group.memberName, group)
    else
        createGroup(group.name, group.password, group)
    end
end

function Groups:GetInfo(id)
    local session = activeGroups[id]
    if not session then return nil end

    local online, offline = Groups:GetMemberList(id)
    return {
        name = session.name,
        online = #online,
        members = #online + #offline,
        icon = session.icon,
        muted = session.muted == true,
        loadingHistory = session.historyLoad ~= nil,
        loadedHistory = session.historyLoad and session.historyLoad.added or 0,
        isCreator = session.isCreator == true,
    }
end

function Groups:IsCreator(id)
    local session = activeGroups[id]
    if session then
        if session.isCreator == true then return true end
        -- Fall back to the creator name (e.g. a rejoin that didn't carry the
        -- flag) so the creator is still recognised as the admin.
        return session.creatorName ~= nil
            and namesMatch(session.creatorName, selfName)
    end
    return savedGroupIsCreator(getSavedGroups()[id])
end

local function sortMembers(members)
    table.sort(members, function(left, right)
        if left.isSelf ~= right.isSelf then return left.isSelf == true end
        return strlower(left.fullName) < strlower(right.fullName)
    end)
end

-- Members that are online and the known members that aren't, each a list
-- of { fullName, classFile, isSelf } with you first.
function Groups:GetMemberList(id)
    local session = activeGroups[id]
    local online, offline = {}, {}
    if not session then return online, offline end

    for _, member in pairs(session.members) do
        online[#online + 1] = {
            fullName = member.name,
            classFile = member.classFile or TrialChatCommon.GetKnownClass(member.name),
            isSelf = isSelf(member.name),
        }
    end
    for _, name in pairs(session.knownMembers or {}) do
        if not isSelf(name) and not findMemberKey(session, name) then
            -- A name typed without its realm and the same name with it
            -- are one member; keep the one with the realm.
            local known
            for _, member in ipairs(offline) do
                if namesMatch(member.fullName, name) then
                    known = member
                    break
                end
            end
            if not known then
                offline[#offline + 1] = {
                    fullName = name,
                    classFile = TrialChatCommon.GetKnownClass(name),
                }
            elseif not string.find(known.fullName, "-", 1, true) then
                known.fullName = name
                known.classFile = known.classFile or TrialChatCommon.GetKnownClass(name)
            end
        end
    end
    sortMembers(online)
    sortMembers(offline)
    return online, offline
end

function Groups:ClearLeftMember(id, name)
    clearLeftMember(id, name)
end

-- Returns and clears the list of members who left while others were offline,
-- so the creator can be told once when they next look at the group.
function Groups:ConsumeLeftNotices(id)
    local left = leftMembers[id]
    if not left then return {} end
    local result = {}
    for _, info in pairs(left) do
        result[#result + 1] = info.name
    end
    table.sort(result, function(a, b)
        return normalizeName(a) < normalizeName(b)
    end)
    leftMembers[id] = nil
    persistLeftMembers(id)
    return result
end

function Groups:GetHistory(id)
    local session = activeGroups[id]
    return session and session.history or {}
end

function Groups:GetTotalUnreadCount()
    local count = 0
    for _, session in pairs(activeGroups) do
        count = count + getUnreadCount(session)
    end
    return count
end

function Groups:SetViewedGroup(id)
    viewedGroupId = id
    local session = id and activeGroups[id]
    if session then
        markGroupRead(session)
        notifyChange("unread", id)
    end
end

function Groups:SendMessage(id, message, reply)
    local session = activeGroups[id]
    if session then
        sendGroupMessage(session, message, reply)
    end
end

function Groups:SetMuted(id, muted)
    local session = activeGroups[id]
    local savedGroup = getSavedGroups()[id]
    if session then
        session.muted = muted == true
        persistGroup(session)
    elseif type(savedGroup) == "table" then
        savedGroup.muted = muted == true
    end
    notifyChange("groups", id)
end

-- The group's icon, from the live session or the saved group.
function Groups:GetIcon(id)
    local session = activeGroups[id]
    if session then return session.icon end
    local savedGroup = getSavedGroups()[id]
    return type(savedGroup) == "table" and savedGroup.icon or nil
end

-- Sets the group's icon. Only the creator owns it; members receive it over
-- the group protocol. A nil icon clears it, back to the group's initials.
function Groups:SetIcon(id, icon)
    local session = activeGroups[id]
    if session then
        if not session.isCreator then return end
        session.icon = icon
        persistGroup(session)
        if icon then
            sendToMembers(session, "ICON", icon)
        end
    else
        local savedGroup = getSavedGroups()[id]
        if type(savedGroup) ~= "table" or not savedGroupIsCreator(savedGroup) then return end
        savedGroup.icon = icon
    end
    notifyChange("groups", id)
end

function Groups:LoadHistory(id)
    local session = activeGroups[id]
    if session then
        startHistoryLoad(session)
    end
end

-- mode is "create" or "join".
function Groups:ShowDialog(mode)
    openGroupDialog(mode)
end

-- action is "disconnect", "exit" or "delete"; each asks for confirmation.
function Groups:Confirm(action, id)
    local session = activeGroups[id]
    local savedGroup = getSavedGroups()[id]
    local name = session and session.name or (type(savedGroup) == "table" and savedGroup.name)
    if not name then return end

    defineConfirmDialogs()
    if action == "disconnect" then
        StaticPopup_Show("TRIALCHAT_CONFIRM_DISCONNECT", name, nil, id)
    elseif action == "exit" then
        StaticPopup_Show("TRIALCHAT_CONFIRM_EXIT", name, nil, id)
    elseif action == "delete" then
        StaticPopup_Show("TRIALCHAT_CONFIRM_DELETE", name, nil, id)
    end
end

-- Invites a player to a connected group; what they answer is printed.
function Groups:Invite(id, name)
    local session = activeGroups[id]
    if not session then return end
    name = strtrim(name or "")
    if name == "" or #name > 64 or string.find(name, "[%c|]") then
        showNotice("Enter the name of the character to invite.")
        return
    end
    if isSelf(name) or isMember(session, name) then
        showNotice((isSelf(name) and "You're" or (name .. " is"))
            .. " already in " .. session.name .. ".")
        return
    end

    -- Inviting someone clears any earlier removal, so they can join again.
    if session.banned and next(session.banned) ~= nil then
        unban(session, name)
        if saveGroup then saveGroup(session) end
    end

    local _, index = findSentInvite(id, name)
    if index then
        table.remove(sentInvites, index)
    end
    if not sendGroupProtocol(session, "INVITE", name,
        session.name .. ":" .. session.password) then
        return
    end
    local invite = { id = id, name = name, groupName = session.name }
    sentInvites[#sentInvites + 1] = invite
    showNotice("Invited " .. name .. " to " .. session.name .. ".")
    C_Timer.After(INVITE_ANSWER_SECONDS, function()
        local current, currentIndex = findSentInvite(id, name)
        if current ~= invite or invite.answered then return end
        table.remove(sentInvites, currentIndex)
        showNotice(name .. " didn't answer the invite. They need TrialChat to get invites.")
    end)
    -- A shown invite can be declined until it goes away.
    C_Timer.After(INVITE_ANSWER_SECONDS + INVITE_SECONDS, function()
        local current, currentIndex = findSentInvite(id, name)
        if current == invite then
            table.remove(sentInvites, currentIndex)
        end
    end)
end

-- Asks for the name of a player to invite to a connected group.
function Groups:ShowInviteDialog(id)
    local session = activeGroups[id]
    if not session then return end
    defineInviteDialog()
    StaticPopup_Show("TRIALCHAT_INVITE_PLAYER", session.name, nil, id)
end

-- Removes a member from a connected group (creator only), whether they are
-- online or just a known offline member. Tells everyone, then removes them
-- locally.
function Groups:Kick(id, name)
    local session = activeGroups[id]
    if not session then return end
    if not Groups:IsCreator(id) then
        showNotice("Only the group creator can remove members.")
        return
    end
    name = strtrim(name or "")
    if name == "" or isSelf(name) then return end
    if not isMember(session, name) then
        showNotice(name .. " is not in " .. session.name .. ".")
        return
    end
    addBanned(session, name)
    sendToMembers(session, "BAN", name)
    removeMember(session, name, "kicked")
    if saveGroup then saveGroup(session) end
    showNotice("Removed " .. name .. " from " .. session.name .. ".")
end

-- The invite waiting for your answer, as { groupName, inviter } (the
-- inviter's name to show), or nil.
function Groups:GetInvite()
    if not shownInvite then return nil end
    return {
        groupName = shownInvite.name,
        inviter = getInviterText(shownInvite.sender),
    }
end

-- Joins the group you're invited to (true) or declines the invite.
function Groups:AnswerInvite(join)
    local invite = shownInvite
    if not invite then return end
    shownInvite = nil
    notifyChange("invite")
    if join then
        local savedGroup = getSavedGroups()[invite.id]
        joinGroup(invite.name, invite.password, invite.sender,
            type(savedGroup) == "table" and savedGroup or nil)
    else
        declinedInvites[getDeclineKey(invite)] = GetTime()
        answerInvite(invite, "declined")
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
eventFrame:RegisterEvent("PLAYER_LOGIN")
local autoJoinStarted = false
local function autoJoinSavedGroups()
    if autoJoinStarted then return end
    autoJoinStarted = true

    local savedGroups = getSavedGroups()
    local groups = {}
    for id, group in pairs(savedGroups) do
        if type(group) == "table" and type(group.name) == "string"
            and type(group.password) == "string" then
            groups[#groups + 1] = { id = id, group = group }
        end
    end
    table.sort(groups, function(left, right)
        return strlower(left.group.name) < strlower(right.group.name)
    end)

    for _, entry in ipairs(groups) do
        local id = entry.id
        local group = entry.group
        if not activeGroups[id] and not pendingJoins[id] then
            local candidates = getJoinCandidates(group, group.memberName)
            if #candidates > 0 then
                joinGroup(group.name, group.password, group.memberName,
                    group, true)
            elseif savedGroupIsCreator(group) then
                createGroup(group.name, group.password, group, true)
            else
                showNotice("Could not automatically join " .. group.name
                    .. ": no saved group members are available to connect through.")
            end
        end
    end
end

eventFrame:SetScript("OnEvent", function(_, event, prefix, message, distribution, sender)
    if event == "PLAYER_LOGIN" then
        refreshIdentity()
        autoJoinSavedGroups()
        return
    end

    if event == "PLAYER_LOGOUT" then
        flushGroupSaves()
        for _, session in pairs(activeGroups) do
            sendToMembers(session, "BYE")
        end
        return
    end

    if prefix ~= PREFIX or distribution ~= "WHISPER" or not message or not sender
        or string.sub(message, 1, #GROUP_TAG) ~= GROUP_TAG then
        return
    end

    local kind, id, body = string.match(
        message, "^TCG1|([^|]+)|([^|]+)|(.*)$")
    if not id or not kind then return end

    local session = activeGroups[id]
    local pending = pendingJoins[id]
    if isSelf(sender) then return end

    if kind == "INVITE" then
        receiveInvite(id, sender, body)
        return
    end

    if kind == "INVITEREPLY" then
        receiveInviteReply(id, sender, body)
        return
    end

    if kind == "HELLO" then
        -- Someone the creator removed can't just reconnect and rejoin.
        if session and body == session.password and not isBanned(session, sender) then
            addMember(session, sender)
            sendGroupProtocol(session, "WELCOME", sender,
                session.creatorName or (session.isCreator and selfName) or "")
            sendGroupProtocol(session, "CLASS", sender, playerClass)
            if session.icon then
                sendGroupProtocol(session, "ICON", sender, session.icon)
            end
            for key, member in pairs(session.members) do
                if not namesMatch(member.name, selfName or UnitName("player"))
                    and not namesMatch(member.name, sender) then
                    -- Only the member list: a CLASS message is always read as
                    -- the sender's own class, and members announce theirs.
                    sendGroupProtocol(session, "MEMBER", sender, member.name)
                end
            end
            for _, memberName in pairs(session.knownMembers or {}) do
                sendGroupProtocol(session, "KNOWN", sender, memberName)
            end
            -- Share the removed-member list so the newcomer rejects them too.
            for _, bannedName in pairs(session.banned or {}) do
                sendGroupProtocol(session, "BAN", sender, bannedName)
            end
            sendToMembers(session, "MEMBER", sender)
            if playerClass then
                sendToMembers(session, "CLASS", playerClass, sender)
            end
            sendHistoryToMember(session, sender)
        end
        return
    end

    if kind == "WELCOME" then
        if pending and isJoinCandidate(pending, sender) then
            if body ~= "" then
                pending.creatorName = body
                pending.isCreator = namesMatch(body, selfName)
            end
            completePendingJoin(pending, sender)
        end
        return
    end

    if kind == "MEMBER" then
        if session and hasMember(session, sender) then
            addMember(session, body)
        elseif pending and isJoinCandidate(pending, sender) then
            if body ~= "" then
                addMember(pending, body)
            end
            completePendingJoin(pending, sender)
        end
        return
    end

    if kind == "KNOWN" then
        if session and hasMember(session, sender) then
            addKnownMember(session, body)
            if saveGroup then saveGroup(session) end
        elseif pending and isJoinCandidate(pending, sender) then
            addKnownMember(pending, body)
        end
        return
    end

    if kind == "CLASS" then
        if session and hasMember(session, sender)
            and RAID_CLASS_COLORS[body] then
            local memberKey = findMemberKey(session, sender)
            local member = memberKey and session.members[memberKey]
            if member then
                member.classFile = body
                TrialChatCommon.RememberClass(member.name, body, true)
                notifyChange("members", id)
            end
        end
        return
    end

    -- The group's icon, chosen by its creator and passed on like the name.
    -- Members only relay it; the creator owns it and rebroadcasts changes.
    if kind == "ICON" then
        if body ~= "" and #body <= 128 and not string.find(body, "[|%c]") then
            if session and hasMember(session, sender) then
                if session.icon ~= body then
                    session.icon = body
                    if saveGroup then saveGroup(session) end
                    notifyChange("groups", id)
                end
            elseif pending and isJoinCandidate(pending, sender) then
                pending.icon = body
            end
        end
        return
    end

    -- Race and gender, for the avatar of members the game can't draw.
    if kind == "LOOK" then
        if session and hasMember(session, sender) then
            local raceFile, sex = string.match(body, "^(%a+):([23])$")
            local oldRace, oldSex = TrialChatCommon.GetKnownLook(sender)
            TrialChatCommon.RememberLook(sender, raceFile, sex, true)
            if raceFile and (raceFile ~= oldRace or tonumber(sex) ~= oldSex) then
                notifyChange("look", id)
            end
        end
        return
    end

    if kind == "BYE" then
        if session and hasMember(session, sender) then
            removeMember(session, sender)
        end
        return
    end

    -- A removed member: remembered so they can't rejoin, and dropped from the
    -- member list. Members relay it (like ICON) so everyone knows.
    if kind == "BAN" then
        local target = body
        if target and target ~= "" then
            if session then
                local savedGroup = getSavedGroups()[id]
                local creatorName = session.creatorName
                    or (savedGroup and savedGroup.creatorName)
                local fromCreator = creatorName and namesMatch(sender, creatorName)
                if (fromCreator or hasMember(session, sender))
                    and not (creatorName and namesMatch(target, creatorName)) then
                    if namesMatch(target, selfName or UnitName("player")) then
                        -- You were removed
                        showNotice("You were removed from " .. session.name .. ".")
                        disconnectSession(id)
                        pendingJoins[id] = nil
                        pendingGroupSaves[id] = nil
                        getSavedGroups()[id] = nil
                        notifyChange("groups", id)
                        return
                    end
                    addBanned(session, target)
                    removeMember(session, target, "kicked")
                    if saveGroup then saveGroup(session) end
                    notifyChange("groups", id)
                end
            elseif pending and isJoinCandidate(pending, sender)
                and not (pending.creatorName and namesMatch(target, pending.creatorName)) then
                addBanned(pending, target)
            end
        end
        return
    end

    if kind == "DELETE" then
        local savedGroup = getSavedGroups()[id]
        local creatorName = session and session.creatorName
            or (savedGroup and savedGroup.creatorName)
        if creatorName and namesMatch(sender, creatorName) then
            if session then
                session.members = {}
            end
            activeGroups[id] = nil
            pendingJoins[id] = nil
            pendingGroupSaves[id] = nil
            getSavedGroups()[id] = nil
            notifyChange("groups", id)
            showNotice("The creator deleted " .. (session and session.name
                or (savedGroup and savedGroup.name) or id) .. ".")
        end
        return
    end

    if kind == "PART" and session and hasMember(session, sender) then
        local messageId, index, count, chunk =
            string.match(body, "^([%x%-]+):(%d+):(%d+):(.*)$")
        body = groupParts:Add(id .. "\0" .. normalizeName(sender),
            messageId, tonumber(index), tonumber(count), chunk)
        if not body then return end
        kind = "MSG2"
    end

    -- A sound emote someone in the group triggered: only its name travels,
    -- and each member plays their own copy of the same file. No chat line
    -- goes with it for a sound-only emote, so it is heard but not shown.
    if kind == "SOUND" and session and hasMember(session, sender) then
        TrialChatCommon.PlayReceivedSoundEmote(sender, body)
        return
    end

    if (kind == "MSG2" or kind == "EMOTE2")
        and session and hasMember(session, sender) then
        -- Kept encoded: the reply prefix's separators only read as
        -- separators before decoding.
        local messageId, timestamp, emoteFlag, encodedText =
            string.match(body, "^([%x%-]+):(%d+):([ME]):(.*)$")
        timestamp = tonumber(timestamp)
        if messageId and timestamp then
            local reply
            reply, encodedText = TrialChatCommon.SplitReplyPrefix(encodedText)
            local text = TrialChatCommon.DecodeMessageMarkup(encodedText)
            local added, entry = addGroupMessage(session, sender, text,
                emoteFlag == "E", messageId, timestamp, false, true, reply)
            if added and emoteFlag ~= "E" then
                TrialChatBubbles.ShowMessage(sender, entry.message, session.name)
            end
        end
        return
    end

    if (kind == "MSG" or kind == "EMOTE")
        and session and hasMember(session, sender) then
        local decodedBody = TrialChatCommon.DecodeMessageMarkup(body)
        local added, entry = addGroupMessage(session, sender, decodedBody,
            kind == "EMOTE", nil, nil, false, true)
        if added and kind == "MSG" then
            TrialChatBubbles.ShowMessage(sender, entry.message, session.name)
        end
        return
    end

    if kind == "HIST" then
        if session and hasMember(session, sender) then
            local added, entry = receiveHistoryChunk(session, sender, body)
            local load = session.historyLoad
            if load and namesMatch(load.source, sender) then
                load.lastActivity = GetTime()
                if added then
                    -- Messages you asked for aren't unread.
                    entry.read = true
                    load.added = load.added + 1
                    notifyHistoryProgress(session)
                end
            end
        elseif pending and isJoinCandidate(pending, sender) then
            receiveHistoryChunk(pending, sender, body)
        end
        return
    end

    if kind == "HISTREQ" then
        if session and hasMember(session, sender) then
            sendHistoryPage(session, sender, body)
        end
        return
    end

    if kind == "HISTEND" then
        if session and hasMember(session, sender) then
            receiveHistoryPageEnd(session, sender, body)
        end
        return
    end
end)

if IsLoggedIn() then
    C_Timer.After(1, function()
        refreshIdentity()
        autoJoinSavedGroups()
    end)
end

C_Timer.NewTicker(GROUP_SAVE_INTERVAL, flushGroupSaves)

C_Timer.NewTicker(MEMBER_UPDATE_INTERVAL, function()
    local now = GetTime()
    for _, session in pairs(activeGroups) do
        addMember(session, selfName or UnitName("player"))
        sendToMembers(session, "MEMBER", selfName or UnitName("player"))
        if playerClass then
            sendToMembers(session, "CLASS", playerClass)
        end
        if getOwnLook() then
            sendToMembers(session, "LOOK", getOwnLook())
        end
        -- The creator owns the group's icon, so only it rebroadcasts it.
        if session.isCreator and session.icon then
            sendToMembers(session, "ICON", session.icon)
        end

        local expired = {}
        for key, member in pairs(session.members) do
            if not namesMatch(member.name, selfName or UnitName("player"))
                and now - member.lastSeen > MEMBER_TIMEOUT then
                expired[#expired + 1] = key
            end
        end
        for _, key in ipairs(expired) do
            local member = session.members[key]
            if member then
                removeMember(session, member.name, "timeout")
            end
        end
    end
end)

-- "Invite to TrialChat group" and "Remove from TrialChat group" in the game's
-- right-click menus for players (unit frames, chat names, friends, guild and
-- community lists), listing the groups you're connected to. TrialChat's own
-- member list builds its own menu with the same entries.
local PLAYER_MENUS = {
    "PLAYER", "PARTY", "RAID_PLAYER", "RAID", "FOCUS", "FRIEND", "GUILD",
    "CHAT_ROSTER", "COMMUNITIES_WOW_MEMBER", "COMMUNITIES_GUILD_MEMBER",
}

local function getMenuPlayerName(contextData)
    if type(contextData) ~= "table" or contextData.bnetIDAccount
        or contextData.isMobile then
        return nil
    end
    local unit = contextData.unit
    if unit then
        local isPlayer = UnitIsPlayer(unit)
        if TrialChatCommon.IsSecret(isPlayer) or not isPlayer then return nil end
        return TrialChatCommon.GetUnitFullName(unit)
    end
    local name, server = contextData.name, contextData.server
    if type(name) ~= "string" or name == "" or TrialChatCommon.IsSecret(name, server) then
        return nil
    end
    if type(server) == "string" and server ~= "" then
        return name .. "-" .. server
    end
    return name
end

-- Adds the "Invite to TrialChat group" and (for a group you created, when the
-- player is a member) "Remove from TrialChat group" submenus to a player menu.
-- Shared by the game's player menus and TrialChat's own member list.
function Groups:AddPlayerMenu(rootDescription, name)
    if not rootDescription or not name or isSelf(name) then return end

    local sessions = {}
    local kickableSessions = {}
    for _, session in pairs(activeGroups) do
        sessions[#sessions + 1] = session
        if Groups:IsCreator(session.id) and isMember(session, name) then
            kickableSessions[#kickableSessions + 1] = session
        end
    end
    if #sessions == 0 and #kickableSessions == 0 then return end
    table.sort(sessions, function(left, right)
        return strlower(left.name) < strlower(right.name)
    end)
    table.sort(kickableSessions, function(left, right)
        return strlower(left.name) < strlower(right.name)
    end)

    if #sessions > 0 then
        rootDescription:CreateDivider()
        local inviteButton = rootDescription:CreateButton("Invite to TrialChat group")
        for _, session in ipairs(sessions) do
            local id = session.id
            local groupButton = inviteButton:CreateButton(session.name, function()
                Groups:Invite(id, name)
            end)
            -- Greyed out for groups they're already in.
            if isMember(session, name) then
                groupButton:SetEnabled(false)
            end
        end
    end

    if #kickableSessions > 0 then
        rootDescription:CreateDivider()
        local removeButton = rootDescription:CreateButton("Remove from TrialChat group")
        for _, session in ipairs(kickableSessions) do
            local id = session.id
            removeButton:CreateButton(session.name, function()
                Groups:Kick(id, name)
            end)
        end
    end
end

local function addInviteMenu(_, rootDescription, contextData)
    local name = getMenuPlayerName(contextData)
    if not name then return end
    if TrialChatWhispers then
        TrialChatWhispers:AddPlayerMenu(rootDescription, name)
    end
    Groups:AddPlayerMenu(rootDescription, name)
end

if Menu and Menu.ModifyMenu then
    for _, which in ipairs(PLAYER_MENUS) do
        Menu.ModifyMenu("MENU_UNIT_" .. which, addInviteMenu)
    end
end
