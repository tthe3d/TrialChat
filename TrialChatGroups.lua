local PREFIX = "TrialChat"
local GROUP_TAG = "TCG1|"
local MAX_GROUP_NAME_BYTES = 24
local MAX_PASSWORD_BYTES = 32
local MAX_GROUP_MESSAGE_BYTES = 200
local MEMBER_TIMEOUT = 90
local MEMBER_UPDATE_INTERVAL = 30
local GROUP_WINDOW_FADE_SECONDS = 0.4
local _, playerClass = UnitClass("player")

local Groups = {}
TrialChatGroups = Groups

local activeGroups = {}
local pendingJoins = {}
local windowAlphaAnimations = {}
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
end

local function removeMember(session, name)
    if not name or name == "" then return end

    local key = findMemberKey(session, name)
    if key then session.members[key] = nil end
    if session.window then
        session.window:UpdateMembers()
    end
end

local function sendGroupProtocol(session, kind, target, body)
    if not target then return false end
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

local function setWindowAlphaSmooth(frame, targetAlpha)
    local animation = windowAlphaAnimations[frame]
    if not animation then
        local animationGroup = frame:CreateAnimationGroup()
        local alphaAnimation = animationGroup:CreateAnimation("Alpha")
        alphaAnimation:SetDuration(GROUP_WINDOW_FADE_SECONDS)
        alphaAnimation:SetSmoothing("OUT")
        animation = {
            group = animationGroup,
            animation = alphaAnimation,
        }
        windowAlphaAnimations[frame] = animation
    end

    if animation.targetAlpha == targetAlpha
        and (animation.group:IsPlaying() or frame:GetAlpha() == targetAlpha) then
        return
    end

    local currentAlpha = frame:GetAlpha()
    if animation.group:IsPlaying() then
        animation.group:Stop()
        frame:SetAlpha(currentAlpha)
    end

    animation.targetAlpha = targetAlpha
    animation.animation:SetFromAlpha(currentAlpha)
    animation.animation:SetToAlpha(targetAlpha)
    animation.group:Play()
end

local function updateWindowAlpha(window)
    if not window or not window.frame then return end

    local mouseOver = window.frame:IsShown() and window.frame:IsMouseOver()
    local inputHasFocus = window.input and window.input:HasFocus()
    local recentMessage = window.lastMessageAt
        and GetTime() - window.lastMessageAt < 10
    setWindowAlphaSmooth(
        window.frame, (mouseOver or inputHasFocus or recentMessage) and 1 or 0.45)
end

local function addGroupMessage(session, sender, message)
    local window = session.window
    if not window then return end

    addMember(session, sender)
    local displayMessage = string.gsub(message, "|", "||")
    local shortSender = string.match(sender, "^([^-]+)") or sender
    local memberKey = findMemberKey(session, sender)
    local member = memberKey and session.members[memberKey]
    local nameColor = getClassColor(member and member.classFile) or "|cffffcc00"
    window.log:AddMessage(nameColor .. shortSender .. "|r: " .. displayMessage)
    window.log:ScrollToBottom()
    window.lastMessageAt = GetTime()
    updateWindowAlpha(window)
    C_Timer.After(10, function()
        updateWindowAlpha(window)
    end)
end

local saveGroup

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
    frame:SetResizeBounds(580, 360, 1200, 900)
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
    title:SetPoint("TOP", frame, "TOP", 0, -12)
    title:SetText(session.name)

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
    window.log:EnableMouseWheel(true)
    window.log:SetScript("OnMouseWheel", function(self, delta)
        if delta > 0 then
            self:ScrollUp()
        else
            self:ScrollDown()
        end
    end)
    window.log:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -42)
    window.log:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -176, 48)

    local memberPanel = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    window.memberPanel = memberPanel
    memberPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 414, -38)
    memberPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -10, 48)
    memberPanel:EnableMouse(true)
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
    window.memberTitle:SetText("Members")

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
    input:SetHeight(26)
    input:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 14)
    input:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -176, 14)
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
        if #message > MAX_GROUP_MESSAGE_BYTES then
            showNotice("Group messages are limited to " .. MAX_GROUP_MESSAGE_BYTES .. " bytes.")
            self:SetFocus()
            return
        end
        addGroupMessage(session, selfName or UnitName("player"), message)
        sendToMembers(session, "MSG", message)
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
        local visibleRows = math.max(1,
            math.floor(self.memberScroll:GetHeight() / 18))
        FauxScrollFrame_Update(self.memberScroll, #names, visibleRows, 18)
        local offset = FauxScrollFrame_GetOffset(self.memberScroll)

        while #self.rows < #names do
            local row = CreateFrame("Frame", nil, memberPanel)
            row:SetHeight(18)
            row:SetPoint("TOPLEFT", memberScroll, "TOPLEFT",
                2, -(#self.rows) * 18)
            row:SetPoint("RIGHT", memberScroll, "RIGHT", -4, 0)
            row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            row.text:SetAllPoints()
            row.text:SetJustifyH("LEFT")
            row.text:SetWordWrap(false)
            self.rows[#self.rows + 1] = row
        end

        for index, row in ipairs(self.rows) do
            local member = names[offset + index]
            if member and index <= visibleRows then
                local nameColor = getClassColor(member.classFile)
                local nameText = nameColor and (nameColor .. member.name .. "|r")
                    or member.name
                row.text:SetText(nameText)
                row:Show()
            else
                row:Hide()
            end
        end
    end

    frame:HookScript("OnShow", function()
        window:UpdateMembers()
    end)

    frame:Hide()
    window:UpdateMembers()
end

saveGroup = function(session)
    local savedGroups = getSavedGroups()
    savedGroups[session.id] = {
        name = session.name,
        password = session.password,
        memberName = session.targetName,
        isCreator = session.isCreator or not session.targetName,
        creatorName = session.creatorName,
        width = session.width,
        height = session.height,
    }
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
end

local function validateMemberName(name)
    name = strtrim(name or "")
    if name == "" or #name > 64 or string.find(name, "[%c|]") then
        showNotice("Enter the character name of an online group member.")
        return nil
    end
    return name
end

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

    targetName = validateMemberName(targetName)
    if not targetName then return end

    local session = {
        id = id,
        name = name,
        password = password,
        members = {},
        targetName = targetName,
        isCreator = false,
        creatorName = savedGroup and savedGroup.creatorName,
        width = savedGroup and savedGroup.width,
        height = savedGroup and savedGroup.height,
    }
    pendingJoins[id] = session
    if not sendGroupProtocol(session, "HELLO", targetName, password) then
        pendingJoins[id] = nil
        return
    end

    for retry = 1, 3 do
        C_Timer.After(retry * 2, function()
            if pendingJoins[id] == session then
                sendGroupProtocol(session, "HELLO", targetName, password)
            end
        end)
    end
    C_Timer.After(8, function()
        if pendingJoins[id] ~= session then return end
        pendingJoins[id] = nil
        showNotice("No reply from " .. targetName .. ". Check that they are online and the group details are correct.")
    end)
end

local function createGroup(name, password, savedGroup)
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
        isCreator = true,
        creatorName = selfName or UnitName("player"),
        width = savedGroup and savedGroup.width,
        height = savedGroup and savedGroup.height,
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
local function openGroupDialog(mode, preset)
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
    if not savedGroup or savedGroup.isCreator or not savedGroup.memberName then
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
        and not (savedGroup and (savedGroup.isCreator or not savedGroup.memberName)) then
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
                isCreator = group.isCreator or not group.memberName,
                creatorName = group.creatorName,
                width = group.width,
                height = group.height,
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
                elseif groupToConnect.isCreator then
                    createGroup(groupToConnect.name, groupToConnect.password,
                        groupToConnect)
                elseif groupToConnect.memberName then
                    joinGroup(groupToConnect.name, groupToConnect.password,
                        groupToConnect.memberName, groupToConnect)
                else
                    openGroupDialog("join", groupToConnect)
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
            sendToMembers(session, "MEMBER", sender)
            if playerClass then
                sendToMembers(session, "CLASS", playerClass, sender)
            end
        end
        return
    end

    if kind == "WELCOME" then
        if pending and namesMatch(sender, pending.targetName) then
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
        elseif pending and namesMatch(sender, pending.targetName) then
            if body ~= "" then
                addMember(pending, body)
            end
            completePendingJoin(pending, sender)
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

    if kind == "MSG" and session and hasMember(session, sender) then
        addGroupMessage(session, sender, body)
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
            session.members[key] = nil
        end
        if session.window then
            session.window:UpdateMembers()
        end
    end
end)
