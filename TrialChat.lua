local PREFIX = "TrialChat"
_G.BINDING_HEADER_TRIALCHAT = "TrialChat"
local MESSAGE_TAG = "M:"
local EMOTE_TAG = "E:"
local PING = "C:PING"
local PONG = "C:PONG"
local CLASS_TAG = "C:CLASS:"
local MAX_MESSAGE_BYTES = 253
local MAX_CHAT_HISTORY = 200
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
local minimapButton
local chatWindow
local chatLog
local chatInput
local openChatWindow
local sendTrialChatMessage
local showTrialChatNotice
local slashOpenHooks = {}
local recipientList
local recipientRows = {}
local recipientScrollFrame
local recipientTitle
local recipientPanel
local recipientToggleButton
local nearbyCountText
local activeCountText
local addListenerInput
local listenersExpanded = false
local updateRecipientList
local updateChatContentLayout
local RECIPIENT_ROW_HEIGHT = 18
local CHAT_WINDOW_IDLE_ALPHA = 0.45
local CHAT_MESSAGE_VISIBLE_SECONDS = 10
local lastChatMessageAt
if fullPlayerName and playerRealm and playerRealm ~= "" then
    fullPlayerName = fullPlayerName .. "-" .. playerRealm
end

local function updateChatWindowAlpha()
    if not chatWindow then return end

    local mouseOverChat = chatWindow:IsShown() and chatWindow:IsMouseOver()
    local mouseOverListeners = recipientPanel
        and recipientPanel:IsShown()
        and recipientPanel:IsMouseOver()
    local inputHasFocus = (chatInput and chatInput:HasFocus())
        or (addListenerInput and addListenerInput:HasFocus())
    local recentMessage = lastChatMessageAt
        and GetTime() - lastChatMessageAt < CHAT_MESSAGE_VISIBLE_SECONDS
    local alpha = (mouseOverChat or mouseOverListeners or inputHasFocus or recentMessage)
        and 1 or CHAT_WINDOW_IDLE_ALPHA

    chatWindow:SetAlpha(alpha)
    if recipientPanel then
        recipientPanel:SetAlpha(alpha)
    end
end

local function noteChatMessage()
    lastChatMessageAt = GetTime()
    updateChatWindowAlpha()
    C_Timer.After(CHAT_MESSAGE_VISIBLE_SECONDS, updateChatWindowAlpha)
end

local function getChatHistory()
    TrialChatDB = TrialChatDB or {}
    if type(TrialChatDB.chatHistory) ~= "table" then
        TrialChatDB.chatHistory = {}
    end
    return TrialChatDB.chatHistory
end

local function saveChatHistoryLine(line)
    local history = getChatHistory()
    history[#history + 1] = line
    while #history > MAX_CHAT_HISTORY do
        table.remove(history, 1)
    end
end

local function saveChatWindowSettings()
    if not chatWindow then return end

    local centerX, centerY = chatWindow:GetCenter()
    local parentWidth, parentHeight = UIParent:GetSize()
    if not centerX or not centerY or parentWidth <= 0 or parentHeight <= 0 then return end

    TrialChatDB = TrialChatDB or {}
    TrialChatDB.chatWindow = {
        width = chatWindow:GetWidth(),
        height = chatWindow:GetHeight(),
        centerX = centerX / parentWidth,
        centerY = centerY / parentHeight,
    }
end

local function normalizeName(name)
    return name and strlower(name) or nil
end

local function normalizeCharacterName(name)
    local normalized = normalizeName(name)
    if normalized and not string.find(name, "-", 1, true)
        and playerRealm and playerRealm ~= "" then
        return normalized .. "-" .. normalizeName(playerRealm)
    end
    return normalized
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
    local members = {}
    local count = IsInRaid() and 40 or 4
    local unitPrefix = IsInRaid() and "raid" or "party"

    for index = 1, count do
        local unit = unitPrefix .. index
        local name = getFullName(unit)
        if name then
            members[normalizeCharacterName(name)] = name
            rememberUnitClass(unit, name)
        end
    end

    return members
end

local function getTrialChatRecipients()
    local recipients, recipientsByName = {}, {}
    getGroupMembers()

    local selfKey = normalizeName(fullPlayerName or playerName)
    local selfShortName = string.match(playerName, "^([^-]+)") or playerName
    recipientsByName[selfKey] = true
    recipients[#recipients + 1] = {
        name = selfShortName .. " (You)",
        classFile = playerClass,
        isSelf = true,
    }

    local permanentListeners = getPermanentListeners()
    local activeByName, activeByShortName = {}, {}
    for targetPlayer in pairs(activeListeners) do
        if not isSelf(targetPlayer) then
            local targetKey = normalizeName(targetPlayer)
            local shortName = string.match(targetPlayer, "^([^-]+)") or targetPlayer
            local recipient = {
                name = shortName,
                classFile = classByName[targetKey] or classByName[normalizeName(shortName)],
                fullName = targetPlayer,
            }
            activeByName[targetKey] = recipient
            activeByShortName[normalizeName(shortName)] = recipient
        end
    end

    for targetKey, targetPlayer in pairs(permanentListeners) do
        if not isSelf(targetPlayer) then
            local normalizedKey = normalizeName(targetKey)
            local shortName = string.match(targetPlayer, "^([^-]+)") or targetPlayer
            local recipient = activeByName[normalizedKey]
            if not recipient and not string.find(targetPlayer, "-", 1, true) then
                recipient = activeByShortName[normalizeName(shortName)]
            end

            if recipient then
                recipient.permanent = true
            else
                activeByName[normalizedKey] = {
                    name = shortName,
                    classFile = classByName[normalizedKey] or classByName[normalizeName(shortName)],
                    fullName = targetPlayer,
                    permanent = true,
                }
            end
        end
    end

    for targetKey, recipient in pairs(activeByName) do
        if not recipientsByName[targetKey] then
            recipientsByName[targetKey] = true
            recipients[#recipients + 1] = recipient
        end
    end

    table.sort(recipients, function(left, right)
        return strlower(left.name) < strlower(right.name)
    end)
    return recipients
end

local function createRecipientRow(index)
    local row = CreateFrame("Button", nil, recipientPanel)
    row:SetHeight(RECIPIENT_ROW_HEIGHT)
    row:SetPoint("TOPLEFT", recipientScrollFrame, "TOPLEFT",
        2, -(index - 1) * RECIPIENT_ROW_HEIGHT)
    row:SetPoint("RIGHT", recipientScrollFrame, "RIGHT", -18, 0)
    row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.label:SetAllPoints()
    row.label:SetJustifyH("LEFT")
    row.label:SetWordWrap(false)
    row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    row:SetScript("OnClick", function(self, button)
        if self.isSelf then return end

        if button == "RightButton" then
            TrialChatCommon.ShowPlayerOptions(
                self.recipientName, self.recipientName, button)
            return
        end

        local permanentListeners = getPermanentListeners()
        local existingKey = findPermanentListenerKey(self.recipientName)
        if existingKey then
            permanentListeners[existingKey] = nil
        else
            permanentListeners[normalizeName(self.recipientName)] = self.recipientName
        end
        updateRecipientList()
    end)
    row:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        local tooltipText
        if self.isSelf then
            tooltipText = "This is you."
        elseif findPermanentListenerKey(self.recipientName) then
            tooltipText = "Left-click to stop keeping this listener.\nRight-click for player options."
        else
            tooltipText = "Left-click to keep this listener permanently.\nRight-click for player options."
        end
        GameTooltip:SetText(tooltipText)
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", GameTooltip_Hide)
    recipientRows[index] = row
end

updateRecipientList = function()
    if not recipientScrollFrame or not recipientTitle then return end

    recipientList = getTrialChatRecipients()
    while #recipientRows < #recipientList do
        createRecipientRow(#recipientRows + 1)
    end
    local nearbyNames = {}
    for targetPlayer in pairs(activeListeners) do
        if not isSelf(targetPlayer) then
            nearbyNames[normalizeName(targetPlayer)] = true
        end
    end
    local nearbyCount = 0
    for _ in pairs(nearbyNames) do
        nearbyCount = nearbyCount + 1
    end
    nearbyCountText:SetText("Nearby Players (" .. nearbyCount .. ")")
    activeCountText:SetText("Active listeners (" .. #recipientList .. ")")
    recipientTitle:SetText("Active listeners (" .. #recipientList .. ")")
    if recipientToggleButton then
        recipientToggleButton:SetText(listenersExpanded and "<" or ">")
    end

    local visibleRows = math.max(1,
        math.floor(recipientScrollFrame:GetHeight() / RECIPIENT_ROW_HEIGHT))
    FauxScrollFrame_Update(recipientScrollFrame, #recipientList, visibleRows, RECIPIENT_ROW_HEIGHT)

    local offset = FauxScrollFrame_GetOffset(recipientScrollFrame)
    for index, row in ipairs(recipientRows) do
        local recipient = recipientList[offset + index]
        if listenersExpanded and recipient and index <= visibleRows then
            local color = getClassColor(recipient.classFile)
            local name = recipient.name .. (recipient.permanent and " |cff00ff00*" or "")
            row.label:SetText(color and color .. name .. "|r" or name)
            row.recipientName = recipient.fullName
            row.isSelf = recipient.isSelf
            row:Show()
        else
            row:Hide()
        end
    end
end

updateChatContentLayout = function()
    if not chatLog or not chatInput then return end

    chatLog:ClearAllPoints()
    chatLog:SetPoint("TOPLEFT", chatWindow, "TOPLEFT", 14, -70)
    chatLog:SetPoint("BOTTOMRIGHT", chatWindow, "BOTTOMRIGHT", -14, 48)
    chatInput:ClearAllPoints()
    chatInput:SetHeight(26)
    chatInput:SetPoint("BOTTOMLEFT", chatWindow, "BOTTOMLEFT", 14, 14)
    chatInput:SetPoint("BOTTOMRIGHT", chatWindow, "BOTTOMRIGHT", -14, 14)
end

local function printMessage(sender, message, color, nameColor, isEmote)
    message = TrialChatCommon.FormatMessageText(message)
    nameColor = isEmote and color or nameColor or color
    local line = color .. "[" .. date("%H:%M") .. "] "
        .. nameColor .. sender
    if isEmote then
        line = line .. " " .. message .. "|r"
    else
        line = line .. "|r:|r " .. message
    end
    saveChatHistoryLine(line)
    if openChatWindow then
        openChatWindow(false)
        noteChatMessage()
        chatLog:AddMessage(line)
        chatLog:ScrollToBottom()
    else
        print(line)
    end
end

local function printIncomingMessage(
    label, sender, message, color, nameColor, senderKey, isEmote)
    local key = normalizeName(senderKey or sender) .. "\0" .. message
        .. "\0" .. tostring(isEmote)
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
            pending.isEmote = isEmote
            return
        end

        if pendingIncomingMessages[key] == pending then
            pendingIncomingMessages[key] = nil
            printMessage(pending.sender, pending.message,
                pending.color, pending.nameColor, pending.isEmote)
        end
    end

    pending = {
        sender = sender,
        message = message,
        color = color,
        nameColor = nameColor,
        groupLabel = isGroupMessage and label or nil,
        nearby = isNearbyMessage,
        receivedAt = GetTime(),
        isEmote = isEmote,
    }
    pendingIncomingMessages[key] = pending

    C_Timer.After(0.2, function()
        if pendingIncomingMessages[key] == pending then
            pendingIncomingMessages[key] = nil
            printMessage(pending.sender, pending.message,
                pending.color, pending.nameColor, pending.isEmote)
        end
    end)
end

local function createChatWindow()
    if chatWindow then return end

    TrialChatDB = TrialChatDB or {}
    chatWindow = CreateFrame("Frame", "TrialChatWindow", UIParent, "BackdropTemplate")
    local savedSettings = TrialChatDB.chatWindow
    local width = type(savedSettings) == "table" and tonumber(savedSettings.width) or 420
    local height = type(savedSettings) == "table" and tonumber(savedSettings.height) or 420
    width = math.max(320, math.min(900, width or 420))
    height = math.max(320, math.min(900, height or 420))
    chatWindow:SetSize(width, height)
    chatWindow:SetFrameStrata("DIALOG")
    chatWindow:SetFrameLevel(100)
    chatWindow:SetMovable(true)
    chatWindow:SetResizable(true)
    chatWindow:SetResizeBounds(320, 320, 900, 900)
    chatWindow:SetClampedToScreen(true)
    local centerX = type(savedSettings) == "table" and tonumber(savedSettings.centerX)
    local centerY = type(savedSettings) == "table" and tonumber(savedSettings.centerY)
    if centerX and centerY then
        local parentWidth, parentHeight = UIParent:GetSize()
        chatWindow:SetPoint("CENTER", UIParent, "BOTTOMLEFT",
            centerX * parentWidth, centerY * parentHeight)
    else
        chatWindow:SetPoint("CENTER")
    end
    chatWindow:EnableMouse(true)
    chatWindow:RegisterForDrag("LeftButton")
    chatWindow:SetScript("OnDragStart", chatWindow.StartMoving)
    chatWindow:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        saveChatWindowSettings()
    end)
    chatWindow:HookScript("OnEnter", updateChatWindowAlpha)
    chatWindow:HookScript("OnLeave", updateChatWindowAlpha)
    chatWindow:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    chatWindow:SetBackdropColor(0.04, 0.04, 0.04, 0.95)
    chatWindow:SetAlpha(CHAT_WINDOW_IDLE_ALPHA)

    local title = chatWindow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", chatWindow, "TOP", 0, -12)
    title:SetText("TrialChat")

    nearbyCountText = chatWindow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    nearbyCountText:SetPoint("TOP", title, "BOTTOM", 0, -3)
    nearbyCountText:SetJustifyH("CENTER")

    activeCountText = chatWindow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    activeCountText:SetPoint("TOP", nearbyCountText, "BOTTOM", 0, -2)
    activeCountText:SetJustifyH("CENTER")

    local closeButton = CreateFrame("Button", nil, chatWindow, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", chatWindow, "TOPRIGHT", -2, -2)
    closeButton:SetScript("OnClick", function()
        chatWindow:Hide()
    end)

    recipientPanel = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    recipientPanel:SetPoint("TOPLEFT", chatWindow, "TOPRIGHT", 0, 0)
    recipientPanel:SetPoint("BOTTOMLEFT", chatWindow, "BOTTOMRIGHT", 0, 0)
    recipientPanel:SetWidth(170)
    recipientPanel:SetFrameStrata("DIALOG")
    recipientPanel:SetFrameLevel(100)
    recipientPanel:EnableMouse(true)
    recipientPanel:HookScript("OnEnter", updateChatWindowAlpha)
    recipientPanel:HookScript("OnLeave", updateChatWindowAlpha)
    recipientPanel:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    recipientPanel:SetBackdropColor(0.02, 0.02, 0.02, 0.75)
    recipientPanel:SetAlpha(CHAT_WINDOW_IDLE_ALPHA)

    recipientTitle = recipientPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    recipientTitle:SetPoint("TOP", recipientPanel, "TOP", 0, -8)
    recipientTitle:SetJustifyH("CENTER")
    recipientTitle:SetText("Active listeners")

    listenersExpanded = false
    recipientToggleButton = CreateFrame("Button", nil, chatWindow, "UIPanelButtonTemplate")
    recipientToggleButton:SetSize(22, 18)
    recipientToggleButton:SetPoint("LEFT", activeCountText, "RIGHT", 4, 0)
    recipientToggleButton:SetScript("OnClick", function()
        listenersExpanded = not listenersExpanded
        if chatWindow:IsShown() and listenersExpanded then
            recipientPanel:Show()
        else
            recipientPanel:Hide()
        end
        updateRecipientList()
        if GameTooltip:GetOwner() == recipientToggleButton then
            GameTooltip:SetText(listenersExpanded and "Hide listeners" or "Show listeners")
        end
    end)
    recipientToggleButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(listenersExpanded and "Hide listeners" or "Show listeners")
        GameTooltip:Show()
    end)
    recipientToggleButton:SetScript("OnLeave", GameTooltip_Hide)

    recipientScrollFrame = CreateFrame(
        "ScrollFrame", "TrialChatRecipientsScrollFrame", recipientPanel, "FauxScrollFrameTemplate")
    recipientScrollFrame:EnableMouseWheel(true)
    recipientScrollFrame:SetPoint("TOPLEFT", recipientPanel, "TOPLEFT", 6, -48)
    recipientScrollFrame:SetPoint("BOTTOMRIGHT", recipientPanel, "BOTTOMRIGHT", -24, 6)
    recipientScrollFrame:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(
            self, offset, RECIPIENT_ROW_HEIGHT, updateRecipientList)
    end)
    recipientScrollFrame:SetScript("OnMouseWheel", function(self, delta)
        local scrollBar = self.ScrollBar
            or _G[self:GetName() .. "ScrollBar"]
        if scrollBar then
            scrollBar:SetValue(scrollBar:GetValue() - delta * RECIPIENT_ROW_HEIGHT)
        end
    end)

    addListenerInput = CreateFrame("EditBox", nil, recipientPanel, "InputBoxTemplate")
    addListenerInput:SetSize(112, 24)
    addListenerInput:SetPoint("BOTTOMLEFT", recipientPanel, "BOTTOMLEFT", 8, 8)
    addListenerInput:SetAutoFocus(false)
    addListenerInput:SetMaxLetters(64)
    addListenerInput:HookScript("OnEditFocusGained", updateChatWindowAlpha)
    addListenerInput:HookScript("OnEditFocusLost", updateChatWindowAlpha)
    addListenerInput:SetScript("OnEnterPressed", function(self)
        local name = strtrim(self:GetText() or "")
        if name == "" then return end

        if isSelf(name) then
            showTrialChatNotice("|cffff3333[TrialChat] You are already in the listener list.|r")
            return
        end
        if string.find(name, "[%c%s|]") then
            showTrialChatNotice("|cffff3333[TrialChat] Enter a character name, optionally followed by -Realm.|r")
            return
        end

        local key = normalizeName(name)
        local permanentListeners = getPermanentListeners()
        if permanentListeners[key] then
            showTrialChatNotice("|cffff3333[TrialChat] That listener is already saved.|r")
            return
        end

        permanentListeners[key] = name
        self:SetText("")
        updateRecipientList()
    end)
    addListenerInput:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    local addListenerButton = CreateFrame("Button", nil, recipientPanel, "UIPanelButtonTemplate")
    addListenerButton:SetSize(38, 22)
    addListenerButton:SetPoint("LEFT", addListenerInput, "RIGHT", 4, 0)
    addListenerButton:SetText("Add")
    addListenerButton:SetScript("OnClick", function()
        addListenerInput:GetScript("OnEnterPressed")(addListenerInput)
    end)

    recipientScrollFrame:ClearAllPoints()
    recipientScrollFrame:SetPoint("TOPLEFT", recipientPanel, "TOPLEFT", 6, -32)
    recipientScrollFrame:SetPoint("BOTTOMRIGHT", recipientPanel, "BOTTOMRIGHT", -24, 38)

    recipientPanel:SetScript("OnSizeChanged", function()
        updateRecipientList()
    end)
    recipientPanel:Hide()

    chatWindow:SetScript("OnShow", function()
        if listenersExpanded then
            recipientPanel:Show()
        end
        updateChatWindowAlpha()
    end)
    chatWindow:SetScript("OnHide", function()
        recipientPanel:Hide()
    end)

    local resizeGrip = CreateFrame("Button", nil, chatWindow)
    resizeGrip:SetSize(16, 16)
    resizeGrip:SetPoint("BOTTOMRIGHT", chatWindow, "BOTTOMRIGHT", -5, 5)
    resizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizeGrip:SetScript("OnMouseDown", function(self)
        self:GetParent():StartSizing("BOTTOMRIGHT")
    end)
    resizeGrip:SetScript("OnMouseUp", function(self)
        local frame = self:GetParent()
        frame:StopMovingOrSizing()
        saveChatWindowSettings()
    end)

    chatLog = CreateFrame("ScrollingMessageFrame", nil, chatWindow)
    chatLog:SetFontObject(ChatFontNormal)
    chatLog:SetMaxLines(200)
    chatLog:SetFading(false)
    chatLog:SetJustifyH("LEFT")
    chatLog:SetHyperlinksEnabled(true)
    chatLog:EnableMouse(true)
    chatLog:SetScript("OnHyperlinkClick", function(_, link, text, button)
        TrialChatCommon.HandleHyperlinkClick(link, text, button)
    end)
    chatLog:SetScript("OnHyperlinkEnter", function(self, link, text)
        GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
        if string.sub(link or "", 1, 6) == "tcurl:" then
            GameTooltip:SetText("Click to copy URL")
        elseif string.sub(link or "", 1, 7) == "player:"
            or string.sub(link or "", 1, 9) == "tcplayer:" then
            GameTooltip:SetText("Click for player options: " .. (text or "player"))
        else
            GameTooltip:SetHyperlink(link)
        end
        GameTooltip:Show()
    end)
    chatLog:SetScript("OnHyperlinkLeave", function()
        GameTooltip_Hide()
    end)
    chatLog:EnableMouseWheel(true)
    chatLog:SetScript("OnMouseWheel", function(self, delta)
        if delta > 0 then
            self:ScrollUp()
        else
            self:ScrollDown()
        end
    end)
    for _, line in ipairs(getChatHistory()) do
        if type(line) == "string" then
            chatLog:AddMessage(TrialChatCommon.RemovePlayerLinks(line))
        end
    end
    chatLog:ScrollToBottom()

    chatInput = CreateFrame("EditBox", nil, chatWindow, "InputBoxTemplate")
    chatInput:SetAutoFocus(false)
    chatInput:SetMaxLetters(MAX_MESSAGE_BYTES)
    TrialChatCommon.RegisterLinkInput(chatInput)
    chatInput:HookScript("OnEditFocusGained", updateChatWindowAlpha)
    chatInput:HookScript("OnEditFocusLost", updateChatWindowAlpha)
    chatInput:SetScript("OnEnterPressed", function(self)
        local message = self:GetText()
        self:SetText("")
        if strtrim(message or "") ~= "" then
            sendTrialChatMessage(message)
        end
        self:SetFocus()
    end)
    chatInput:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    updateChatContentLayout()
    chatWindow:Hide()
    updateRecipientList()
end

openChatWindow = function(focusInput)
    createChatWindow()
    updateRecipientList()
    chatWindow:Show()
    if focusInput then
        chatInput:SetFocus()
    end
    updateChatWindowAlpha()
end

showTrialChatNotice = function(message)
    openChatWindow(false)
    chatLog:AddMessage(message)
    chatLog:ScrollToBottom()
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
                    openChatWindow(true)
                end
            end)
            slashOpenHooks[editBox] = true
        end
    end
end

local function showMinimapTooltip(button)
    GameTooltip:SetOwner(button, "ANCHOR_LEFT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("TrialChat")
    GameTooltip:AddLine(
        chatWindow and chatWindow:IsShown() and "Click to hide TrialChat."
            or "Click to show TrialChat.",
        1, 1, 1)
    GameTooltip:AddLine("Right-click for group chats.", 0.7, 0.7, 0.7)
    GameTooltip:AddLine("Drag to move this button.", 0.7, 0.7, 0.7)
    GameTooltip:Show()
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

    minimapButton:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            TrialChatGroups:ToggleMenu(minimapButton)
            return
        end

        if chatWindow:IsShown() then
            chatWindow:Hide()
        else
            openChatWindow(true)
        end
        if GameTooltip:GetOwner() == minimapButton then
            showMinimapTooltip(minimapButton)
        end
    end)
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
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("CHAT_MSG_ADDON")
frame:SetScript("OnEvent", function(_, _, prefix, message, channel, sender)
    if prefix ~= PREFIX or not message or not sender or isSelf(sender) then return end
    if #message > MAX_MESSAGE_BYTES + #MESSAGE_TAG then return end

    local now = GetTime()
    if string.sub(message, 1, #CLASS_TAG) == CLASS_TAG then
        rememberClass(sender, string.sub(message, #CLASS_TAG + 1))
        updateRecipientList()
        return
    end

    if message == PING and channel == "WHISPER" then
        C_ChatInfo.SendAddonMessage(PREFIX, PONG, "WHISPER", sender)
        activeListeners[sender] = now
        updateRecipientList()
        return
    end

    if message == PONG and channel == "WHISPER" then
        local pingTime = pendingPings[normalizeName(sender)]
        if pingTime and now - pingTime <= LISTENER_TIMEOUT then
            activeListeners[sender] = now
        end
        pendingPings[normalizeName(sender)] = nil
        updateRecipientList()
        return
    end

    local messageTag = string.sub(message, 1, #EMOTE_TAG) == EMOTE_TAG
        and EMOTE_TAG or MESSAGE_TAG
    if string.sub(message, 1, #messageTag) ~= messageTag then return end
    local isEmote = messageTag == EMOTE_TAG
    local chatText = TrialChatCommon.DecodeMessageMarkup(
        string.sub(message, #messageTag + 1))
    chatText = TrialChatCommon.NormalizeMessageMarkup(chatText)
    local shortSender = string.match(sender, "^([^-]+)") or sender
    activeListeners[sender] = now
    updateRecipientList()

    if isEmote then
        if channel == "RAID" then
            printIncomingMessage("Raid", shortSender, chatText, "|cffff7d0a",
                "|cffff7d0a", sender, true)
        elseif channel == "PARTY" then
            printIncomingMessage("Party", shortSender, chatText, "|cffff7d0a",
                "|cffff7d0a", sender, true)
        elseif channel == "WHISPER" then
            printIncomingMessage("Nearby", shortSender, chatText, "|cffff7d0a",
                "|cffff7d0a", sender, true)
        end
        return
    end

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
    updateRecipientList()
end)

sendTrialChatMessage = function(msg)
    msg = strtrim(msg or "")
    if msg == "" then
        showTrialChatNotice("|cffff3333[TrialChat] Enter a message to send with /tc.|r")
        return
    end

    if #msg > MAX_MESSAGE_BYTES then
        showTrialChatNotice("|cffff3333[TrialChat] Message is too long (maximum "
            .. MAX_MESSAGE_BYTES .. " bytes).|r")
        return
    end

    local isEmote
    local emoteToken
    local emoteTarget
    msg, isEmote, emoteToken, emoteTarget = TrialChatCommon.ParseEmote(msg)
    if not msg then
        showTrialChatNotice("|cffff3333[TrialChat] Enter the text for your emote.|r")
        return
    end
    if #msg > MAX_MESSAGE_BYTES then
        showTrialChatNotice("|cffff3333[TrialChat] Message is too long (maximum "
            .. MAX_MESSAGE_BYTES .. " bytes).|r")
        return
    end
    TrialChatCommon.PerformEmote(emoteToken, emoteTarget)
    local payload = (isEmote and EMOTE_TAG or MESSAGE_TAG)
        .. TrialChatCommon.EncodeMessageMarkup(msg)
    if #payload > 255 then
        showTrialChatNotice(
            "|cffff3333[TrialChat] This message is too long to send with its links.|r")
        return
    end
    local classPayload = playerClass and RAID_CLASS_COLORS[playerClass]
        and CLASS_TAG .. playerClass or nil
    local sentToGroup = IsInGroup()
    local inRaid = IsInRaid()
    local sentWhisperCount = 0
    local sentNearbyWhisperCount = 0
    local groupMembers = getGroupMembers()

    if sentToGroup and not inRaid then
        local groupChannel = "PARTY"
        if classPayload then
            C_ChatInfo.SendAddonMessage(PREFIX, classPayload, groupChannel)
        end
        C_ChatInfo.SendAddonMessage(PREFIX, payload, groupChannel)
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
                C_ChatInfo.SendAddonMessage(PREFIX, classPayload, "WHISPER", targetPlayer)
            end
            C_ChatInfo.SendAddonMessage(PREFIX, payload, "WHISPER", targetPlayer)
            sentWhisperCount = sentWhisperCount + 1
            if not isGroupMember then
                sentNearbyWhisperCount = sentNearbyWhisperCount + 1
            end
        end
    end

    local myShortName = string.match(playerName, "^([^-]+)") or playerName
    local myNameColor = getClassColor(playerClass)
    local messageColor = isEmote and "|cffff7d0a"
        or sentToGroup and "|cffff7d0a" or "|cffffcc00"
    if sentToGroup and sentNearbyWhisperCount > 0 then
        printMessage(myShortName, msg, messageColor, myNameColor, isEmote)
    elseif sentToGroup then
        printMessage(myShortName, msg, messageColor, myNameColor, isEmote)
    elseif sentWhisperCount > 0 then
        printMessage(myShortName, msg, messageColor, myNameColor, isEmote)
    else
        printMessage(myShortName, msg, messageColor, myNameColor, isEmote)
        showTrialChatNotice(
            "|cffff7d0aBut nobody heard that, because there are no players using TrialChat around.|r")
    end
    updateRecipientList()
end

SLASH_TRIALCHAT1 = "/tc"
SLASH_TRIALCHAT2 = "/trialchat"
SlashCmdList["TRIALCHAT"] = function(msg)
    msg = strtrim(msg or "")
    if msg == "" then
        openChatWindow(true)
        return
    end

    sendTrialChatMessage(msg)
end

BINDING_NAME_TRIALCHAT_OPEN = "Open TrialChat and focus chat"

function TrialChat_Open()
    C_Timer.After(0, function()
        openChatWindow(true)
    end)
end

local hookFrame = CreateFrame("Frame")
hookFrame:RegisterEvent("PLAYER_LOGIN")
hookFrame:RegisterEvent("PLAYER_LOGOUT")
hookFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGOUT" then
        saveChatWindowSettings()
        return
    end

    createChatWindow()
    createMinimapButton()
    hookSlashOpenShortcut()
end)
