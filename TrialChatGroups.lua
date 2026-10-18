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

-- Which saved groups this character has chosen to join or not. The groups
-- themselves are account-wide (TrialChatDB.groups), but whether a character
-- is in one is theirs alone, kept in the per-character saved variable.
local function getCharacterGroupState()
    local characterDB = TrialChatCommon.GetCharacterDB()
    local state = characterDB.groups
    if type(state) ~= "table" then
        state = {}
        characterDB.groups = state
    end
    state.accepted = state.accepted or {}
    state.declined = state.declined or {}
    return state
end

-- What to do with a saved group when this character logs in: "join" (they're
-- in it, or asked to be), "hidden" (they said no), or "prompt" (ask them).
local function savedGroupMode(id, group)
    local state = getCharacterGroupState()
    if state.declined[id] then return "hidden" end
    if state.accepted[id] or savedGroupIsCreator(group) then return "join" end
    return "prompt"
end

-- Records that this character is in a group, so it reconnects next login
-- and stops being offered to join.
local function markGroupAccepted(id)
    if not id then return end
    local state = getCharacterGroupState()
    state.declined[id] = nil
    state.accepted[id] = true
end

local function markGroupDeclined(id)
    if not id then return end
    local state = getCharacterGroupState()
    state.accepted[id] = nil
    state.declined[id] = true
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
-- a UI reload before the creator next opens the group. They're saved under a
-- key of their own: older versions recorded a disconnect or a timeout here
-- too, and those records aren't leaves, so they're left behind unread.
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
    saved.leftNotices = #list > 0 and list or nil
end

local function restoreLeftMembers(id, savedGroup)
    if type(savedGroup) ~= "table" or type(savedGroup.leftNotices) ~= "table" then
        return
    end
    leftMembers[id] = leftMembers[id] or {}
    for _, name in ipairs(savedGroup.leftNotices) do
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
    if session.greetedAt then session.greetedAt[normalizeName(name)] = nil end
    -- A member is only forgotten when they leave the group on purpose or are
    -- removed from it. Disconnecting, logging out or going quiet just takes
    -- them off the online list: they stay a member, offline and reachable
    -- again when they come back.
    local goneForGood = reason == "left" or reason == "kicked"
    if session.knownMembers and goneForGood then
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
    -- person. Only a member who actually left the group is recorded: a
    -- disconnect, a logout or a quiet timeout isn't leaving, and a kick isn't
    -- a voluntary leave either.
    if wasMember and reason == "left" and not isSelf(name) then
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
        TrialChatCommon.SendAddonWhisper, PREFIX, payload, target)
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

-- Your class, look and (as the creator) the group's icon go to each member
-- once when you meet them, and again every few minutes, rather than to
-- everyone with every heartbeat: in a big group that was most of the
-- traffic.
local GREETING_REFRESH_SECONDS = 300

local function greetMember(session, name)
    if not name or isSelf(name) then return end
    session.greetedAt = session.greetedAt or {}
    local key = normalizeName(name)
    local at = session.greetedAt[key]
    if at and GetTime() - at < GREETING_REFRESH_SECONDS then return end
    session.greetedAt[key] = GetTime()
    if playerClass then
        sendGroupProtocol(session, "CLASS", name, playerClass)
    end
    if getOwnLook() then
        sendGroupProtocol(session, "LOOK", name, getOwnLook())
    end
    if session.isCreator and session.icon then
        sendGroupProtocol(session, "ICON", name, session.icon)
    end
end

-- A hello says first which TrialChat this is and how far its history goes
-- ("CAPS"), so a member on this version answers with packed member lists and
-- only the history that's missing. Older versions ignore it and answer as
-- they always have. The member answering says the same about itself, so the
-- history going the other way is only what it's missing too.
local PROTOCOL_VERSION = 3
local CAPS_SECONDS = 60
local capsFrom = {}

local function getNewestTimestamp(session)
    local history = session.history or {}
    for index = #history, 1, -1 do
        local entry = history[index]
        if type(entry) == "table" and tonumber(entry.timestamp) then
            return tonumber(entry.timestamp)
        end
    end
    return 0
end

local function sendCaps(session, target)
    sendGroupProtocol(session, "CAPS", target,
        PROTOCOL_VERSION .. ":" .. getNewestTimestamp(session))
end

-- What a member told us before their hello (or their answer), if recent.
local function getCaps(id, name)
    local caps = capsFrom[id .. "\0" .. normalizeName(name)]
    if caps and GetTime() - caps.at <= CAPS_SECONDS then return caps end
end

---------------------------------------------------------------------------
-- Joining without sending the password
--
-- A hello used to carry the group's password to whoever you connected
-- through, so a name typed wrong, or someone posing as a member, got it.
-- Now the two sides prove to each other that they know it, without sending
-- it:
--   AUTH       the joiner asks to join, with a random number;
--   CHALLENGE  the member answers with a random number of its own;
--   PROOF      the joiner sends a fingerprint of both numbers made with the
--              password (an HMAC), which the member checks;
--   VOUCH      if it checks out, the member proves the same in return, and
--              lets them in (WELCOME and the rest, as before).
-- The joiner trusts nothing from a member until it has vouched. A
-- fingerprint can't be turned back into the password, though a short
-- password could still be guessed by trying many; a longer one holds up.
--
-- Members on older versions don't know this; they can still connect
-- through you, since their hello still carries the password, checked as
-- before. To connect through one of them, a member that doesn't answer the
-- request gets that old hello instead, but only if it already knows the
-- password: a member of your saved group, or the player who invited you. A
-- name you typed for a first connect never gets it.
---------------------------------------------------------------------------
local AUTH_SECONDS = 60
local challenges = {}
-- Requests, challenges and vouches go by character ("Alice" typed and
-- "Alice-Realm" heard back are the same player).
local characterKey = TrialChatCommon.NormalizeCharacterName
local nonceCounter = 0

local function newNonce()
    nonceCounter = nonceCounter + 1
    return string.sub(TrialChatHash.ToHex(TrialChatHash.SHA256(table.concat({
        tostring(GetTime()), tostring(GetServerTime()), tostring(math.random()),
        tostring(math.random(0, 2147483647)), tostring(nonceCounter),
        tostring(selfName), tostring(debugprofilestop and debugprofilestop() or 0),
    }, "|"))), 1, 32)
end

local function isNonce(text)
    return type(text) == "string" and #text == 32 and not string.find(text, "[^%x]")
end

local function getGroupKey(group)
    if group.authKeyFor ~= group.password then
        group.authKey = TrialChatHash.SHA256(
            "TrialChat|" .. group.id .. "|" .. (group.password or ""))
        group.authKeyFor = group.password
    end
    return group.authKey
end

-- label: "join" for the joiner's proof, "welcome" for the member's. name is
-- whoever makes it, so one side's proof can't be passed off as the other's.
local function makeProof(group, label, name, nonceX, nonceR)
    return TrialChatHash.ToHex(TrialChatHash.HMAC(getGroupKey(group), table.concat({
        label, group.id, TrialChatCommon.NormalizeCharacterName(name) or "",
        nonceX, nonceR,
    }, "|")))
end

-- A member the joiner may listen to: one it asked, that has vouched, or an
-- older version it sent the old hello to (see mayTellPassword).
local function hasVouched(group, name)
    local key = characterKey(name)
    local at = group.vouched and group.vouched[key]
        or group.oldHelloAt and group.oldHelloAt[key]
    return at ~= nil and GetTime() - at <= AUTH_SECONDS
end

-- How long a member gets to answer the new request before an older version
-- is assumed.
local OLD_VERSION_SECONDS = 1.5

-- Whether name already knows the password, so the old hello tells it
-- nothing new: someone who was in the group with you, or who invited you.
local function mayTellPassword(group, name)
    if group.passwordFrom and namesMatch(group.passwordFrom, name) then return true end
    if not group.knownMembers then return false end
    for _, knownName in pairs(group.knownMembers) do
        if namesMatch(knownName, name) then return true end
    end
    return false
end


-- Asks to join through target: the version note, then AUTH. The same random
-- number is kept for a little while, so a challenge to an earlier try of
-- the same hello still fits.
local function sayHello(session, target)
    session.auth = session.auth or {}
    local key = characterKey(target)
    local auth = session.auth[key]
    -- Asked before and never challenged: an older version, if anything.
    if auth and not auth.nonceR and GetTime() - auth.at >= OLD_VERSION_SECONDS
        and mayTellPassword(session, target) then
        session.oldHelloAt = session.oldHelloAt or {}
        session.oldHelloAt[key] = GetTime()
        sendGroupProtocol(session, "HELLO", target, session.password)
    end
    sendCaps(session, target)
    if not auth or GetTime() - auth.at > AUTH_SECONDS / 2 then
        auth = { nonceX = newNonce(), at = GetTime() }
        session.auth[key] = auth
    end
    return sendGroupProtocol(session, "AUTH", target, auth.nonceX)
end

-- Names, comma-separated, in as few messages as they fit in.
local function sendNameList(session, kind, target, names)
    local room = 255 - #GROUP_TAG - #kind - #session.id - 2
    local batch = ""
    for _, name in ipairs(names) do
        if batch ~= "" and #batch + 1 + #name > room then
            sendGroupProtocol(session, kind, target, batch)
            batch = ""
        end
        batch = batch == "" and name or (batch .. "," .. name)
    end
    if batch ~= "" then
        sendGroupProtocol(session, kind, target, batch)
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

-- since: the newest message they have (see CAPS), when they said; then only
-- messages from that moment on go, which for someone logging back in is
-- usually a handful instead of the newest 50.
sendHistoryToMember = function(session, target, since)
    local entries = {}
    for index = #session.history, 1, -1 do
        local item = session.history[index]
        if type(item) == "table" and since
            and (tonumber(item.timestamp) or 0) < since then
            break
        end
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
                and TrialChatCommon.CanHearSoundEmotes() then
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

-- Players the game said aren't online when TrialChat whispered them, by
-- character, with when. Connecting skips them for a while instead of waiting
-- on each in turn, and hearing from them clears it.
local OFFLINE_SKIP_SECONDS = 120
local offlineAt = {}

local function seemsOffline(name)
    local key = TrialChatCommon.NormalizeCharacterName(name)
    local at = key and offlineAt[key]
    return at ~= nil and GetTime() - at < OFFLINE_SKIP_SECONDS
end

local function isJoinCandidate(session, name)
    for _, candidate in ipairs(session.joinCandidates or {}) do
        if namesMatch(candidate, name) then return true end
    end
    return false
end

local function isTrustedCandidate(pending, name)
    return isJoinCandidate(pending, name) and hasVouched(pending, name)
end

-- Shows a group you just connected to or asked for in TrialChat.
local function showSession(session)
    notifyChange("open", session.id)
end

local function activateGroup(session)
    pendingJoins[session.id] = nil
    activeGroups[session.id] = session
    -- Connecting means this character is in the group, so it reconnects on
    -- its next login without being asked.
    markGroupAccepted(session.id)
    session.members = session.members or {}
    addMember(session, selfName or UnitName("player"))
    persistGroup(session)
    notifyChange("groups", session.id)
    if not session.autoJoin then
        showSession(session)
    end
end

-- skipHistory: the history goes to them another way (answering their hello).
local function completePendingJoin(session, sender, skipHistory)
    addMember(session, sender)
    activateGroup(session)
    sendToMembers(session, "MEMBER", selfName or UnitName("player"))
    for _, member in pairs(session.members) do
        greetMember(session, member.name)
    end
    if not skipHistory then
        local caps = getCaps(session.id, sender)
        sendHistoryToMember(session, sender, caps and caps.newest)
    end
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

-- How long to wait on one member before asking the next, and how often to
-- say hello again meanwhile (a whisper can get lost). A member who isn't
-- online is skipped as soon as the game says so (see OnPlayerOffline below).
local JOIN_ATTEMPT_SECONDS = 6
local JOIN_RETRY_SECONDS = 2

-- Nobody answered. A saved group opens anyway, with just you in it, and keeps
-- looking for its members (see lookForMembers); at login that happens
-- quietly, while a connect you asked for says so.
local function finishJoinWithoutAnswer(session)
    local id = session.id
    pendingJoins[id] = nil
    notifyChange("groups", id)
    if session.isCreator or session.hasSavedGroup then
        if not session.autoJoin then
            showNotice("Nobody from " .. session.name .. " is online right now."
                .. " It's open, and you'll be connected when someone comes online.")
        end
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
        memberName = session.targetName,
        knownMembers = session.knownMembers,
    })
end

startJoinAttempt = function(session, candidateIndex)
    local id = session.id
    if pendingJoins[id] ~= session then return end
    while session.joinCandidates[candidateIndex]
        and seemsOffline(session.joinCandidates[candidateIndex]) do
        candidateIndex = candidateIndex + 1
    end
    local targetName = session.joinCandidates[candidateIndex]
    if not targetName then
        finishJoinWithoutAnswer(session)
        return
    end
    session.targetName = targetName
    session.candidateIndex = candidateIndex
    session.joinAttempt = (session.joinAttempt or 0) + 1
    local attempt = session.joinAttempt
    if not sayHello(session, targetName) then
        pendingJoins[id] = nil
        notifyChange("groups", id)
        return
    end

    local function stillWaiting()
        return pendingJoins[id] == session and session.joinAttempt == attempt
    end
    for retry = 1, math.floor((JOIN_ATTEMPT_SECONDS - 1) / JOIN_RETRY_SECONDS) do
        C_Timer.After(retry * JOIN_RETRY_SECONDS, function()
            if stillWaiting() then
                sayHello(session, targetName)
            end
        end)
    end
    C_Timer.After(JOIN_ATTEMPT_SECONDS, function()
        if stillWaiting() then
            startJoinAttempt(session, candidateIndex + 1)
        end
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

-- The game said a player TrialChat whispered isn't online. Connecting moves
-- on to the next member right away, and a member who dropped without saying
-- goodbye (a disconnect or a crash) shows offline now, instead of being
-- whispered until the heartbeat gives up on them.
TrialChatCommon.OnPlayerOffline(function(name)
    local key = TrialChatCommon.NormalizeCharacterName(name)
    if not key or isSelf(name) then return end
    offlineAt[key] = GetTime()
    local waiting = {}
    for _, session in pairs(pendingJoins) do
        if session.targetName and namesMatch(session.targetName, name) then
            waiting[#waiting + 1] = session
        end
    end
    for _, session in ipairs(waiting) do
        startJoinAttempt(session, (session.candidateIndex or 1) + 1)
    end
    for _, session in pairs(activeGroups) do
        if hasMember(session, name) then
            removeMember(session, name, "offline")
        end
    end
end)

-- A group open with nobody else in it (everyone was offline when it opened,
-- or two halves of it opened apart) keeps looking for its members: now and
-- then it says hello to a few saved members it hasn't seen offline lately,
-- less often the longer nobody answers. Whoever has the group open lets it
-- in (see WELCOME below), and the two join up.
local LOOK_FOR_MEMBERS_SECONDS = 30
local LOOK_FOR_MEMBERS_MAX_SECONDS = 300
local LOOK_FOR_MEMBERS_HELLOS = 3

local function isAlone(session)
    for _, member in pairs(session.members) do
        if not isSelf(member.name) then return false end
    end
    return true
end

local function lookForMembers(session)
    if not isAlone(session) then
        session.lookDelay, session.lookAt = nil, nil
        return
    end
    local now = GetTime()
    if session.lookAt and now < session.lookAt then return end
    session.lookDelay = math.min(LOOK_FOR_MEMBERS_MAX_SECONDS,
        session.lookDelay and session.lookDelay * 2 or LOOK_FOR_MEMBERS_SECONDS)
    session.lookAt = now + session.lookDelay

    local names = {}
    for _, name in pairs(session.knownMembers or {}) do
        if not isSelf(name) and not isBanned(session, name) then
            names[#names + 1] = name
        end
    end
    if #names == 0 then return end
    table.sort(names, function(left, right)
        return normalizeName(left) < normalizeName(right)
    end)
    local first = session.lookCursor or 0
    local sent = 0
    for step = 1, #names do
        local name = names[(first + step - 1) % #names + 1]
        if not seemsOffline(name) then
            sayHello(session, name)
            sent = sent + 1
            if sent == LOOK_FOR_MEMBERS_HELLOS then
                session.lookCursor = (first + step) % #names
                return
            end
        end
    end
    session.lookCursor = 0
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

local function disconnectSession(id, leaveGroup)
    local session = activeGroups[id]
    if not session then return nil end

    persistGroup(session)
    -- Members are told apart: a real leave says so, so they remove the player
    -- from the group; a plain disconnect only takes them offline.
    sendToMembers(session, leaveGroup and "LEAVE" or "BYE")
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

    local session = disconnectSession(id, true)
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
-- (connected), "connecting", or "offline" (saved, not connected). A saved
-- group this character hasn't joined carries prompt = true instead of a
-- member count, for the sidebar to ask whether to join it.
function Groups:GetConversations()
    local conversations = {}
    local function add(id, name, state, session, savedGroup, prompt)
        conversations[#conversations + 1] = {
            id = id,
            name = name,
            state = state,
            unread = session and getUnreadCount(session) or 0,
            online = session and countMembers(session) or 0,
            icon = (session and session.icon) or (savedGroup and savedGroup.icon),
            muted = (session and session.muted or savedGroup and savedGroup.muted) == true,
            prompt = prompt or nil,
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
            local mode = savedGroupMode(id, group)
            if mode ~= "hidden" then
                add(id, group.name, "offline", nil, group, mode == "prompt")
            end
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

-- The player's answer to a saved group's join prompt in the sidebar. Joining
-- connects to it; declining hides it from this character for good.
function Groups:AnswerPrompt(id, join)
    local group = getSavedGroups()[id]
    if not isValidSavedGroup(group) then return end
    if join then
        markGroupAccepted(id)
        Groups:Connect(id)
    else
        markGroupDeclined(id)
    end
    notifyChange("groups", id)
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

-- Whether a player is an online member of any group you're connected to.
function Groups:IsOnline(name)
    if not name or name == "" then return false end
    for _, session in pairs(activeGroups) do
        for _, member in pairs(session.members) do
            if namesMatch(member.name, name) then
                return true
            end
        end
    end
    return false
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
        -- They sent the password, so an older version of theirs may get
        -- the old hello (see mayTellPassword).
        if pendingJoins[invite.id] then
            pendingJoins[invite.id].passwordFrom = invite.sender
        end
    else
        declinedInvites[getDeclineKey(invite)] = GetTime()
        answerInvite(invite, "declined")
    end
end

-- Lets sender into the group: who the creator is, your class and look, the
-- member lists and the history they're missing. vouch, when they proved the
-- password, is your proof of it, sent first.
local function answerHello(session, id, sender, vouch)
    local caps = getCaps(id, sender)
    addMember(session, sender)
    if caps then
        sendCaps(session, sender)
    end
    if vouch then
        sendGroupProtocol(session, "VOUCH", sender, vouch)
    end
    sendGroupProtocol(session, "WELCOME", sender,
        session.creatorName or (session.isCreator and selfName) or "")
    greetMember(session, sender)
    -- Any member passes the icon on, so a newcomer has it even while the
    -- creator is away.
    if session.icon and not session.isCreator then
        sendGroupProtocol(session, "ICON", sender, session.icon)
    end
    -- Only the member list: a CLASS message is always read as the sender's
    -- own class, and members announce theirs.
    local others, known = {}, {}
    for _, member in pairs(session.members) do
        if not isSelf(member.name) and not namesMatch(member.name, sender) then
            others[#others + 1] = member.name
        end
    end
    for _, memberName in pairs(session.knownMembers or {}) do
        known[#known + 1] = memberName
    end
    if caps then
        sendNameList(session, "MEMBERS", sender, others)
        sendNameList(session, "KNOWNS", sender, known)
    else
        for _, memberName in ipairs(others) do
            sendGroupProtocol(session, "MEMBER", sender, memberName)
        end
        for _, memberName in ipairs(known) do
            sendGroupProtocol(session, "KNOWN", sender, memberName)
        end
    end
    -- Share the removed-member list so the newcomer rejects them too.
    for _, bannedName in pairs(session.banned or {}) do
        sendGroupProtocol(session, "BAN", sender, bannedName)
    end
    sendToMembers(session, "MEMBER", sender, sender)
    sendHistoryToMember(session, sender, caps and caps.newest)
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
        -- Groups this character isn't in wait to be accepted in the sidebar
        -- (Groups:AnswerPrompt); a refused group stays hidden.
        if not activeGroups[id] and not pendingJoins[id]
            and savedGroupMode(id, group) == "join" then
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
    -- Hearing from them means they're online (again).
    local senderKey = TrialChatCommon.NormalizeCharacterName(sender)
    if senderKey then offlineAt[senderKey] = nil end

    if kind == "INVITE" then
        receiveInvite(id, sender, body)
        return
    end

    if kind == "INVITEREPLY" then
        receiveInviteReply(id, sender, body)
        return
    end

    if kind == "CAPS" then
        local version, newest = string.match(body, "^(%d+):(%d+)$")
        -- Version 2 and up read packed lists and want only missing history.
        if version and tonumber(version) >= 2 then
            capsFrom[id .. "\0" .. normalizeName(sender)] = {
                newest = tonumber(newest), at = GetTime(),
            }
        end
        return
    end

    -- Joining without sending the password (see above). Someone asks: send
    -- them a challenge. Anyone may ask; nothing is given away by answering.
    if kind == "AUTH" then
        local group = session or pending
        if group and isNonce(body) and not isBanned(group, sender) then
            local nonceR = newNonce()
            challenges[id .. "\0" .. characterKey(sender)] = {
                nonceX = body, nonceR = nonceR, at = GetTime(),
            }
            sendGroupProtocol(group, "CHALLENGE", sender, nonceR)
        end
        return
    end

    -- The member you asked sent its challenge: prove you know the password.
    if kind == "CHALLENGE" then
        local group = pending or session
        local auth = group and group.auth and group.auth[characterKey(sender)]
        if auth and isNonce(body) and GetTime() - auth.at <= AUTH_SECONDS then
            auth.nonceR = body
            sendGroupProtocol(group, "PROOF", sender, makeProof(group, "join",
                selfName or UnitName("player"), auth.nonceX, body))
        end
        return
    end

    -- Their proof checks out: they're in. Two members logging in at the same
    -- moment each wait to be let in by the other; whoever is proved to first
    -- lets the other in, so they connect instead of each opening the group
    -- alone. Someone the creator removed can't just reconnect and rejoin.
    if kind == "PROOF" then
        local challengeKey = id .. "\0" .. characterKey(sender)
        local challenge = challenges[challengeKey]
        local group = session or pending
        if challenge and group and GetTime() - challenge.at <= AUTH_SECONDS
            and not isBanned(group, sender)
            and body == makeProof(group, "join", sender, challenge.nonceX, challenge.nonceR) then
            challenges[challengeKey] = nil
            if not session then
                completePendingJoin(pending, sender, true)
                session = activeGroups[id]
            end
            answerHello(session, id, sender, makeProof(session, "welcome",
                selfName or UnitName("player"), challenge.nonceX, challenge.nonceR))
        end
        return
    end

    -- The member you asked proved it knows the password too: from now on
    -- what it sends about the group counts.
    if kind == "VOUCH" then
        local group = pending or session
        local key = characterKey(sender)
        local auth = group and group.auth and group.auth[key]
        if auth and auth.nonceR
            and body == makeProof(group, "welcome", sender, auth.nonceX, auth.nonceR) then
            group.vouched = group.vouched or {}
            group.vouched[key] = GetTime()
        end
        return
    end

    -- Older versions still send the password in their hello, which is
    -- checked as before. This version never sends it.
    if kind == "HELLO" then
        if not session and pending and body == pending.password
            and not isBanned(pending, sender) then
            completePendingJoin(pending, sender, true)
            session = activeGroups[id]
        end
        if session and body == session.password and not isBanned(session, sender) then
            answerHello(session, id, sender)
        end
        return
    end

    if kind == "WELCOME" then
        if pending and isTrustedCandidate(pending, sender) then
            if body ~= "" then
                pending.creatorName = body
                pending.isCreator = namesMatch(body, selfName)
            end
            completePendingJoin(pending, sender)
        elseif session and not hasMember(session, sender) then
            -- An answer to looking for members, from a member that vouched
            -- (or an older version sent the old hello): the two join up.
            if hasVouched(session, sender) then
                local key = characterKey(sender)
                if session.vouched then session.vouched[key] = nil end
                if session.oldHelloAt then session.oldHelloAt[key] = nil end
                if body ~= "" and not session.creatorName then
                    session.creatorName = body
                end
                addMember(session, sender)
                sendGroupProtocol(session, "MEMBER", sender, selfName or UnitName("player"))
                greetMember(session, sender)
                local caps = getCaps(id, sender)
                sendHistoryToMember(session, sender, caps and caps.newest)
            end
        end
        return
    end

    if kind == "MEMBERS" or kind == "KNOWNS" then
        local names = {}
        for name in string.gmatch(body, "[^,]+") do names[#names + 1] = name end
        if session and hasMember(session, sender) then
            for _, name in ipairs(names) do
                if kind == "MEMBERS" then
                    local isNew = not hasMember(session, name)
                    addMember(session, name)
                    if isNew then greetMember(session, name) end
                else
                    addKnownMember(session, name)
                end
            end
            if kind == "KNOWNS" and saveGroup then saveGroup(session) end
        elseif pending and isTrustedCandidate(pending, sender) then
            for _, name in ipairs(names) do
                if kind == "MEMBERS" then
                    addMember(pending, name)
                else
                    addKnownMember(pending, name)
                end
            end
            if kind == "MEMBERS" then
                completePendingJoin(pending, sender)
            end
        end
        return
    end

    if kind == "MEMBER" then
        if session and hasMember(session, sender) then
            local isNew = not hasMember(session, body)
            addMember(session, body)
            if isNew then greetMember(session, body) end
        elseif session and namesMatch(body, sender) and isKnownMember(session, sender) then
            -- A known member's heartbeat: they're online, perhaps after
            -- showing offline when a whisper to them didn't get through.
            addMember(session, sender)
            greetMember(session, sender)
        elseif pending and isTrustedCandidate(pending, sender) then
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
        elseif pending and isTrustedCandidate(pending, sender) then
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
            elseif pending and isTrustedCandidate(pending, sender) then
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
        -- They disconnected or logged out: they stay a member, just offline.
        if session and hasMember(session, sender) then
            removeMember(session, sender, "offline")
        end
        return
    end

    if kind == "LEAVE" then
        -- They left the group on purpose: drop them and let the creator know.
        if session and hasMember(session, sender) then
            removeMember(session, sender, "left")
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
            elseif pending and isTrustedCandidate(pending, sender)
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
    -- The bell that mutes the group's message sound mutes these too; any
    -- text emote the sound came with still shows.
    if kind == "SOUND" and session and hasMember(session, sender) then
        if not session.muted then
            TrialChatCommon.PlayReceivedSoundEmote(sender, body)
        end
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
        elseif pending and isTrustedCandidate(pending, sender) then
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
        -- Class, look and icon only to whoever hasn't had them lately.
        for _, member in pairs(session.members) do
            greetMember(session, member.name)
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
        lookForMembers(session)
    end
    for key, challenge in pairs(challenges) do
        if now - challenge.at > AUTH_SECONDS then
            challenges[key] = nil
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
