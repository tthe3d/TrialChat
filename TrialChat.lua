local PREFIX = "TrialChat"
local MESSAGE_TAG = "M:"
local PING = "C:PING"
local PONG = "C:PONG"
local CLASS_TAG = "C:CLASS:"
local MAX_MESSAGE_BYTES = 240
local LISTENER_TIMEOUT = 35
local PING_INTERVAL = 30
local PING_BUDGET = 4

if not C_ChatInfo.RegisterAddonMessagePrefix(PREFIX) then
    print("|cffff3333[TrialChat] Could not register the addon-message prefix.|r")
    return
end

local activeListeners = {}
local lastPingAt = {}
local pendingPings = {}
local pendingIncomingMessages = {}
local playerName = UnitName("player")
local fullPlayerName, playerRealm = UnitFullName("player")
local _, playerClass = UnitClass("player")
local classByName = {}
local trialChatMode = false
local minimapButton
if fullPlayerName and playerRealm and playerRealm ~= "" then
    fullPlayerName = fullPlayerName .. "-" .. playerRealm
end

local function normalizeName(name)
    return name and strlower(name) or nil
end

local function getFullName(unit)
    local name, realm = UnitFullName(unit)
    if not name then return nil end
    if realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name
end

local function rememberClass(fullName, classFile)
    if not fullName or not classFile or not RAID_CLASS_COLORS[classFile] then return end

    classByName[normalizeName(fullName)] = classFile
    local shortName = string.match(fullName, "^([^-]+)")
    if shortName then
        classByName[normalizeName(shortName)] = classFile
    end
end

local function rememberUnitClass(unit, fullName)
    local _, classFile = UnitClass(unit)
    rememberClass(fullName, classFile)
end

local function getClassColor(classFile)
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

local function getKnownNameColor(name, fallback)
    local classFile = classByName[normalizeName(name)]
    if not classFile and not string.find(name, "-", 1, true) then
        local shortName = string.match(name, "^([^-]+)")
        classFile = shortName and classByName[normalizeName(shortName)]
    end
    return getClassColor(classFile) or fallback
end

local function isSelf(sender)
    local senderKey = normalizeName(sender)
    if senderKey == normalizeName(fullPlayerName) then return true end
    return not string.find(sender, "-", 1, true)
        and normalizeName(sender) == normalizeName(playerName)
end

local function getGroupMembers()
    local members, shortNames = {}, {}
    local count = IsInRaid() and 40 or 4
    local unitPrefix = IsInRaid() and "raid" or "party"

    for index = 1, count do
        local unit = unitPrefix .. index
        local name = getFullName(unit)
        if name then
            members[normalizeName(name)] = true
            local shortName = string.match(name, "^([^-]+)")
            shortNames[normalizeName(shortName)] = true
            rememberUnitClass(unit, name)
        end
    end

    return members, shortNames
end

local function printMessage(label, sender, message, color, nameColor)
    message = string.gsub(message, "|", "||")
    nameColor = nameColor or color
    print(color .. "[" .. label .. "] " .. nameColor .. sender .. "|r:|r " .. message)
end

local function printIncomingMessage(label, sender, message, color, nameColor, senderKey)
    local key = normalizeName(senderKey or sender) .. "\0" .. message
    local pending = pendingIncomingMessages[key]
    local isGroupMessage = label == "Party" or label == "Raid"
    local isNearbyMessage = label == "Nearby"

    if pending then
        local isNewAudience = (isGroupMessage and not pending.groupLabel)
            or (isNearbyMessage and not pending.nearby)
        if isNewAudience and GetTime() - pending.receivedAt <= 0.2 then
            pending.groupLabel = isGroupMessage and label or pending.groupLabel
            pending.nearby = pending.nearby or isNearbyMessage
            pending.nameColor = pending.nameColor or nameColor
            pending.color = pending.groupLabel and "|cffff7d0a" or color
            pending.label = pending.groupLabel and pending.nearby
                and pending.groupLabel .. " + Nearby"
                or pending.groupLabel or "Nearby"
            return
        end

        if pendingIncomingMessages[key] == pending then
            pendingIncomingMessages[key] = nil
            printMessage(pending.label, pending.sender, pending.message,
                pending.color, pending.nameColor)
        end
    end

    pending = {
        label = label,
        sender = sender,
        message = message,
        color = color,
        nameColor = nameColor,
        groupLabel = isGroupMessage and label or nil,
        nearby = isNearbyMessage,
        receivedAt = GetTime(),
    }
    pendingIncomingMessages[key] = pending

    C_Timer.After(0.2, function()
        if pendingIncomingMessages[key] == pending then
            pendingIncomingMessages[key] = nil
            printMessage(pending.label, pending.sender, pending.message,
                pending.color, pending.nameColor)
        end
    end)
end

local function showMinimapTooltip(button)
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("TrialChat")
    GameTooltip:AddLine(trialChatMode and "Mode: On" or "Mode: Off", 1, 0.82, 0)
    GameTooltip:AddLine("Click to toggle TrialChat mode.", 1, 1, 1)
    GameTooltip:AddLine("Drag to move this button.", 0.7, 0.7, 0.7)
    GameTooltip:Show()
end

local function updateMinimapButton()
    if not minimapButton then return end

    minimapButton.icon:SetDesaturated(not trialChatMode)
    if GameTooltip:GetOwner() == minimapButton then
        showMinimapTooltip(minimapButton)
    end
end

local function toggleTrialChatMode()
    trialChatMode = not trialChatMode
    if trialChatMode then
        print("|cffff7d0a[TrialChat] Mode enabled. Plain messages will use TrialChat.|r")
    else
        print("|cffff7d0a[TrialChat] Mode disabled. Plain messages will use normal chat.|r")
    end
    updateMinimapButton()
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
    minimapButton:RegisterForClicks("LeftButtonUp")
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

    minimapButton:SetScript("OnClick", toggleTrialChatMode)
    minimapButton:SetScript("OnLeave", GameTooltip_Hide)
    minimapButton:SetScript("OnDragStart", function(self)
        self.isDragging = true
    end)
    minimapButton:SetScript("OnDragStop", function(self)
        self.isDragging = false

        local centerX, centerY = Minimap:GetCenter()
        local buttonX, buttonY = self:GetCenter()
        TrialChatDB.minimapAngle = math.deg(math.atan2(buttonY - centerY, buttonX - centerX))
        updateMinimapButtonPosition()
    end)

    minimapButton:SetMovable(true)
    minimapButton:SetClampedToScreen(true)
    minimapButton:SetScript("OnUpdate", function(self)
        if self.isDragging then
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
    end)

    updateMinimapButtonPosition()
    updateMinimapButton()
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:SetScript("OnEvent", function(_, _, prefix, message, channel, sender)
    if prefix ~= PREFIX or not message or not sender or isSelf(sender) then return end
    if #message > MAX_MESSAGE_BYTES + #MESSAGE_TAG then return end

    local now = GetTime()
    if string.sub(message, 1, #CLASS_TAG) == CLASS_TAG then
        rememberClass(sender, string.sub(message, #CLASS_TAG + 1))
        return
    end

    if message == PING and channel == "WHISPER" then
        C_ChatInfo.SendAddonMessage(PREFIX, PONG, "WHISPER", sender)
        activeListeners[sender] = now
        return
    end

    if message == PONG and channel == "WHISPER" then
        local pingTime = pendingPings[normalizeName(sender)]
        if pingTime and now - pingTime <= LISTENER_TIMEOUT then
            activeListeners[sender] = now
        end
        pendingPings[normalizeName(sender)] = nil
        return
    end

    if string.sub(message, 1, #MESSAGE_TAG) ~= MESSAGE_TAG then return end
    local chatText = string.sub(message, #MESSAGE_TAG + 1)
    local shortSender = string.match(sender, "^([^-]+)") or sender

    if channel == "RAID" then
        printIncomingMessage("Raid", shortSender, chatText, "|cffff7d0a",
            getKnownNameColor(sender, "|cffff7d0a"), sender)
    elseif channel == "PARTY" then
        printIncomingMessage("Party", shortSender, chatText, "|cffff7d0a",
            getKnownNameColor(sender, "|cffff7d0a"), sender)
    elseif channel == "WHISPER" then
        printIncomingMessage("Nearby", shortSender, chatText, "|cffffcc00",
            getKnownNameColor(sender, "|cffffcc00"), sender)
    end
end)

C_Timer.NewTicker(2, function()
    local now = GetTime()

    for name, lastSeen in pairs(activeListeners) do
        if now - lastSeen > LISTENER_TIMEOUT then
            activeListeners[name] = nil
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
            local nameKey = normalizeName(name)
            if name and nameKey ~= normalizeName(fullPlayerName) and not processed[nameKey] then
                rememberUnitClass(unit, name)
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
end)

local function sendTrialChatMessage(msg)
    msg = strtrim(msg or "")
    if msg == "" then
        print("|cffff3333[TrialChat] Enter a message to send with /tc.|r")
        return
    end

    if #msg > MAX_MESSAGE_BYTES then
        print("|cffff3333[TrialChat] Message is too long (maximum 240 bytes).|r")
        return
    end

    local payload = MESSAGE_TAG .. msg
    local classPayload = playerClass and RAID_CLASS_COLORS[playerClass]
        and CLASS_TAG .. playerClass or nil
    local sentToGroup = IsInGroup()
    local sentWhisperCount = 0
    local groupMembers, groupShortNames = getGroupMembers()

    if sentToGroup then
        local groupChannel = IsInRaid() and "RAID" or "PARTY"
        if classPayload then
            C_ChatInfo.SendAddonMessage(PREFIX, classPayload, groupChannel)
        end
        C_ChatInfo.SendAddonMessage(PREFIX, payload, groupChannel)
    end

    for targetPlayer in pairs(activeListeners) do
        local targetKey = normalizeName(targetPlayer)
        local shortName = string.match(targetPlayer, "^([^-]+)")
        local isGroupMember = groupMembers[targetKey]
            or (not string.find(targetPlayer, "-", 1, true) and groupShortNames[normalizeName(shortName)])
        if not isGroupMember then
            if classPayload then
                C_ChatInfo.SendAddonMessage(PREFIX, classPayload, "WHISPER", targetPlayer)
            end
            C_ChatInfo.SendAddonMessage(PREFIX, payload, "WHISPER", targetPlayer)
            sentWhisperCount = sentWhisperCount + 1
        end
    end

    local myShortName = string.match(playerName, "^([^-]+)") or playerName
    local myNameColor = getClassColor(playerClass)
    if sentToGroup and sentWhisperCount > 0 then
        printMessage(IsInRaid() and "Raid + Nearby" or "Party + Nearby",
            myShortName, msg, "|cffff7d0a", myNameColor)
    elseif sentToGroup then
        printMessage(IsInRaid() and "Raid" or "Party", myShortName, msg, "|cffff7d0a", myNameColor)
    elseif sentWhisperCount > 0 then
        printMessage("Nearby", myShortName, msg, "|cffffcc00", myNameColor)
    else
        printMessage("Nearby", myShortName, msg, "|cffffcc00", myNameColor)
        print("|cffff7d0aBut nobody heard that, because there are no players using TrialChat around.|r")
    end
end

SLASH_TRIALCHAT1 = "/tc"
SLASH_TRIALCHAT2 = "/trialchat"
SlashCmdList["TRIALCHAT"] = function(msg)
    msg = strtrim(msg or "")
    if msg == "" then
        toggleTrialChatMode()
        return
    end

    sendTrialChatMessage(msg)
end

local function installChatInputHook()
    local function wrapSendText(editBox)
        if not editBox or editBox.trialChatSendTextHooked or not editBox.SendText then return end

        local originalSendText = editBox.SendText
        editBox.SendText = function(self, addHistory, ...)
            if not trialChatMode then
                return originalSendText(self, addHistory, ...)
            end

            local text = self:GetText() or ""
            if string.match(text, "^%s*/") then
                return originalSendText(self, addHistory, ...)
            end

            local message = strtrim(text)
            if message ~= "" then
                sendTrialChatMessage(message)
                if addHistory then
                    self:AddHistory()
                end
            end
        end
        editBox.trialChatSendTextHooked = true
    end

    if ChatFrameEditBoxMixin and ChatFrameEditBoxMixin.SendText then
        wrapSendText(ChatFrameEditBoxMixin)
    end

    for index = 1, (NUM_CHAT_WINDOWS or 10) do
        local chatFrame = _G["ChatFrame" .. index]
        if chatFrame then
            wrapSendText(chatFrame.editBox)
        end
    end
end

local hookFrame = CreateFrame("Frame")
hookFrame:RegisterEvent("PLAYER_LOGIN")
hookFrame:SetScript("OnEvent", function()
    installChatInputHook()
    createMinimapButton()
end)
