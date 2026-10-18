local PREFIX = "TrialChat"
local MESSAGE_TAG = "M:"
local EMOTE_TAG = "E:"
local SOUND_TAG = "S:"
local PING = "C:PING"
local PONG = "C:PONG"
local CLASS_TAG = "C:CLASS:"
local MAX_MESSAGE_BYTES = 253
local MAX_CHAT_MESSAGE_BYTES = 1000
local PART_TAG = "P:"
local NEARBY_PART_BYTES = 230
local MAX_CHAT_HISTORY = 1000
local LISTENER_TIMEOUT = 35
local PING_INTERVAL = 30
local PING_BUDGET = 4
local LISTENER_CHANGE_DELAY = 0.2

if not C_ChatInfo.RegisterAddonMessagePrefix(PREFIX) then
    print("|cffff3333[TrialChat] Could not register the addon-message prefix.|r")
    return
end

-- Nearby chat: talking to TrialChat users around you (and the listeners
-- you keep), shown in the TrialChat window through this table.
TrialChatNearby = {}
local Nearby = TrialChatNearby

local activeListeners = {}
local incomingParts = TrialChatCommon.NewPartCollector()
local lastPingAt = {}
local pendingPings = {}
local pendingIncomingMessages = {}
local recentIncomingMessages = {}
local INCOMING_MESSAGE_DEDUP_SECONDS = 1
local playerName = TrialChatCommon.GetPlayerName()
local fullPlayerName = TrialChatCommon.GetPlayerFullName()
local playerRealm = TrialChatCommon.GetPlayerRealm()
local playerClass = TrialChatCommon.GetPlayerClass()
local classByName = {}
local minimapButton
local sendTrialChatMessage
local showTrialChatNotice
local slashOpenHooks = {}
local changeHandler
local listenerChangePending = false

local function notifyChange(kind, ...)
    if changeHandler then
        changeHandler(kind, ...)
    end
end

-- Pings and pongs come in bursts; tell the window about them once.
local function notifyListenersChanged()
    if listenerChangePending then return end
    listenerChangePending = true
    C_Timer.After(LISTENER_CHANGE_DELAY, function()
        listenerChangePending = false
        notifyChange("listeners")
    end)
end

-- Nearby history: entries of { sender, message, isEmote, timestamp }.
-- Older versions saved ready-made chat lines, which are kept as they are.
local function getChatHistory()
    TrialChatDB = TrialChatDB or {}
    if type(TrialChatDB.chatHistory) ~= "table" then
        TrialChatDB.chatHistory = {}
    end
    return TrialChatDB.chatHistory
end

local function saveChatHistoryEntry(entry)
    local history = getChatHistory()
    history[#history + 1] = entry
    local overflow = #history - MAX_CHAT_HISTORY
    if overflow <= 0 then return end

    local compacted = {}
    for index = overflow + 1, #history do
        compacted[#compacted + 1] = history[index]
    end
    TrialChatDB.chatHistory = compacted
end

local normalizeName = TrialChatCommon.NormalizeName
local normalizeCharacterName = TrialChatCommon.NormalizeCharacterName
local getShortName = TrialChatCommon.ShortName

local function noteActiveListener(name)
    if not name then return end
    local normalizedName = normalizeCharacterName(name)
    local listenerKey = name
    for existingName in pairs(activeListeners) do
        if normalizeCharacterName(existingName) == normalizedName then
            listenerKey = existingName
            break
        end
    end
    local isNew = activeListeners[listenerKey] == nil
    activeListeners[listenerKey] = GetTime()
    if isNew then
        notifyListenersChanged()
    end
end

local function getPermanentListeners()
    TrialChatDB = TrialChatDB or {}
    TrialChatDB.permanentListeners = TrialChatDB.permanentListeners or {}
    return TrialChatDB.permanentListeners
end

local function findPermanentListenerKey(name)
    local permanentListeners = getPermanentListeners()
    local nameKey = normalizeName(name)
    local shortName = string.match(name or "", "^([^-]+)")
    local shortKey = normalizeName(shortName)

    for key in pairs(permanentListeners) do
        local keyName = normalizeName(key)
        if keyName == nameKey then
            return key
        end
    end

    if shortKey then
        for key in pairs(permanentListeners) do
            local keyName = normalizeName(key)
            if not string.find(keyName, "-", 1, true) and keyName == shortKey then
                return key
            end
        end
    end
end

local function getFullName(unit)
    local name, realm = UnitFullName(unit)
    if not name then return nil end
    if realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

local function rememberClass(fullName, classFile, keep)
    if not fullName or not classFile or not RAID_CLASS_COLORS[classFile] then return end

    classByName[normalizeName(fullName)] = classFile
    local shortName = string.match(fullName, "^([^-]+)")
    if shortName then
        classByName[normalizeName(shortName)] = classFile
    end
    TrialChatCommon.RememberClass(fullName, classFile, keep)
end

-- Class, race and gender of a player the game can see right now.
local function rememberUnit(unit, fullName)
    local _, classFile = UnitClass(unit)
    rememberClass(fullName, classFile)
    TrialChatCommon.RememberUnitLook(unit, fullName)
end

local function getKnownClass(name)
    local shortName = string.match(name or "", "^([^-]+)")
    return classByName[normalizeName(name)]
        or shortName and classByName[normalizeName(shortName)]
        or TrialChatCommon.GetKnownClass(name)
end

local isSelf = TrialChatCommon.IsSelf

local function getGroupMembers()
    local members = {}
    local count = IsInRaid() and 40 or 4
    local unitPrefix = IsInRaid() and "raid" or "party"

    for index = 1, count do
        local unit = unitPrefix .. index
        local name = getFullName(unit)
        if name then
            members[normalizeCharacterName(name)] = name
            rememberUnit(unit, name)
        end
    end

    return members
end

local function addNearbyMessage(sender, message, isEmote, reply)
    local entry = {
        sender = sender,
        message = message,
        isEmote = isEmote or nil,
        timestamp = GetServerTime(),
        reply = reply,
    }
    saveChatHistoryEntry(entry)
    if changeHandler then
        notifyChange("message", entry)
    else
        print(getShortName(sender) .. (isEmote and " " or ": ") .. message)
    end
end

local function printIncomingMessage(label, sender, message, isEmote, reply)
    local key = normalizeCharacterName(sender) .. "\0" .. message
        .. "\0" .. tostring(isEmote)
        .. "\0" .. ((reply and reply.sender) or "")
    local now = GetTime()
    local pending = pendingIncomingMessages[key]
    local isGroupMessage = label == "Party" or label == "Raid"
    local isNearbyMessage = label == "Nearby"

    if pending then
        local isNewAudience = (isGroupMessage and not pending.groupLabel)
            or (isNearbyMessage and not pending.nearby)
        if isNewAudience and GetTime() - pending.receivedAt <= 0.2 then
            pending.groupLabel = isGroupMessage and label or pending.groupLabel
            pending.nearby = pending.nearby or isNearbyMessage
            pending.isEmote = isEmote
            return
        end

        if now - pending.receivedAt <= INCOMING_MESSAGE_DEDUP_SECONDS then
            return
        end

        if pendingIncomingMessages[key] == pending then
            pendingIncomingMessages[key] = nil
            addNearbyMessage(pending.sender, pending.message, pending.isEmote,
                pending.reply)
        end
    elseif recentIncomingMessages[key]
        and now - recentIncomingMessages[key].receivedAt
            <= INCOMING_MESSAGE_DEDUP_SECONDS then
        return
    end

    local recent = { receivedAt = now }
    recentIncomingMessages[key] = recent
    C_Timer.After(INCOMING_MESSAGE_DEDUP_SECONDS, function()
        if recentIncomingMessages[key] == recent then
            recentIncomingMessages[key] = nil
        end
    end)

    pending = {
        sender = sender,
        message = message,
        groupLabel = isGroupMessage and label or nil,
        nearby = isNearbyMessage,
        receivedAt = GetTime(),
        isEmote = isEmote,
        reply = reply,
    }
    pendingIncomingMessages[key] = pending

    C_Timer.After(0.2, function()
        if pendingIncomingMessages[key] == pending then
            pendingIncomingMessages[key] = nil
            addNearbyMessage(pending.sender, pending.message, pending.isEmote,
                pending.reply)
        end
    end)
end

showTrialChatNotice = function(message, isError)
    if changeHandler then
        notifyChange("notice", message, isError)
    else
        print("|cffff7d0a[TrialChat]|r " .. message)
    end
end

local function showMinimapTooltip(button)
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("TrialChat")
    GameTooltip:AddLine(
        TrialChatMessenger:IsShown() and "Click to hide TrialChat."
            or "Click to show TrialChat.",
        1, 1, 1)
    local unread = TrialChatGroups and TrialChatGroups:GetTotalUnreadCount() or 0
    if unread > 0 then
        GameTooltip:AddLine(unread .. " unread group message"
            .. (unread == 1 and "" or "s") .. ".", 1, 0.49, 0.04)
    end
    local whisperUnread = TrialChatWhispers
        and TrialChatWhispers:GetTotalUnreadCount() or 0
    if whisperUnread > 0 then
        GameTooltip:AddLine(whisperUnread .. " unread whisper"
            .. (whisperUnread == 1 and "" or "s") .. ".", 1, 0.49, 0.04)
    end
    TrialChatDB = TrialChatDB or {}
    if TrialChatDB.echoToSay then
        GameTooltip:AddLine("Echo to Say (/s): ON", 0, 1, 0)
    else
        GameTooltip:AddLine("Echo to Say (/s): OFF", 0.7, 0.7, 0.7)
    end
    if TrialChatDB.echoToParty then
        GameTooltip:AddLine("Echo to Party (/p): ON", 0, 1, 0)
    else
        GameTooltip:AddLine("Echo to Party (/p): OFF", 0.7, 0.7, 0.7)
    end
    GameTooltip:AddLine("Right-click for options.", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Drag to move this button.", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

local function hookSlashOpenShortcut()
    for index = 1, (NUM_CHAT_WINDOWS or 10) do
        local chatFrame = _G["ChatFrame" .. index]
        local editBox = chatFrame and chatFrame.editBox
        if editBox and not slashOpenHooks[editBox] then
            editBox:HookScript("OnTextChanged", function(self, userInput)
                if not userInput then return end

                local text = strlower(self:GetText() or "")
                if string.match(text, "^/tc%s+$")
                    or string.match(text, "^/trialchat%s+$") then
                    self:SetText("")
                    self:ClearFocus()
                    TrialChatMessenger:Open(true)
                end
            end)
            slashOpenHooks[editBox] = true
        end
    end
end

local function updateMinimapButtonPosition()
    if not minimapButton then return end

    local angle = math.rad(TrialChatDB.minimapAngle or 220)
    local radius = (Minimap:GetWidth() / 2) + 8
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(angle) * radius, math.sin(angle) * radius)
end

local function createMinimapButton()
    TrialChatDB = TrialChatDB or {}

    minimapButton = CreateFrame("Button", "TrialChatMinimapButton", Minimap)
    minimapButton:SetSize(31, 31)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(Minimap:GetFrameLevel() + 5)
    minimapButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    minimapButton:RegisterForDrag("LeftButton")

    minimapButton.icon = minimapButton:CreateTexture(nil, "ARTWORK")
    minimapButton.icon:SetSize(17, 17)
    minimapButton.icon:SetPoint("TOPLEFT", minimapButton, "TOPLEFT", 7, -6)
    minimapButton.icon:SetTexture("Interface\\AddOns\\TrialChat\\broke.tga")
    minimapButton.icon:SetTexCoord(0, 1, 0, 1)
    minimapButton:SetScript("OnEnter", showMinimapTooltip)

    local border = minimapButton:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", minimapButton, "TOPLEFT", 0, 0)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

    minimapButton:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "RightButton" then
            MenuUtil.CreateContextMenu(self, function(_, root)
                root:CreateTitle("TrialChat")
                root:CreateButton("Options", function()
                    TrialChatOptions:Toggle()
                end)
            end)
            return
        end
        TrialChatMessenger:Toggle()
        if GameTooltip:GetOwner() == self then
            showMinimapTooltip(self)
        end
    end)
    minimapButton:SetScript("OnLeave", GameTooltip_Hide)
    local function updateMinimapDragPosition(self)
        local centerX, centerY = Minimap:GetCenter()
        local cursorX, cursorY = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale()
        cursorX, cursorY = cursorX / scale, cursorY / scale
        local angle = math.atan2(cursorY - centerY, cursorX - centerX)
        local radius = (Minimap:GetWidth() / 2) + 8
        self:ClearAllPoints()
        self:SetPoint("CENTER", Minimap, "CENTER",
            math.cos(angle) * radius, math.sin(angle) * radius)
    end

    minimapButton:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", updateMinimapDragPosition)
    end)
    minimapButton:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)

        local centerX, centerY = Minimap:GetCenter()
        local buttonX, buttonY = self:GetCenter()
        TrialChatDB.minimapAngle = math.deg(math.atan2(buttonY - centerY, buttonX - centerX))
        updateMinimapButtonPosition()
    end)

    minimapButton:SetMovable(true)
    minimapButton:SetClampedToScreen(true)
    updateMinimapButtonPosition()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:SetScript("OnEvent", function(_, _, prefix, message, channel, sender)
    if prefix ~= PREFIX or not message or not sender or isSelf(sender) then return end
    if #message > MAX_MESSAGE_BYTES + #MESSAGE_TAG then return end

    local now = GetTime()
    if string.sub(message, 1, #CLASS_TAG) == CLASS_TAG then
        rememberClass(sender, string.sub(message, #CLASS_TAG + 1), true)
        notifyListenersChanged()
        return
    end

    -- A sound emote someone triggered: only its name travels, and you play
    -- your own copy of the file, so everyone around you hears it too. The
    -- header's bell mutes them; the sender still counts as active either
    -- way, so presence never depends on the sound.
    if string.sub(message, 1, #SOUND_TAG) == SOUND_TAG then
        noteActiveListener(sender)
        if not Nearby:IsSoundEmotesMuted() then
            TrialChatCommon.PlayReceivedSoundEmote(sender,
                string.sub(message, #SOUND_TAG + 1))
        end
        return
    end

    if message == PING and channel == "WHISPER" then
        C_ChatInfo.SendAddonMessage(PREFIX, PONG, "WHISPER", sender)
        noteActiveListener(sender)
        return
    end

    if message == PONG and channel == "WHISPER" then
        local senderKey = normalizeCharacterName(sender)
        local pingTime = pendingPings[senderKey]
        if pingTime and now - pingTime <= LISTENER_TIMEOUT then
            noteActiveListener(sender)
        end
        pendingPings[senderKey] = nil
        return
    end

    if string.sub(message, 1, #PART_TAG) == PART_TAG then
        local partId, index, count, chunk =
            string.match(message, "^P:(%x+):(%d+):(%d+):(.*)$")
        message = incomingParts:Add(normalizeCharacterName(sender),
            partId, tonumber(index), tonumber(count), chunk)
        if not message then return end
    end

    local messageTag = string.sub(message, 1, #EMOTE_TAG) == EMOTE_TAG
        and EMOTE_TAG or MESSAGE_TAG
    if string.sub(message, 1, #messageTag) ~= messageTag then return end
    local isEmote = messageTag == EMOTE_TAG
    local reply, body
    reply, body = TrialChatCommon.SplitReplyPrefix(
        string.sub(message, #messageTag + 1))
    if reply then
        reply.text = TrialChatCommon.NormalizeMessageMarkup(reply.text)
    end
    local chatText = TrialChatCommon.DecodeMessageMarkup(body)
    chatText = TrialChatCommon.NormalizeMessageMarkup(chatText)
    chatText = TrialChatCommon.AddSongLinkOwner(chatText, sender)
    noteActiveListener(sender)
    -- Keep the class and looks of people you chat with, for their name
    -- color and avatar later.
    TrialChatCommon.RememberClass(sender, getKnownClass(sender), true)
    local raceFile, sex = TrialChatCommon.GetKnownLook(sender)
    TrialChatCommon.RememberLook(sender, raceFile, sex, true)

    if not isEmote then
        TrialChatBubbles.ShowMessage(sender, chatText)
    end

    if channel == "RAID" then
        printIncomingMessage("Raid", sender, chatText, isEmote, reply)
    elseif channel == "PARTY" then
        printIncomingMessage("Party", sender, chatText, isEmote, reply)
    elseif channel == "WHISPER" then
        printIncomingMessage("Nearby", sender, chatText, isEmote, reply)
    end
end)

C_Timer.NewTicker(2, function()
    local now = GetTime()
    local listenersChanged = false

    for name, lastSeen in pairs(activeListeners) do
        if now - lastSeen > LISTENER_TIMEOUT then
            activeListeners[name] = nil
            listenersChanged = true
        end
    end

    for name, pingTime in pairs(pendingPings) do
        if now - pingTime > LISTENER_TIMEOUT then
            pendingPings[name] = nil
        end
    end

    for name, pingTime in pairs(lastPingAt) do
        if now - pingTime > PING_INTERVAL * 2 then
            lastPingAt[name] = nil
        end
    end

    local pingBudget = PING_BUDGET
    local processed = {}
    for index = 1, 40 do
        if pingBudget == 0 then break end

        local unit = "nameplate" .. index
        if UnitExists(unit) and UnitIsPlayer(unit) and not UnitIsEnemy("player", unit) then
            local name = getFullName(unit)
            local nameKey = normalizeCharacterName(name)
            if name and nameKey ~= normalizeCharacterName(fullPlayerName)
                and not processed[nameKey] then
                rememberUnit(unit, name)
                processed[nameKey] = true
                local lastPing = lastPingAt[nameKey]
                if not lastPing or now - lastPing >= PING_INTERVAL then
                    C_ChatInfo.SendAddonMessage(PREFIX, PING, "WHISPER", name)
                    lastPingAt[nameKey] = now
                    pendingPings[nameKey] = now
                    pingBudget = pingBudget - 1
                end
            end
        end
    end
    if listenersChanged then
        notifyListenersChanged()
    end
end)

-- Sends these packets to the people around you: your party, every TrialChat
-- player listening nearby plus the listeners you saved, and the members of
-- your raid (a raid isn't sent to as a channel, so its members are whispered
-- one by one). Your class goes along once in a while, so their copy of
-- TrialChat can color your name.
local function sendNearbyPackets(packets)
    local classPayload = playerClass and RAID_CLASS_COLORS[playerClass]
        and CLASS_TAG .. playerClass or nil
    local sentToGroup = IsInGroup()
    local inRaid = IsInRaid()
    local groupMembers = getGroupMembers()

    if sentToGroup and not inRaid then
        local groupChannel = "PARTY"
        if classPayload then
            C_ChatInfo.SendAddonMessage(PREFIX, classPayload, groupChannel)
        end
        for _, packet in ipairs(packets) do
            C_ChatInfo.SendAddonMessage(PREFIX, packet, groupChannel)
        end
    end

    local sendTargets = {}
    local activeTargetsByShortName = {}
    for targetPlayer in pairs(activeListeners) do
        if not isSelf(targetPlayer) then
            sendTargets[normalizeCharacterName(targetPlayer)] = targetPlayer
            local shortName = string.match(targetPlayer, "^([^-]+)")
            activeTargetsByShortName[normalizeName(shortName)] = true
        end
    end
    for _, targetPlayer in pairs(getPermanentListeners()) do
        local normalizedKey = normalizeCharacterName(targetPlayer)
        local shortName = string.match(targetPlayer, "^([^-]+)") or targetPlayer
        local isBareName = not string.find(targetPlayer, "-", 1, true)
        local alreadyActive = sendTargets[normalizedKey]
            or (isBareName and activeTargetsByShortName[normalizeName(shortName)])
        if not alreadyActive and not isSelf(targetPlayer) then
            sendTargets[normalizedKey] = targetPlayer
        end
    end

    if inRaid then
        for _, targetPlayer in pairs(groupMembers) do
            if not isSelf(targetPlayer) then
                sendTargets[normalizeCharacterName(targetPlayer)] = targetPlayer
            end
        end
    end

    for _, targetPlayer in pairs(sendTargets) do
        local isGroupMember = groupMembers[normalizeCharacterName(targetPlayer)] ~= nil
        if not isGroupMember or inRaid then
            if classPayload and not (inRaid and isGroupMember) then
                local targetKey = normalizeName(targetPlayer)
                local shortName = string.match(targetPlayer, "^([^-]+)")
                if not classByName[targetKey]
                    and not (shortName and classByName[normalizeName(shortName)]) then
                    C_ChatInfo.SendAddonMessage(PREFIX, classPayload, "WHISPER", targetPlayer)
                end
            end
            for _, packet in ipairs(packets) do
                C_ChatInfo.SendAddonMessage(PREFIX, packet, "WHISPER", targetPlayer)
            end
        end
    end
end

sendTrialChatMessage = function(msg, reply)
    msg = strtrim(msg or "")
    if msg == "" then
        showTrialChatNotice("Enter a message to send with /tc.", true)
        return
    end

    if #msg > MAX_CHAT_MESSAGE_BYTES then
        showTrialChatNotice("Message is too long (maximum "
            .. MAX_CHAT_MESSAGE_BYTES .. " bytes).", true)
        return
    end

    local isEmote
    local emoteToken
    local emoteTarget
    -- Sound emotes use "//" and play a local file; a sound emote that is also
    -- a normal emote continues below as that emote, a sound-only one stops
    -- here. Either way its name goes out to the people around you, so they
    -- hear it too: they play their own copy of the same file.
    local isSoundEmote, soundEmote, soundPlayed, soundWaiting, soundName =
        TrialChatCommon.ParseSoundEmote(msg)
    if isSoundEmote then
        if not soundEmote then
            if not soundPlayed and not soundWaiting
                and TrialChatCommon.IsGameSoundEnabled() then
                showTrialChatNotice("No sound emote found for that command.", true)
            end
            if soundName then
                sendNearbyPackets({ SOUND_TAG .. soundName })
            end
            return
        end
        msg = soundEmote
    end
    msg, isEmote, emoteToken, emoteTarget = TrialChatCommon.ParseEmote(msg)
    if not msg then
        showTrialChatNotice("Enter the text for your emote.", true)
        return
    end
    if #msg > MAX_CHAT_MESSAGE_BYTES then
        showTrialChatNotice("Message is too long (maximum "
            .. MAX_CHAT_MESSAGE_BYTES .. " bytes).", true)
        return
    end
    -- An emote isn't a message, so it never answers one.
    if isEmote then reply = nil end
    TrialChatCommon.PerformEmote(emoteToken, emoteTarget)
    local payload = (isEmote and EMOTE_TAG or MESSAGE_TAG)
        .. TrialChatCommon.EncodeReplyPrefix(reply)
        .. TrialChatCommon.EncodeMessageMarkup(TrialChatCommon.AddOwnSongLinkOwner(msg))
    -- Too long for one addon message: send it in parts the receiver joins.
    local packets = { payload }
    if #payload > 255 then
        local partId = TrialChatCommon.NewPartId()
        local parts = TrialChatCommon.SplitIntoParts(payload, NEARBY_PART_BYTES)
        packets = {}
        for index, part in ipairs(parts) do
            packets[index] = PART_TAG .. partId .. ":" .. index .. ":"
                .. #parts .. ":" .. part
        end
    end
    -- The name of a sound emote travels as its own small packet with the
    -- message, so everyone who gets the message hears the sound as well:
    -- each of them plays their own copy of the file.
    if soundName then
        packets[#packets + 1] = SOUND_TAG .. soundName
    end
    sendNearbyPackets(packets)

    addNearbyMessage(fullPlayerName or playerName, msg, isEmote, reply)
    -- With "echo to say" on, normal (non-emote) messages also go out as
    -- regular /say, so nearby players without TrialChat can read them. The
    -- game then draws its own bubble over us, so don't draw a TrialChat one
    -- as well. Emotes are already announced by PerformEmote, so they aren't
    -- echoed.
    TrialChatDB = TrialChatDB or {}
    if not isEmote then
        if TrialChatDB.echoToSay then
            -- The message still holds the raw shortcut (":-)" and the like)
            -- and "/say" rejects a "|" that doesn't start a valid escape, so
            -- escape bare pipes before handing it to the game.
            SendChatMessage(TrialChatCommon.EscapeChatPipes(msg), "SAY")
        else
            TrialChatBubbles.ShowOwnMessage(msg)
        end
        -- With "echo to party" on, the message also goes to the group, so
        -- members who are elsewhere (or without TrialChat) read it there. A
        -- raid has no party channel of its own, so it goes to the raid
        -- instead; outside a group there is nowhere to echo it and it stays
        -- nearby. Group chat draws no bubbles, so the TrialChat bubble is
        -- never doubled by this one.
        if TrialChatDB.echoToParty then
            local chatType = IsInRaid() and "RAID"
                or (IsInGroup() and "PARTY" or nil)
            if chatType then
                SendChatMessage(TrialChatCommon.EscapeChatPipes(msg), chatType)
            end
        end
    end
end

Nearby.MAX_MESSAGE_BYTES = MAX_CHAT_MESSAGE_BYTES

-- The handler is called as handler(kind, ...) where kind is "message"
-- (followed by the new history entry), "listeners" (someone started or
-- stopped listening, or a listener was saved or removed), or "notice"
-- (followed by the text and whether it is an error).
function Nearby:SetChangeHandler(handler)
    changeHandler = handler
end

function Nearby:GetHistory()
    return getChatHistory()
end

function Nearby:Send(message, reply)
    sendTrialChatMessage(message, reply)
end

function Nearby:GetClass(name)
    return getKnownClass(name)
end

-- Sound emotes are the only sound nearby chat makes, so its bell mutes
-- just them (a group's bell also mutes the message sound). This mutes
-- what other players trigger; a "//name" you type yourself still plays.
function Nearby:IsSoundEmotesMuted()
    return TrialChatDB.nearbySoundEmotesMuted == true
end

function Nearby:SetSoundEmotesMuted(muted)
    TrialChatDB.nearbySoundEmotesMuted = muted == true or nil
end

local function countsAsListener(name)
    return name and not isSelf(name)
end

function Nearby:GetActiveCount()
    local names = {}
    local count = 0
    for name in pairs(activeListeners) do
        local key = normalizeName(name)
        if countsAsListener(name) and not names[key] then
            names[key] = true
            count = count + 1
        end
    end
    return count
end

function Nearby:IsActive(name)
    local nameKey = normalizeCharacterName(name)
    for listener in pairs(activeListeners) do
        if normalizeCharacterName(listener) == nameKey then
            return true
        end
    end
    return false
end

local function sortListeners(listeners)
    table.sort(listeners, function(left, right)
        return strlower(left.fullName) < strlower(right.fullName)
    end)
end

-- The players around you that use TrialChat, and the saved listeners that
-- aren't around, each a list of { fullName, classFile, saved }.
function Nearby:GetListeners()
    getGroupMembers()
    local nearby, away = {}, {}
    local activeByName, activeByShortName = {}, {}
    for targetPlayer in pairs(activeListeners) do
        if countsAsListener(targetPlayer) then
            local key = normalizeName(targetPlayer)
            if not activeByName[key] then
                local listener = {
                    fullName = targetPlayer,
                    classFile = getKnownClass(targetPlayer),
                }
                activeByName[key] = listener
                activeByShortName[normalizeName(getShortName(targetPlayer))] = listener
                nearby[#nearby + 1] = listener
            end
        end
    end

    for targetKey, targetPlayer in pairs(getPermanentListeners()) do
        if countsAsListener(targetPlayer) then
            local listener = activeByName[normalizeName(targetKey)]
            if not listener and not string.find(targetPlayer, "-", 1, true) then
                listener = activeByShortName[normalizeName(getShortName(targetPlayer))]
            end
            if listener then
                listener.saved = true
            else
                away[#away + 1] = {
                    fullName = targetPlayer,
                    classFile = getKnownClass(targetPlayer),
                    saved = true,
                }
            end
        end
    end
    sortListeners(nearby)
    sortListeners(away)
    return nearby, away
end

function Nearby:GetSavedCount()
    local count = 0
    for _, targetPlayer in pairs(getPermanentListeners()) do
        if countsAsListener(targetPlayer) then
            count = count + 1
        end
    end
    return count
end

-- Saved listeners hear your nearby chat wherever they are.
function Nearby:ToggleSavedListener(name)
    if not name or isSelf(name) then return end

    local permanentListeners = getPermanentListeners()
    local existingKey = findPermanentListenerKey(name)
    if existingKey then
        permanentListeners[existingKey] = nil
    else
        permanentListeners[normalizeName(name)] = name
    end
    notifyChange("listeners")
end

function Nearby:IsSavedListener(name)
    return findPermanentListenerKey(name) ~= nil
end

-- Returns an error message when the name can't be added.
function Nearby:AddSavedListener(name)
    name = strtrim(name or "")
    if name == "" then return nil end

    if isSelf(name) then
        return "You are already in the listener list."
    end
    if string.find(name, "[%c%s|]") then
        return "Enter a character name, optionally followed by -Realm."
    end

    local key = normalizeName(name)
    local permanentListeners = getPermanentListeners()
    if permanentListeners[key] then
        return "That listener is already saved."
    end

    permanentListeners[key] = name
    notifyChange("listeners")
    return nil
end

SLASH_TRIALCHAT1 = "/tc"
SLASH_TRIALCHAT2 = "/trialchat"
SlashCmdList["TRIALCHAT"] = function(msg)
    msg = strtrim(msg or "")
    if msg == "" then
        TrialChatMessenger:Open(true)
        return
    end

    sendTrialChatMessage(msg)
end

-- /reload still reloads the UI, but first tells the people around you that a
-- newer version of the addon is out, so they know to reload too.
--
-- The reload has to run in the same input event as the typed command. C_UI.Reload
-- is restricted to hardware events, so deferring it (for example with C_Timer)
-- makes the client block it with "Interface action failed because of an AddOn".
-- Sending the notice first is fine: chat messages go out before the reload.
local RELOAD_EMOTE = "reload"

local function reloadUI()
    if C_UI and C_UI.Reload then
        C_UI.Reload()
    else
        ReloadUI()
    end
end

-- Sends the TrialChat "reload" emote, then reloads the UI. The /reload slash
-- command uses the default send (nearby chat and the current group); the
-- TrialChat message box passes a send that targets the conversation being
-- viewed, so the emote lands in the same chat it would if typed there.
-- The emote is sent first, synchronously, and only then does the reload start.
function TrialChat_Reload(sendEmote)
    if sendEmote then
        sendEmote()
    else
        sendTrialChatMessage("/" .. RELOAD_EMOTE)
    end
    reloadUI()
end

-- True when a TrialChat input box was given the "/reload" command, so it can
-- be treated as a command instead of a chat message.
function TrialChat_IsReloadCommand(message)
    return string.lower(strtrim(message or "")) == "/reload"
end

SlashCmdList["RELOAD"] = function(msg)
    if strtrim(msg or "") ~= "" then
        -- "/reload <argument>" keeps its plain meaning, without the notice.
        reloadUI()
        return
    end
    TrialChat_Reload()
end

BINDING_NAME_TRIALCHAT_OPEN = "Open and start typing"

function TrialChat_Open()
    C_Timer.After(0, function()
        TrialChatMessenger:Open(true)
    end)
end

local hookFrame = CreateFrame("Frame")
hookFrame:RegisterEvent("PLAYER_LOGIN")
hookFrame:SetScript("OnEvent", function()
    TrialChatCommon.RefreshPlayerIdentity()
    playerName = TrialChatCommon.GetPlayerName()
    fullPlayerName = TrialChatCommon.GetPlayerFullName()
    playerRealm = TrialChatCommon.GetPlayerRealm()
    playerClass = TrialChatCommon.GetPlayerClass()
    createMinimapButton()
    hookSlashOpenShortcut()
end)
