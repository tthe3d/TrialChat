local PREFIX = "TrialChat"
local GROUP_TAG = "TCG1|"
local MAX_GROUP_NAME_BYTES = 24
local MAX_PASSWORD_BYTES = 32
local MAX_GROUP_MESSAGE_BYTES = 190
local MAX_CHAT_HISTORY = 200
local MAX_HISTORY_SYNC_MESSAGES = 50
local HISTORY_CHUNK_BYTES = 170
local MEMBER_TIMEOUT = 90
local MEMBER_UPDATE_INTERVAL = 30
local _, playerClass = UnitClass("player")

local Groups = {}
TrialChatGroups = Groups

local activeGroups = {}
local pendingJoins = {}
local nearbyPlayers = {}
local playerName, playerRealm = UnitFullName("player")
local selfName = playerName
if selfName and playerRealm and playerRealm ~= "" then
    selfName = selfName .. "-" .. playerRealm
end

local function normalizeName(name)
    return strlower(name or "")
end

local function getSavedGroups()
    TrialChatDB = TrialChatDB or {}
    TrialChatDB.groups = TrialChatDB.groups or {}
    return TrialChatDB.groups
end

local function savedGroupIsCreator(group)
    if type(group) ~= "table" then return false end
    if group.isCreator ~= nil then return group.isCreator == true end
    return not group.creatorName and not group.memberName
end

local function getGroupId(name)
    return normalizeName(name)
end

local function showNotice(message)
    print("|cffff7d0a[TrialChat Groups]|r " .. message)
end

local function getSelfKey()
    return normalizeName(selfName or UnitName("player"))
end

local function isSelf(name)
    local key = normalizeName(name)
    return key == getSelfKey() or key == normalizeName(UnitName("player"))
end

local function namesMatch(left, right)
    if normalizeName(left) == normalizeName(right) then return true end
    if string.find(left or "", "-", 1, true)
        and string.find(right or "", "-", 1, true) then
        return false
    end

    local leftShort = string.match(left or "", "^([^-]+)")
    local rightShort = string.match(right or "", "^([^-]+)")
    return leftShort ~= nil and normalizeName(leftShort) == normalizeName(rightShort)
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

local saveGroup
local sendHistoryToMember

local function addKnownMember(session, name)
    if not name or name == "" or isSelf(name) then return end
    session.knownMembers = session.knownMembers or {}
    session.knownMembers[normalizeName(name)] = name
    session.reconnectName = name
end

local function getClassColor(classFile)
    local color = classFile and RAID_CLASS_COLORS[classFile]
    if not color then return nil end
    if color.colorStr then return "|c" .. color.colorStr end
    return string.format("|cff%02x%02x%02x",
        math.floor(color.r * 255),
        math.floor(color.g * 255),
        math.floor(color.b * 255))
end

local function addMember(session, name, classFile)
    if not name or name == "" then return end

    addKnownMember(session, name)
    local key = findMemberKey(session, name) or normalizeName(name)
    local existing = session.members[key]
    session.members[key] = {
        name = name,
        lastSeen = GetTime(),
        classFile = classFile or (existing and existing.classFile)
            or (isSelf(name) and playerClass),
    }
    if session.window then
        session.window:UpdateMembers()
    end
    if activeGroups[session.id] == session and saveGroup then
        saveGroup(session)
    end
end

local function removeMember(session, name)
    if not name or name == "" then return end

    local key = findMemberKey(session, name)
    if key then session.members[key] = nil end
    if key and session.reconnectName
        and namesMatch(session.reconnectName, name) then
        local mostRecentMember
        for _, member in pairs(session.members) do
            if not isSelf(member.name)
                and (not mostRecentMember or member.lastSeen > mostRecentMember.lastSeen) then
                mostRecentMember = member
            end
        end
        if mostRecentMember then
            session.reconnectName = mostRecentMember.name
        end
    end
    if session.window then
        session.window:UpdateMembers()
    end
    if activeGroups[session.id] == session and saveGroup then
        saveGroup(session)
    end
end

local function sendGroupProtocol(session, kind, target, body)
    if not target then return false end
    if kind == "MSG2" or kind == "EMOTE2" then
        body = TrialChatCommon.EncodeMessageMarkup(body or "")
    end
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

local function updateWindowAlpha(window)
    if not window or not window.frame then return end

    local mouseOver = window.frame:IsShown() and window.frame:IsMouseOver()
        or (window.memberPanel and window.memberPanel:IsShown()
            and window.memberPanel:IsMouseOver())
    local inputHasFocus = window.input and window.input:HasFocus()
    local recentMessage = window.lastMessageAt
        and GetTime() - window.lastMessageAt < 10
    local alpha = (mouseOver or inputHasFocus or recentMessage) and 1 or 0.45
    window.frame:SetAlpha(alpha)
    if window.memberPanel then
        window.memberPanel:SetAlpha(alpha)
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

local function renderGroupMessage(session, entry)
    local shortSender = string.match(entry.sender, "^([^-]+)") or entry.sender
    local memberKey = findMemberKey(session, entry.sender)
    local member = memberKey and session.members[memberKey]
    local nameColor = entry.isEmote and "|cffff7d0a"
        or getClassColor(member and member.classFile) or "|cffffcc00"
    local timestamp = "|cffaaaaaa[" .. date("%H:%M", entry.timestamp) .. "]|r "
    local senderText = nameColor .. shortSender .. "|r"
    local displayMessage = TrialChatCommon.FormatMessageText(entry.message)
    if entry.isEmote then
        return timestamp .. senderText .. " "
            .. displayMessage .. "|r"
    end
    return timestamp .. senderText .. ": " .. displayMessage
end

local function rebuildGroupLog(session)
    local window = session.window
    if not window then return end

    window.log:Clear()
    for _, item in ipairs(session.history or {}) do
        local line = type(item) == "table"
            and renderGroupMessage(session, item) or item
        if type(line) == "string" then
            window.log:AddMessage(TrialChatCommon.RemovePlayerLinks(line))
        end
    end
    window.log:ScrollToBottom()
end

local function addGroupMessage(
    session, sender, message, isEmote, messageId, timestamp, isHistorical,
    shouldNotify)
    if isHistorical then
        addKnownMember(session, sender)
    else
        addMember(session, sender)
    end
    message = TrialChatCommon.NormalizeMessageMarkup(message)
    session.history = type(session.history) == "table" and session.history or {}

    if messageId then
        for _, item in ipairs(session.history) do
            if type(item) == "table" and item.id == messageId then
                return false
            end
        end
    else
        session.messageCounter = (session.messageCounter or 0) + 1
        messageId = makeMessageId(sender, session.messageCounter)
    end
    timestamp = timestamp or GetServerTime()

    if shouldNotify then
        PlaySound(SOUNDKIT.TELL_MESSAGE)
    end

    local entry = {
        id = messageId,
        sender = sender,
        message = message,
        isEmote = isEmote,
        timestamp = timestamp,
    }
    session.history[#session.history + 1] = entry
    table.sort(session.history, function(left, right)
        local leftTimestamp = type(left) == "table" and left.timestamp or 0
        local rightTimestamp = type(right) == "table" and right.timestamp or 0
        if leftTimestamp == rightTimestamp then
            local leftId = type(left) == "table" and left.id or tostring(left)
            local rightId = type(right) == "table" and right.id or tostring(right)
            return leftId < rightId
        end
        return leftTimestamp < rightTimestamp
    end)
    while #session.history > MAX_CHAT_HISTORY do
        table.remove(session.history, 1)
    end

    if activeGroups[session.id] == session and saveGroup then
        saveGroup(session)
    end
    if session.window then
        rebuildGroupLog(session)
        session.window.lastMessageAt = GetTime()
        updateWindowAlpha(session.window)
        C_Timer.After(10, function()
            updateWindowAlpha(session.window)
        end)
    end
    return true, entry
end

local function sendHistoryEntry(session, target, entry, initialDelay)
    local emoteFlag = entry.isEmote and "E" or "M"
    local serialized = TrialChatCommon.EncodeMessageMarkup(table.concat({
        entry.id, tostring(entry.timestamp), entry.sender, emoteFlag, entry.message,
    }, ":"))
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
        local serialized = TrialChatCommon.EncodeMessageMarkup(table.concat({
            entry.id, tostring(entry.timestamp), entry.sender,
            entry.isEmote and "E" or "M", entry.message,
        }, ":"))
        local chunks = math.ceil(#serialized / HISTORY_CHUNK_BYTES)
        sendHistoryEntry(session, target, entry, delay)
        delay = delay + chunks * 0.1
    end
end

local pendingHistoryChunks = {}

local function receiveHistoryChunk(session, sender, body)
    local messageId, chunkIndex, chunkCount, chunk =
        string.match(body, "^([%x%-]+):(%d+):(%d+):(.*)$")
    chunkIndex = tonumber(chunkIndex)
    chunkCount = tonumber(chunkCount)
    if not messageId or not chunkIndex or not chunkCount
        or chunkCount < 1 or chunkCount > 8
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

    local serialized = TrialChatCommon.DecodeMessageMarkup(
        table.concat(transfer.chunks))
    local entryId, timestamp, entrySender, emoteFlag, message =
        string.match(serialized, "^([%x%-]+):(%d+):([^:]+):([ME]):(.*)$")
    timestamp = tonumber(timestamp)
    if entryId ~= messageId or not timestamp then return end

    local added, entry = addGroupMessage(session, entrySender, message,
        emoteFlag == "E", entryId, timestamp, true)
    if added and activeGroups[session.id] == session then
        for _, member in pairs(session.members) do
            if not namesMatch(member.name, selfName or UnitName("player"))
                and not namesMatch(member.name, sender) then
                sendHistoryEntry(session, member.name, entry)
            end
        end
    end
end

local function createGroupWindow(session)
    if session.window then
        session.window.frame:Show()
        session.window.input:SetFocus()
        updateWindowAlpha(session.window)
        return
    end

    local window = {}
    session.window = window
    local frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    window.frame = frame
    frame:SetSize(session.width or 580, session.height or 420)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetFrameLevel(100)
    frame:SetMovable(true)
    frame:SetResizable(true)
    frame:SetResizeBounds(320, 320, 1200, 900)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
    end)
    frame:SetScript("OnSizeChanged", function(_, width, height)
        session.width = width
        session.height = height
        local savedGroup = getSavedGroups()[session.id]
        if savedGroup then
            savedGroup.width = width
            savedGroup.height = height
        end
        if window.UpdateMembers then
            window:UpdateMembers()
        end
    end)
    frame:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    frame:SetBackdropColor(0.04, 0.04, 0.04, 0.95)
    frame:SetAlpha(0.45)
    frame:HookScript("OnEnter", function()
        updateWindowAlpha(window)
    end)
    frame:HookScript("OnLeave", function()
        updateWindowAlpha(window)
    end)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -12)
    title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -12)
    title:SetJustifyH("CENTER")
    title:SetText(session.name)

    window.onlineMemberCount = frame:CreateFontString(
        nil, "OVERLAY", "GameFontNormalSmall")
    window.onlineMemberCount:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -32)
    window.onlineMemberCount:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, -32)
    window.onlineMemberCount:SetJustifyH("CENTER")

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)
    closeButton:SetScript("OnClick", function()
        frame:Hide()
    end)

    window.log = CreateFrame("ScrollingMessageFrame", nil, frame)
    window.log:SetFontObject(ChatFontNormal)
    window.log:SetMaxLines(200)
    window.log:SetFading(false)
    window.log:SetJustifyH("LEFT")
    window.log:SetHyperlinksEnabled(true)
    window.log:EnableMouse(true)
    window.log:SetScript("OnHyperlinkClick", function(_, link, text, button)
        TrialChatCommon.HandleHyperlinkClick(link, text, button)
    end)
    window.log:SetScript("OnHyperlinkEnter", function(self, link, text)
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
    window.log:SetScript("OnHyperlinkLeave", function()
        GameTooltip_Hide()
    end)
    window.log:EnableMouseWheel(true)
    window.log:SetScript("OnMouseWheel", function(self, delta)
        if delta > 0 then
            self:ScrollUp()
        else
            self:ScrollDown()
        end
    end)
    for _, line in ipairs(session.history or {}) do
        local rendered = type(line) == "table"
            and renderGroupMessage(session, line) or line
        if type(rendered) == "string" then
            window.log:AddMessage(TrialChatCommon.RemovePlayerLinks(rendered))
        end
    end
    window.log:ScrollToBottom()
    window.log:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -58)
    window.log:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 48)

    local memberPanel = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    window.memberPanel = memberPanel
    memberPanel:SetPoint("TOPLEFT", frame, "TOPRIGHT", 0, 0)
    memberPanel:SetPoint("BOTTOMLEFT", frame, "BOTTOMRIGHT", 0, 0)
    memberPanel:SetWidth(170)
    memberPanel:SetFrameStrata("DIALOG")
    memberPanel:SetFrameLevel(frame:GetFrameLevel() + 1)
    memberPanel:EnableMouse(true)
    memberPanel:HookScript("OnEnter", function()
        updateWindowAlpha(window)
    end)
    memberPanel:HookScript("OnLeave", function()
        updateWindowAlpha(window)
    end)
    memberPanel:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    memberPanel:SetBackdropColor(0.02, 0.02, 0.02, 0.75)

    window.memberTitle = memberPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    window.memberTitle:SetPoint("TOP", memberPanel, "TOP", 0, -8)

    window.memberToggleButton = CreateFrame(
        "Button", nil, frame, "UIPanelButtonTemplate")
    window.memberToggleButton:SetSize(22, 18)
    window.memberToggleButton:SetPoint("TOP", title, "BOTTOM", 70, -2)
    window.membersExpanded = false
    window.memberToggleButton:SetScript("OnClick", function()
        window.membersExpanded = not window.membersExpanded
        if frame:IsShown() and window.membersExpanded then
            memberPanel:Show()
        else
            memberPanel:Hide()
        end
        window:UpdateMembers()
        updateWindowAlpha(window)
        if GameTooltip:GetOwner() == window.memberToggleButton then
            GameTooltip:SetText(window.membersExpanded
                and "Hide members" or "Show members")
        end
    end)
    window.memberToggleButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(window.membersExpanded
            and "Hide members" or "Show members")
        GameTooltip:Show()
    end)
    window.memberToggleButton:SetScript("OnLeave", GameTooltip_Hide)

    local memberScroll = CreateFrame(
        "ScrollFrame", nil, memberPanel, "FauxScrollFrameTemplate")
    window.memberScroll = memberScroll
    memberScroll:SetPoint("TOPLEFT", memberPanel, "TOPLEFT", 6, -28)
    memberScroll:SetPoint("BOTTOMRIGHT", memberPanel, "BOTTOMRIGHT", -24, 6)
    memberScroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, 18, function()
            window:UpdateMembers()
        end)
    end)

    local input = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    window.input = input
    input:SetAutoFocus(false)
    input:SetMaxLetters(MAX_GROUP_MESSAGE_BYTES)
    TrialChatCommon.RegisterLinkInput(input)
    input:SetHeight(26)
    input:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 14)
    input:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 14)
    input:HookScript("OnEditFocusGained", function()
        updateWindowAlpha(window)
    end)
    input:HookScript("OnEditFocusLost", function()
        updateWindowAlpha(window)
    end)
    input:SetScript("OnEnterPressed", function(self)
        local message = strtrim(self:GetText() or "")
        self:SetText("")
        if message == "" then
            self:SetFocus()
            return
        end
        local isEmote
        local emoteToken
        local emoteTarget
        message, isEmote, emoteToken, emoteTarget =
            TrialChatCommon.ParseEmote(message)
        if not message then
            showNotice("Enter the text for your emote.")
            self:SetFocus()
            return
        end
        if #message > MAX_GROUP_MESSAGE_BYTES then
            showNotice("Group messages are limited to " .. MAX_GROUP_MESSAGE_BYTES .. " bytes.")
            self:SetFocus()
            return
        end
        local sender = selfName or UnitName("player")
        session.messageCounter = (session.messageCounter or 0) + 1
        local messageId = makeMessageId(sender, session.messageCounter)
        local timestamp = GetServerTime()
        local messageKind = isEmote and "EMOTE2" or "MSG2"
        local body = table.concat({
            messageId, tostring(timestamp), isEmote and "E" or "M", message,
        }, ":")
        local encodedBody = TrialChatCommon.EncodeMessageMarkup(body)
        local payload = GROUP_TAG .. messageKind .. "|" .. session.id .. "|" .. encodedBody
        if #payload > 255 then
            showNotice("That message is too long for the addon chat protocol.")
            self:SetFocus()
            return
        end

        TrialChatCommon.PerformEmote(emoteToken, emoteTarget)
        addGroupMessage(session, sender, message, isEmote, messageId, timestamp)
        sendToMembers(session, messageKind, body)
        self:SetFocus()
    end)
    input:SetScript("OnEscapePressed", function(self)
        self:ClearFocus()
    end)

    local resizeButton = CreateFrame("Button", nil, frame)
    resizeButton:SetSize(16, 16)
    resizeButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -6, 6)
    resizeButton:SetNormalTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Up")
    resizeButton:SetHighlightTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Highlight")
    resizeButton:SetPushedTexture("Interface/ChatFrame/UI-ChatIM-SizeGrabber-Down")
    resizeButton:SetScript("OnMouseDown", function()
        frame:StartSizing("BOTTOMRIGHT")
    end)
    resizeButton:SetScript("OnMouseUp", function()
        frame:StopMovingOrSizing()
        if saveGroup then saveGroup(session) end
    end)

    window.rows = {}
    function window:UpdateMembers()
        local names = {}
        for key, member in pairs(session.members) do
            names[#names + 1] = {
                key = key,
                name = member.name,
                classFile = member.classFile,
            }
        end
        table.sort(names, function(left, right)
            return strlower(left.name) < strlower(right.name)
        end)

        self.memberTitle:SetText("Members (" .. #names .. ")")
        self.onlineMemberCount:SetText("Online members (" .. #names .. ")")
        self.memberToggleButton:SetText(self.membersExpanded and "<" or ">")
        local visibleRows = math.max(1,
            math.floor(self.memberScroll:GetHeight() / 18))
        FauxScrollFrame_Update(self.memberScroll, #names, visibleRows, 18)
        local offset = FauxScrollFrame_GetOffset(self.memberScroll)

        while #self.rows < #names do
            local row = CreateFrame("Button", nil, memberPanel)
            row:SetHeight(18)
            row:SetPoint("TOPLEFT", memberScroll, "TOPLEFT",
                2, -(#self.rows) * 18)
            row:SetPoint("RIGHT", memberScroll, "RIGHT", -4, 0)
            row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.text:SetAllPoints()
            row.text:SetJustifyH("LEFT")
            row.text:SetWordWrap(false)
            row:RegisterForClicks("RightButtonUp")
            row:SetScript("OnClick", function(self, button)
                if button == "RightButton" then
                    TrialChatCommon.ShowPlayerOptions(
                        self.memberName, self.memberName, button)
                end
            end)
            row:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                GameTooltip:SetText("Right-click for player options.")
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", GameTooltip_Hide)
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")
            self.rows[#self.rows + 1] = row
        end

        for index, row in ipairs(self.rows) do
            local member = names[offset + index]
            if member and index <= visibleRows then
                local nameColor = getClassColor(member.classFile)
                local nameText = nameColor and (nameColor .. member.name .. "|r")
                    or member.name
                row.text:SetText(nameText)
                row.memberName = member.name
                row:Show()
            else
                row:Hide()
            end
        end
    end

    frame:HookScript("OnShow", function()
        if window.membersExpanded then
            memberPanel:Show()
        end
        window:UpdateMembers()
    end)
    frame:HookScript("OnHide", function()
        memberPanel:Hide()
    end)

    memberPanel:Hide()
    frame:Hide()
    window:UpdateMembers()
end

saveGroup = function(session)
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
        memberName = session.reconnectName or session.targetName,
        isCreator = session.isCreator == true,
        creatorName = session.creatorName,
        width = session.width,
        height = session.height,
        history = session.history or {},
        knownMembers = knownMembers,
    }
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

local function activateGroup(session)
    pendingJoins[session.id] = nil
    activeGroups[session.id] = session
    session.members = session.members or {}
    addMember(session, selfName or UnitName("player"))
    saveGroup(session)
    createGroupWindow(session)
    session.window.frame:Show()
    session.window.input:SetFocus()
end

local function completePendingJoin(session, sender)
    addMember(session, sender)
    activateGroup(session)
    sendToMembers(session, "MEMBER", selfName or UnitName("player"))
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

local function joinGroup(name, password, targetName, savedGroup)
    local id = getGroupId(name)
    local active = activeGroups[id]
    if active then
        active.window.frame:Show()
        active.window.input:SetFocus()
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
        isCreator = savedGroup and savedGroup.isCreator
            and savedGroup.creatorName and namesMatch(savedGroup.creatorName, selfName),
        creatorName = savedGroup and savedGroup.creatorName,
        width = savedGroup and savedGroup.width,
        height = savedGroup and savedGroup.height,
        history = savedGroup and type(savedGroup.history) == "table"
            and savedGroup.history or {},
        knownMembers = getKnownMembers(savedGroup),
        reconnectName = joinCandidates[1],
        joinCandidates = joinCandidates,
        hasSavedGroup = type(savedGroup) == "table",
    }
    pendingJoins[id] = session
    startJoinAttempt(session, 1)
end

startJoinAttempt = function(session, candidateIndex)
    local id = session.id
    local targetName = session.joinCandidates[candidateIndex]
    session.targetName = targetName
    if not sendGroupProtocol(session, "HELLO", targetName, session.password) then
        pendingJoins[id] = nil
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
        if session.isCreator or session.hasSavedGroup then
            showNotice("No saved group member replied. Opening your saved group locally.")
            createGroup(session.name, session.password, getSavedGroups()[id] or {
                name = session.name,
                password = session.password,
                isCreator = session.isCreator == true,
                creatorName = session.creatorName,
                memberName = session.reconnectName,
                history = session.history,
                knownMembers = session.knownMembers,
                width = session.width,
                height = session.height,
            })
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

createGroup = function(name, password, savedGroup)
    local id = getGroupId(name)
    if activeGroups[id] then
        activeGroups[id].window.frame:Show()
        activeGroups[id].window.input:SetFocus()
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
        isCreator = savedGroup
            and savedGroupIsCreator(savedGroup) or not savedGroup,
        creatorName = savedGroup and savedGroup.creatorName
            or (not savedGroup and (selfName or UnitName("player"))),
        width = savedGroup and savedGroup.width,
        height = savedGroup and savedGroup.height,
        history = savedGroup and type(savedGroup.history) == "table"
            and savedGroup.history or {},
        knownMembers = getKnownMembers(savedGroup),
        reconnectName = savedGroup and savedGroup.memberName,
    }
    activateGroup(session)
end

local function validateGroupDetails(name, password)
    name = strtrim(name or "")
    password = password or ""
    if #name == 0 or #name > MAX_GROUP_NAME_BYTES
        or not string.match(name, "^[%w _]+$") then
        showNotice("Use a group name of 1-" .. MAX_GROUP_NAME_BYTES
            .. " letters, numbers, spaces, or underscores.")
        return nil
    end
    if #password == 0 or #password > MAX_PASSWORD_BYTES
        or string.find(password, "[%c]") then
        showNotice("Enter a password of 1-" .. MAX_PASSWORD_BYTES .. " characters.")
        return nil
    end
    return name, password
end

local dialog
openGroupDialog = function(mode, preset)
    if not dialog then
        dialog = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        dialog:SetSize(340, 250)
        dialog:SetPoint("CENTER")
        dialog:SetFrameStrata("DIALOG")
        dialog:SetFrameLevel(120)
        dialog:EnableMouse(true)
        dialog:SetBackdrop({
            bgFile = "Interface/Tooltips/UI-Tooltip-Background",
            edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        dialog:SetBackdropColor(0.04, 0.04, 0.04, 0.98)

        dialog.title = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        dialog.title:SetPoint("TOP", dialog, "TOP", 0, -14)

        local closeButton = CreateFrame("Button", nil, dialog, "UIPanelCloseButton")
        closeButton:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -2, -2)
        closeButton:SetScript("OnClick", function()
            dialog:Hide()
        end)

        local nameLabel = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        nameLabel:SetPoint("TOPLEFT", dialog, "TOPLEFT", 18, -48)
        nameLabel:SetText("Group name")
        dialog.nameInput = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
        dialog.nameInput:SetSize(274, 24)
        dialog.nameInput:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 4, -4)
        dialog.nameInput:SetAutoFocus(false)
        dialog.nameInput:SetMaxLetters(MAX_GROUP_NAME_BYTES)

        local passwordLabel = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        passwordLabel:SetPoint("TOPLEFT", dialog.nameInput, "BOTTOMLEFT", -4, -10)
        passwordLabel:SetText("Password")
        dialog.passwordInput = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
        dialog.passwordInput:SetSize(274, 24)
        dialog.passwordInput:SetPoint("TOPLEFT", passwordLabel, "BOTTOMLEFT", 4, -4)
        dialog.passwordInput:SetAutoFocus(false)
        dialog.passwordInput:SetMaxLetters(MAX_PASSWORD_BYTES)
        dialog.passwordInput:SetPassword(true)

        dialog.memberLabel = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        dialog.memberLabel:SetPoint("TOPLEFT", dialog.passwordInput, "BOTTOMLEFT", -4, -10)
        dialog.memberLabel:SetText("Connect through online member")
        dialog.memberInput = CreateFrame("EditBox", nil, dialog, "InputBoxTemplate")
        dialog.memberInput:SetSize(294, 24)
        dialog.memberInput:SetPoint("TOPLEFT", dialog.memberLabel, "BOTTOMLEFT", 4, -4)
        dialog.memberInput:SetAutoFocus(false)
        dialog.memberInput:SetMaxLetters(64)

        dialog.submitButton = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
        dialog.submitButton:SetSize(100, 24)
        dialog.submitButton:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -18, 14)
        dialog.submitButton:SetScript("OnClick", function()
            local name, password = validateGroupDetails(
                dialog.nameInput:GetText(), dialog.passwordInput:GetText())
            if not name then return end

            if dialog.mode == "create" then
                dialog:Hide()
                createGroup(name, password, dialog.preset)
            else
                local memberName = dialog.memberInput:GetText()
                local id = getGroupId(name)
                if not activeGroups[id] and not pendingJoins[id] then
                    memberName = validateMemberName(memberName)
                    if not memberName then return end
                end
                dialog:Hide()
                joinGroup(name, password, memberName, dialog.preset)
            end
        end)

        dialog.passwordInput:SetScript("OnEnterPressed", function()
            if dialog.mode == "join" then
                dialog.memberInput:SetFocus()
            else
                dialog.submitButton:Click()
            end
        end)
        dialog.nameInput:SetScript("OnEnterPressed", function()
            dialog.passwordInput:SetFocus()
        end)
        dialog.memberInput:SetScript("OnEnterPressed", function()
            dialog.submitButton:Click()
        end)
    end

    dialog.mode = mode
    dialog.preset = preset
    dialog.title:SetText(mode == "create" and "Create Group" or "Join Group")
    dialog.submitButton:SetText(mode == "create" and "Create" or "Join")
    dialog.memberLabel:SetShown(mode == "join")
    dialog.memberInput:SetShown(mode == "join")
    dialog.nameInput:SetText(preset and preset.name or "")
    dialog.passwordInput:SetText(preset and preset.password or "")
    dialog.memberInput:SetText(preset and preset.memberName or "")
    dialog:Show()
    dialog.nameInput:SetFocus()
end

local function disconnectSession(id)
    local session = activeGroups[id]
    if not session then return nil end

    sendToMembers(session, "BYE")
    activeGroups[id] = nil
    session.members = {}
    if session.window then
        session.window.frame:Hide()
        session.window.input:ClearFocus()
        session.window:UpdateMembers()
    end
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
        activeGroups[id] = nil
        session.members = {}
        if session.window then
            session.window.frame:Hide()
            session.window.input:ClearFocus()
            session.window:UpdateMembers()
        end
    end
    getSavedGroups()[id] = nil
    showNotice("Deleted " .. (session and session.name or savedGroup.name) .. ".")
end

local menu
local menuRows = {}
local function createMenuRow(index)
    local row = CreateFrame("Button", nil, menu)
    row:SetHeight(24)
    row:SetPoint("TOPLEFT", menu, "TOPLEFT", 8, -30 - (index - 1) * 24)
    row:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -8, -30 - (index - 1) * 24)
    row:SetHighlightTexture("Interface/QuestFrame/UI-QuestTitleHighlight")
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -56, 0)
    row.text:SetJustifyH("LEFT")
    row:SetScript("OnClick", function(self)
        menu:Hide()
        self.action()
    end)
    row.connectButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.connectButton:SetSize(76, 18)
    row.connectButton:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    row.connectButton:SetScript("OnClick", function(self)
        local parent = self:GetParent()
        local savedGroup = parent.savedGroup
        if activeGroups[parent.groupId] then
            menu:Hide()
            StaticPopup_Show("TRIALCHAT_CONFIRM_DISCONNECT",
                parent.groupName, nil, parent.groupId)
        else
            menu:Hide()
            parent.connect(savedGroup)
        end
    end)
    row.connectButton:Hide()

    row.exitButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.exitButton:SetSize(48, 18)
    row.exitButton:SetPoint("RIGHT", row.connectButton, "LEFT", -2, 0)
    row.exitButton:SetText("Exit")
    row.exitButton:SetScript("OnClick", function(self)
        local parent = self:GetParent()
        menu:Hide()
        StaticPopup_Show("TRIALCHAT_CONFIRM_EXIT", parent.groupName,
            nil, parent.groupId)
    end)
    row.exitButton:Hide()

    row.deleteButton = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    row.deleteButton:SetSize(52, 18)
    row.deleteButton:SetPoint("RIGHT", row.connectButton, "LEFT", -2, 0)
    row.deleteButton:SetText("Delete")
    row.deleteButton:SetScript("OnClick", function(self)
        menu:Hide()
        StaticPopup_Show("TRIALCHAT_CONFIRM_DELETE", self:GetParent().groupName,
            nil, self:GetParent().groupId)
    end)
    row.deleteButton:Hide()
    menuRows[index] = row
end

local function createMenu()
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

    menu = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    menu:SetWidth(230)
    menu:SetFrameStrata("DIALOG")
    menu:SetFrameLevel(120)
    menu:EnableMouse(true)
    menu:SetClampedToScreen(true)
    menu:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    menu:SetBackdropColor(0.02, 0.02, 0.02, 0.98)

    menu.title = menu:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    menu.title:SetPoint("TOP", menu, "TOP", 0, -10)
    menu.title:SetText("Groups")

    menu.createButton = CreateFrame("Button", nil, menu, "UIPanelButtonTemplate")
    menu.createButton:SetSize(96, 24)
    menu.createButton:SetScript("OnClick", function()
        menu:Hide()
        openGroupDialog("create")
    end)
    menu.createButton:SetText("Add Group")

    menu.joinButton = CreateFrame("Button", nil, menu, "UIPanelButtonTemplate")
    menu.joinButton:SetSize(96, 24)
    menu.joinButton:SetScript("OnClick", function()
        menu:Hide()
        openGroupDialog("join")
    end)
    menu.joinButton:SetText("Join Group")
end

function Groups:ToggleMenu(anchor)
    if not menu then
        createMenu()
    end
    if menu:IsShown() then
        menu:Hide()
        return
    end

    local savedGroups = getSavedGroups()
    local groups = {}
    for id, group in pairs(savedGroups) do
        if type(group) == "table" and type(group.name) == "string"
            and type(group.password) == "string" then
            groups[#groups + 1] = {
                id = id,
                name = group.name,
                password = group.password,
                memberName = group.memberName,
                isCreator = savedGroupIsCreator(group),
                creatorName = group.creatorName,
                width = group.width,
                height = group.height,
                history = group.history,
                knownMembers = type(group.knownMembers) == "table"
                    and group.knownMembers or {},
            }
        end
    end
    table.sort(groups, function(left, right)
        return strlower(left.name) < strlower(right.name)
    end)

    while #menuRows < #groups do
        createMenuRow(#menuRows + 1)
    end
    for index, row in ipairs(menuRows) do
        local group = groups[index]
        if group then
            local savedGroup = group
            local groupRow = row
            row.groupId = group.id
            row.groupName = group.name
            row.savedGroup = savedGroup
            row.connect = function(groupToConnect)
                local active = activeGroups[groupToConnect.id]
                if active then
                    active.window.frame:Show()
                    active.window.input:SetFocus()
                elseif #getJoinCandidates(groupToConnect) > 0 then
                    joinGroup(groupToConnect.name, groupToConnect.password,
                        groupToConnect.memberName, groupToConnect)
                elseif groupToConnect.isCreator then
                    createGroup(groupToConnect.name, groupToConnect.password,
                        groupToConnect)
                else
                    createGroup(groupToConnect.name, groupToConnect.password,
                        groupToConnect)
                end
            end
            row.text:SetText(group.name)
            row.action = function()
                groupRow.connect(savedGroup)
            end
            local isConnected = activeGroups[group.id] ~= nil
            row.connectButton:SetText(isConnected and "Disconnect" or "Connect")
            row.connectButton:SetShown(true)
            row.exitButton:SetShown(not savedGroup.isCreator)
            row.deleteButton:SetShown(savedGroup.isCreator)
            row.text:ClearAllPoints()
            row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
            row.text:SetPoint("RIGHT", row, "RIGHT",
                savedGroup.isCreator and -138 or -134, 0)
            row:Show()
        else
            row:Hide()
        end
    end

    local footerY = -30 - #groups * 24
    menu.createButton:ClearAllPoints()
    menu.createButton:SetPoint("TOPLEFT", menu, "TOPLEFT", 10, footerY)
    menu.joinButton:ClearAllPoints()
    menu.joinButton:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -10, footerY)
    menu:SetHeight(30 + #groups * 24 + 42)
    menu:ClearAllPoints()
    menu:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 4, -4)
    menu:Show()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("CHAT_MSG_ADDON")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
eventFrame:SetScript("OnEvent", function(_, event, prefix, message, distribution, sender)
    if event == "PLAYER_LOGOUT" then
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

    if kind == "HELLO" then
        if session and body == session.password then
            addMember(session, sender)
            sendGroupProtocol(session, "WELCOME", sender,
                session.creatorName or (session.isCreator and selfName) or "")
            sendGroupProtocol(session, "CLASS", sender, playerClass)
            for key, member in pairs(session.members) do
                if not namesMatch(member.name, selfName or UnitName("player"))
                    and not namesMatch(member.name, sender) then
                    sendGroupProtocol(session, "MEMBER", sender, member.name)
                    if member.classFile then
                        sendGroupProtocol(session, "CLASS", sender, member.classFile)
                    end
                end
            end
            for _, memberName in pairs(session.knownMembers or {}) do
                sendGroupProtocol(session, "KNOWN", sender, memberName)
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
                if session.window then
                    session.window:UpdateMembers()
                end
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

    if kind == "DELETE" then
        local savedGroup = getSavedGroups()[id]
        local creatorName = session and session.creatorName
            or (savedGroup and savedGroup.creatorName)
        if creatorName and namesMatch(sender, creatorName) then
            if session then
                session.members = {}
                if session.window then
                    session.window.frame:Hide()
                    session.window.input:ClearFocus()
                end
            end
            activeGroups[id] = nil
            pendingJoins[id] = nil
            getSavedGroups()[id] = nil
            showNotice("The creator deleted " .. (session and session.name
                or (savedGroup and savedGroup.name) or id) .. ".")
        end
        return
    end

    if (kind == "MSG2" or kind == "EMOTE2")
        and session and hasMember(session, sender) then
        local decodedBody = TrialChatCommon.DecodeMessageMarkup(body)
        local messageId, timestamp, emoteFlag, text =
            string.match(decodedBody, "^([%x%-]+):(%d+):([ME]):(.*)$")
        timestamp = tonumber(timestamp)
        if messageId and timestamp then
            addGroupMessage(session, sender, text,
                emoteFlag == "E", messageId, timestamp, false, true)
        end
        return
    end

    if (kind == "MSG" or kind == "EMOTE")
        and session and hasMember(session, sender) then
        local decodedBody = TrialChatCommon.DecodeMessageMarkup(body)
        addGroupMessage(session, sender, decodedBody, kind == "EMOTE",
            nil, nil, false, true)
        return
    end

    if kind == "HIST" then
        if session and hasMember(session, sender) then
            receiveHistoryChunk(session, sender, body)
        elseif pending and isJoinCandidate(pending, sender) then
            receiveHistoryChunk(pending, sender, body)
        end
    end
end)

C_Timer.NewTicker(MEMBER_UPDATE_INTERVAL, function()
    local now = GetTime()
    for _, session in pairs(activeGroups) do
        addMember(session, selfName or UnitName("player"))
        sendToMembers(session, "MEMBER", selfName or UnitName("player"))
        if playerClass then
            sendToMembers(session, "CLASS", playerClass)
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
                removeMember(session, member.name)
            end
        end
        if session.window then
            session.window:UpdateMembers()
        end
    end
end)
