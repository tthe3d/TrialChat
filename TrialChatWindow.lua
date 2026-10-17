-- The TrialChat window: your conversations (nearby chat and your groups) in
-- a sidebar, the open one's messages in the middle under a header and above
-- the message box, and who's in it on the right.
TrialChatMessenger = {}
local Messenger = TrialChatMessenger
local UI = TrialChatUI
local Color = UI.Color

local NEARBY = "nearby"
local DEFAULT_WIDTH = 860
local DEFAULT_HEIGHT = 540
-- Size limits of the window without the member list, which adds its width.
local MIN_WIDTH, MIN_HEIGHT = 460, 400
local MAX_WIDTH, MAX_HEIGHT = 1420, 1100
local SIDEBAR_WIDTH = 200
local MEMBERS_WIDTH = 180
local HEADER_HEIGHT = 60
local COMPOSER_HEIGHT = 64
local INVITE_MARGIN = 20
-- The strip above the message box that shows what a reply will answer.
local REPLY_BAR_HEIGHT = 32
local REPLY_BAR_GAP = 6
-- The right-click menu on a message, in this window's colors.
local WINDOW_MENU_THEME = {
    bg = Color.window, bgAlpha = 0.98,
    border = Color.outline, borderAlpha = 1,
    radius = 8,
    hover = Color.hover, hoverAlpha = 1,
    text = Color.textSoft,
    font = UI.Font.item,
    itemHeight = 24,
    padding = 5,
    minWidth = 130,
}
local CONVERSATION_ROW_HEIGHT = 40
local MEMBER_ROW_HEIGHT = 26
local MEMBER_LABEL_HEIGHT = 30
local IDLE_ALPHA = 0.45
local MESSAGE_VISIBLE_SECONDS = 7
local REFRESH_DELAY = 0.1
local RENDER_DELAY = 0.3
local SEPARATOR = " \194\183 " -- a middle dot between details

local Nearby = TrialChatNearby
local Groups = TrialChatGroups
local Whispers = TrialChatWhispers

local function isWhisper(key)
    return Whispers:IsWhisper(key)
end

local window
local sidebar
local main
local membersPanel
local conversationList
local memberList
local messageList
local inviteCard
local replyBar
local searchField
local addListenerField
local header = {}
local composer = {}

local selected = NEARBY
local nearbyUnread = 0
local lastMessageAt
local refreshPending = {}
local selectConversation
-- The message a new message will answer, or nil. Kept in one place so both
-- views show the same pending reply.
local pendingReply
-- Lays the message box area out again; set once the window exists.
local updateComposerArea
-- Opens the right-click menu on a message; set with the reply handling.
local showMessageMenu

local function getSettings()
    TrialChatDB = TrialChatDB or {}
    if type(TrialChatDB.messenger) ~= "table" then
        TrialChatDB.messenger = { membersShown = true }
    end
    return TrialChatDB.messenger
end

local function isNearby(key)
    return key == NEARBY
end

-- The minimal view (TrialChatMinimal.lua) is used instead of the window
-- while the mode is "minimal"; it's made the first time it's needed.
local minimal

local function inMinimalMode()
    return getSettings().mode == "minimal"
end

-- Whether the open conversation is on screen, in whichever view is in use.
local function isViewShown()
    if inMinimalMode() then
        return minimal ~= nil and minimal:IsShown()
    end
    return window ~= nil and window:IsShown()
end

-- Bursts of changes (a history load, members coming online) redraw once.
local function scheduleRefresh(name, refresh, delay)
    if refreshPending[name] then return end
    refreshPending[name] = true
    C_Timer.After(delay or REFRESH_DELAY, function()
        refreshPending[name] = nil
        if window then
            refresh()
        end
    end)
end

local function saveWindowSettings()
    if not window then return end

    local centerX, centerY = window:GetCenter()
    local parentWidth, parentHeight = UIParent:GetSize()
    if not centerX or not centerY or parentWidth <= 0 or parentHeight <= 0 then return end

    local settings = getSettings()
    settings.width = window:GetWidth()
    settings.height = window:GetHeight()
    settings.centerX = centerX / parentWidth
    settings.centerY = centerY / parentHeight
end

-- The window fades back while you're not using it, like the chat frames,
-- but not while an invite waits for an answer.
local function updateAlpha()
    if not window then return end

    local focused = (composer.input and composer.input:HasFocus())
        or (searchField and searchField:HasFocus())
        or (addListenerField and addListenerField:HasFocus())
    local recentMessage = lastMessageAt
        and GetTime() - lastMessageAt < MESSAGE_VISIBLE_SECONDS
    -- The emoji picker is part of using the window: it stays lit while the
    -- picker is up, even if moving it around steals the keyboard focus.
    local pickerOpen = TrialChatEmojiPicker and TrialChatEmojiPicker.IsShown
        and TrialChatEmojiPicker.IsShown()
    local visible = (window:IsShown() and window:IsMouseOver()) or focused or recentMessage
        or (inviteCard and inviteCard:IsShown()) or pickerOpen
    TrialChatCommon.FadeTo(window, visible and 1 or IDLE_ALPHA)
end

local function noteMessage()
    lastMessageAt = GetTime()
    updateAlpha()
    C_Timer.After(MESSAGE_VISIBLE_SECONDS, updateAlpha)
end

local function getConversationName(key)
    if isNearby(key) then return "Nearby" end
    local whisper = Whispers:GetInfo(key)
    if whisper then return whisper.displayName or whisper.name end
    local info = Groups:GetInfo(key)
    return info and info.name or key
end

local function getMessageLimit()
    if isNearby(selected) then return Nearby.MAX_MESSAGE_BYTES end
    if isWhisper(selected) then return Whispers.MAX_MESSAGE_BYTES end
    return Groups.MAX_MESSAGE_BYTES
end

local function colorForName(name)
    return UI.ClassColor(Nearby:GetClass(name)) or Color.textSoft
end

local function colorForEntry(entry)
    return colorForName(entry.sender)
end

-- Player links in messages are shown as plain text, like the chat log did.
local function formatNearbyMessage(entry)
    return TrialChatCommon.RemovePlayerLinks(TrialChatCommon.FormatMessageText(
        TrialChatCommon.ApplyEmojiMarkup(entry.message or "")))
end

local function formatGroupMessage(entry)
    return TrialChatCommon.RemovePlayerLinks(TrialChatCommon.FormatMessageText(
        TrialChatCommon.ApplyEmojiMarkup(TrialChatCommon.AddSongLinkOwner(
            entry.message or "", entry.sender))))
end

local function getInitials(name)
    local first, second = string.match(name, "^(%w)%w*[%s_]+(%w)")
    if first then
        return string.upper(first .. second)
    end
    return string.upper(string.sub(name, 1, 2))
end

local function getTileColors(key)
    local hash = 0
    for index = 1, #key do
        hash = (hash + string.byte(key, index) * index) % 997
    end
    return UI.TileColors[hash % #UI.TileColors + 1]
end

local function findFirstUnread(entries)
    local first, count = nil, 0
    for index, entry in ipairs(entries) do
        if type(entry) == "table" and not entry.read
            and not TrialChatCommon.IsSelf(entry.sender) then
            first = first or index
            count = count + 1
        end
    end
    return first, count
end

---------------------------------------------------------------------------
-- Messages
---------------------------------------------------------------------------
local function renderMessages(options)
    options = options or {}
    local entries, format, emptyText
    if isNearby(selected) then
        entries = Nearby:GetHistory()
        format = formatNearbyMessage
        emptyText = "No messages yet. Players near you who use TrialChat"
            .. " will see what you write here."
    elseif isWhisper(selected) then
        entries = Whispers:GetHistory(selected)
        format = formatGroupMessage
        emptyText = "No whispers here yet."
    else
        entries = Groups:GetHistory(selected)
        format = formatGroupMessage
        emptyText = "No messages in this group yet."
    end
    messageList:SetEntries(entries, {
        format = format,
        colorFor = colorForEntry,
        onMessageMenu = function(entry)
            showMessageMenu(entry, WINDOW_MENU_THEME)
        end,
        firstUnread = options.firstUnread,
        unreadCount = options.unreadCount,
        keepPosition = options.keepPosition,
        emptyText = emptyText,
    })
end

-- New messages, notices and redraws go to the view in use; the other one
-- is drawn again when it's switched to.
local function showNotice(text, color)
    if inMinimalMode() then
        minimal:AddNotice(text, color)
    else
        messageList:AddNotice(text, color)
    end
end

local function appendMessage(entry, isOwn)
    if inMinimalMode() then
        minimal:AddEntry(entry, isOwn)
    else
        messageList:AppendEntry(entry, isOwn)
    end
end

local function redrawMessages()
    if inMinimalMode() then
        minimal:Render()
    else
        renderMessages({ keepPosition = true })
    end
end

---------------------------------------------------------------------------
-- Header
---------------------------------------------------------------------------
local function plural(count, word)
    return count .. " " .. word .. (count == 1 and "" or "s")
end

-- While a group's history syncs, its button stays pressed with the arrows
-- turning, and the header counts the messages received.
local function updateSyncButton(info)
    local button = header.syncButton
    button.syncing = info ~= nil and info.loadingHistory
    button.received = info and info.loadedHistory or 0
    UI.SetButtonActive(button, button.syncing)
    if not button.syncing then
        header.syncSpin:Stop()
    elseif not header.syncSpin:IsPlaying() then
        header.syncSpin:Play()
    end
end

local function updateHeader()
    local nearbyChat = isNearby(selected)
    local whisperChat = isWhisper(selected)
    local membersShown = getSettings().membersShown
    local info = not nearbyChat and not whisperChat and Groups:GetInfo(selected)
    header.title:SetText(getConversationName(selected))
    local iconTexture = not nearbyChat and not whisperChat and Groups:GetIcon(selected)
    iconTexture = iconTexture and TrialChatCommon.GetIconTexture(iconTexture)
    if nearbyChat then
        header.tile:SetLook(Color.tile, Color.textSoft, nil, "pin")
    elseif whisperChat then
        local whisper = Whispers:GetInfo(selected)
        local classFile = whisper and TrialChatCommon.GetKnownClass(whisper.name)
        header.tile:SetLook(UI.ClassColor(classFile) or Color.tile, Color.textSoft,
            getInitials(getConversationName(selected)))
    elseif iconTexture then
        header.tile.box:SetColor(Color.tile)
        header.tile:SetTexture(iconTexture)
    else
        local colors = getTileColors(selected)
        header.tile:SetLook(colors[1], colors[2], getInitials(getConversationName(selected)))
    end
    if nearbyChat then
        local active = Nearby:GetActiveCount()
        local saved = Nearby:GetSavedCount()
        local subtitle = active == 0 and "Nobody nearby uses TrialChat"
            or (active .. " nearby with TrialChat")
        if saved > 0 then
            subtitle = subtitle .. SEPARATOR .. plural(saved, "saved listener")
        end
        header.subtitle:SetText(subtitle)
    elseif whisperChat then
        header.subtitle:SetText("Whisper" .. SEPARATOR .. "normal chat")
    elseif info then
        local subtitle = info.online .. " online" .. SEPARATOR .. plural(info.members, "member")
        if info.loadingHistory then
            subtitle = subtitle .. SEPARATOR .. "syncing history"
            if info.loadedHistory > 0 then
                subtitle = subtitle .. " (" .. info.loadedHistory .. ")"
            end
        end
        header.subtitle:SetText(subtitle)
        UI.SetIcon(header.muteButton.icon, info.muted and "bellOff" or "bell")
        header.muteButton.muted = info.muted
    end
    updateSyncButton(info or nil)
    header.syncButton:SetShown(not nearbyChat and not whisperChat)
    header.muteButton:SetShown(not nearbyChat and not whisperChat)
    UI.SetButtonActive(header.membersButton, membersShown)
end

---------------------------------------------------------------------------
-- Message box
---------------------------------------------------------------------------
local function updateCounter()
    local bytes = #(composer.input:GetText() or "")
    local limit = getMessageLimit()
    composer.counter:SetText(bytes .. " / " .. limit)
    UI.SetTextColor(composer.counter, bytes > limit and Color.error or Color.muted)
end

local function updateComposer()
    composer.input:SetMaxLetters(getMessageLimit())
    composer.input.placeholder:SetText("Message " .. getConversationName(selected))
    updateCounter()
end

local function sendToConversation(message, reply)
    if strtrim(message or "") == "" then return end
    if isNearby(selected) then
        Nearby:Send(message, reply)
    elseif isWhisper(selected) then
        Whispers:SendMessage(selected, message, reply)
    else
        Groups:SendMessage(selected, message, reply)
    end
end

-- Typing /reload in a TrialChat message box acts as the command: the reload
-- emote goes out in the conversation on screen (the same place a normal
-- message would), and only then is the UI reloaded.
local function reloadFromComposer()
    TrialChat_Reload(function()
        sendToConversation("/reload")
    end)
end

-- Remembers the message a new message will answer, and shows it in both
-- views.
local function setReply(entry)
    pendingReply = entry and { sender = entry.sender, text = entry.message }
        or nil
    if minimal then
        minimal:SetReply(pendingReply)
    end
    if updateComposerArea then updateComposerArea() end
end

local function clearReply()
    setReply(nil)
end

-- The reply is taken once, by the message that uses it.
local function takePendingReply()
    local reply = pendingReply
    if reply then
        clearReply()
    end
    return reply
end

-- Copy text puts the message in a selectable box, since addons can't write
-- to the clipboard directly.
local function copyEntryText(entry)
    TrialChatCommon.ShowCopyDialog(
        TrialChatCommon.RemovePlayerLinks(entry.message or ""))
end

-- Puts the cursor in the message box, so replying starts typing right away.
local function focusInput()
    if inMinimalMode() and minimal then
        minimal:FocusInput()
    elseif composer.input then
        composer.input:SetFocus()
    end
end

-- theme lets each view open the menu in its own colors.
showMessageMenu = function(entry, theme)
    UI.ShowPopupMenu(theme or WINDOW_MENU_THEME, {
        { text = "Reply", onClick = function()
            setReply(entry)
            focusInput()
        end },
        { text = "Copy text", onClick = function() copyEntryText(entry) end },
    })
end

local function sendComposerMessage()
    local input = composer.input
    local message = input:GetText()
    input:SetText("")
    -- Typing /reload in the message box acts as the command: the reload emote
    -- goes out in the conversation on screen, then the UI reloads.
    if TrialChat_IsReloadCommand(message) then
        reloadFromComposer()
        return
    end
    sendToConversation(message, takePendingReply())
    input:SetFocus()
end

-- The minimal view sends here too, so it answers the same message.
local function sendWithReply(message)
    if TrialChat_IsReloadCommand(message) then
        reloadFromComposer()
        return
    end
    sendToConversation(message, takePendingReply())
end

-- The smiley button opens the emoji grid; picking one drops its shortcut into
-- the message box. The emote lists open beside the grid and "make your own"
-- sits under it.
-- The picker's catcher sits beneath the window rather than over it, so the
-- window stays interactive while the picker is up: it can be dragged or resized
-- without the picker closing, and using any of its buttons or fields closes the
-- picker (see watchOutsideClick in TrialChatEmojiPicker).
local function showEmoteMenu()
    -- Clicking the smiley again while the grid is up closes it, the way a
    -- toggle should, and hands writing straight back to the message box.
    if TrialChatEmojiPicker.IsShown() then
        TrialChatEmojiPicker.Hide()
        if composer.input then composer.input:SetFocus() end
        updateAlpha()
        return
    end
    -- Put the cursor in the message box as the picker opens, so the window
    -- stays lit (it fades while nothing is focused) and typing can start right
    -- away. Clicking an emoji drops it in at the cursor.
    if composer.input then
        composer.input:SetFocus()
        updateAlpha()
    end
    TrialChatEmojiPicker.Show({
        input = composer.input,
        anchor = composer.emoteButton,
        window = window,
        onClose = function()
            updateAlpha()
        end,
        onPick = function(entry)
            local input = composer.input
            if not input then return end
            -- The picker holds the keyboard on the message box, so the emoji
            -- drops in at the caret. Only when the box isn't focused for some
            -- reason does it go on the end, as before.
            if input:HasFocus() then
                input:Insert(entry.shortcut)
            else
                input:SetCursorPosition(#(input:GetText() or ""))
                input:Insert(entry.shortcut)
                input:SetFocus()
            end
        end,
        onEmote = function(name, isSound)
            sendToConversation((isSound and "//" or "/") .. name)
        end,
        onWriteOwn = function()
            local input = composer.input
            if not input then return end
            input:SetText("/e ")
            input:SetFocus()
        end,
    })
end

---------------------------------------------------------------------------
-- Members
---------------------------------------------------------------------------
local function updateMembers()
    if not membersPanel:IsShown() then return end

    local elements = {}
    local function addLabel(text)
        elements[#elements + 1] = { kind = "label", text = text }
    end
    local function addMember(person, online, tag, canSave)
        local isSelf = person.isSelf or TrialChatCommon.IsSelf(person.fullName)
        elements[#elements + 1] = {
            kind = "member",
            fullName = person.fullName,
            name = isSelf and "You" or TrialChatCommon.ShortName(person.fullName),
            color = online and (UI.ClassColor(person.classFile)
                or colorForName(person.fullName)) or Color.muted,
            online = online,
            tag = tag,
            isSelf = isSelf,
            canSave = canSave and not isSelf,
        }
    end

    if isNearby(selected) then
        local nearby, away = Nearby:GetListeners()
        addLabel("Nearby - " .. (#nearby + 1))
        addMember({ fullName = TrialChatCommon.GetPlayerFullName(), isSelf = true,
            classFile = TrialChatCommon.GetPlayerClass() }, true)
        for _, listener in ipairs(nearby) do
            addMember(listener, true, listener.saved and "saved", true)
        end
        if #away > 0 then
            addLabel("Saved - " .. #away)
            for _, listener in ipairs(away) do
                addMember(listener, false, nil, true)
            end
        end
    elseif isWhisper(selected) then
        -- A whisper is only ever the two of you. The game tells us nothing
        -- about the other player's presence, so they are shown the way the
        -- sidebar already shows their conversation: as someone you can talk
        -- to, with their class color once it's known.
        local whisper = Whispers:GetInfo(selected)
        local people = {
            { fullName = TrialChatCommon.GetPlayerFullName(), isSelf = true,
                classFile = TrialChatCommon.GetPlayerClass() },
        }
        if whisper and not TrialChatCommon.IsSelf(whisper.name) then
            people[#people + 1] = {
                fullName = whisper.name,
                classFile = TrialChatCommon.GetKnownClass(whisper.name),
            }
        end
        addLabel("Whisper - " .. #people)
        for _, person in ipairs(people) do
            local nearbyTag = not person.isSelf and Nearby:IsActive(person.fullName)
            addMember(person, true, nearbyTag and "nearby")
        end
    else
        local online, offline = Groups:GetMemberList(selected)
        addLabel("Online - " .. #online)
        for _, member in ipairs(online) do
            local nearbyTag = not member.isSelf and Nearby:IsActive(member.fullName)
            addMember(member, true, nearbyTag and "nearby")
        end
        if #offline > 0 then
            addLabel("Offline - " .. #offline)
            for _, member in ipairs(offline) do
                addMember(member, false)
            end
        end
    end

    -- Players with the same name on different realms show their realm.
    local nameCounts = {}
    for _, element in ipairs(elements) do
        if element.kind == "member" then
            nameCounts[element.name] = (nameCounts[element.name] or 0) + 1
        end
    end
    for _, element in ipairs(elements) do
        if element.kind == "member" and nameCounts[element.name] > 1 and not element.isSelf then
            element.name = element.fullName
        end
    end
    memberList:SetDataProvider(CreateDataProvider(elements),
        ScrollBoxConstants.RetainScrollPosition)
end

local function onMemberClick(row, button)
    local element = row.element
    if not element or element.isSelf then return end
    if button == "RightButton" then
        if isNearby(selected) or isWhisper(selected) then
            -- Nearby and a whisper are one-on-one: the game's own player
            -- menu already carries the TrialChat entries for the player.
            TrialChatCommon.ShowPlayerOptions(element.fullName, element.fullName, button)
            return
        end
        -- Group member list: a menu carrying the same group entries as the
        -- game's player menu (invite, and remove for a group you created).
        local memberName = element.fullName
        MenuUtil.CreateContextMenu(row, function(_, root)
            root:CreateTitle(element.name)
            root:CreateButton("Whisper", function()
                Whispers:OpenConversation(memberName)
            end)
            root:CreateButton("Whisper in normal chat", function()
                if ChatFrame_OpenChat then
                    ChatFrame_OpenChat("/w " .. memberName)
                end
            end)
            Groups:AddPlayerMenu(root, memberName)
        end)
    elseif element.canSave then
        Nearby:ToggleSavedListener(element.fullName)
    end
end

local function onMemberEnter(row)
    local element = row.element
    row.hover:Show()
    if not element then return end
    GameTooltip:SetOwner(row, "ANCHOR_LEFT")
    GameTooltip:SetText(element.isSelf and "This is you." or element.fullName)
    if not element.isSelf then
        if element.canSave then
            GameTooltip:AddLine(Nearby:IsSavedListener(element.fullName)
                and "Left-click to stop keeping this listener."
                or "Left-click to keep this listener: they hear your nearby chat wherever they are.",
                1, 1, 1, true)
        end
        local hint = (isNearby(selected) or isWhisper(selected))
            and "Right-click for player options."
            or "Right-click to whisper, invite or remove this member."
        GameTooltip:AddLine(hint, 1, 1, 1, true)
    end
    GameTooltip:Show()
end

local function onMemberLeave(row)
    row.hover:Hide()
    GameTooltip_Hide()
end

local function initMemberLabel(frame, element)
    if not frame.text then
        frame.text = UI.CreateLabel(frame)
        frame.text:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 7)
    end
    frame.text:SetText(string.upper(element.text))
end

local function initMemberRow(row, element)
    if not row.name then
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row.hoverArea = row:CreateTexture(nil, "BACKGROUND")
        row.hoverArea:SetPoint("TOPLEFT", row, "TOPLEFT", 8, 0)
        row.hoverArea:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -8, 0)
        row.hover = UI.CreateBox(row, { radius = 6, region = row.hoverArea })
        row.hover:SetColor(Color.hover)
        row.hover:Hide()
        row.dot = UI.CreateDot(row, 8)
        row.dot:SetPoint("LEFT", row, "LEFT", 16, 0)
        row.tag = UI.CreateText(row, UI.Font.small, Color.muted)
        row.tag:SetPoint("RIGHT", row, "RIGHT", -16, 0)
        row.name = UI.CreateText(row, UI.Font.item)
        row.name:SetPoint("LEFT", row.dot, "RIGHT", 10, 0)
        row.name:SetPoint("RIGHT", row.tag, "LEFT", -6, 0)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row:SetScript("OnClick", onMemberClick)
        row:SetScript("OnEnter", onMemberEnter)
        row:SetScript("OnLeave", onMemberLeave)
    end
    -- Rows are reused for other members when the list changes.
    row.element = element
    row.hover:SetShown(row:IsMouseOver())
    UI.SetDot(row.dot, element.online)
    row.name:SetText(element.name)
    UI.SetTextColor(row.name, element.color)
    row.tag:SetText(element.tag or "")
end

local function addListener()
    local error = Nearby:AddSavedListener(addListenerField:GetText())
    if error then
        showNotice(error, Color.error)
        return
    end
    addListenerField:SetText("")
end

---------------------------------------------------------------------------
-- Conversations
---------------------------------------------------------------------------
local function updateConversations()
    local search = strlower(strtrim(searchField:GetText() or ""))
    local function matches(name)
        return search == "" or string.find(strlower(name), search, 1, true) ~= nil
    end

    local elements = {}
    if matches("Nearby") then
        elements[#elements + 1] = {
            key = NEARBY, name = "Nearby", state = "online", unread = nearbyUnread,
            meta = tostring(Nearby:GetActiveCount()),
        }
    end
    for _, conversation in ipairs(Groups:GetConversations()) do
        if matches(conversation.name) then
            local state = conversation.state
            elements[#elements + 1] = {
                key = conversation.id,
                name = conversation.name,
                state = state,
                unread = conversation.unread,
                muted = conversation.muted,
                icon = conversation.icon,
                meta = state == "online" and (conversation.online .. " online")
                    or state == "connecting" and "connecting..." or "offline",
            }
        end
    end
    for _, conversation in ipairs(Whispers:GetConversations()) do
        if matches(conversation.name) then
            elements[#elements + 1] = {
                key = conversation.id,
                name = conversation.name,
                state = "online",
                unread = conversation.unread,
                meta = "Whisper",
            }
        end
    end
    conversationList:SetDataProvider(CreateDataProvider(elements),
        ScrollBoxConstants.RetainScrollPosition)
    if minimal then
        minimal:UpdateConversations()
    end
end

-- The conversations the minimal view switches between: Nearby and the
-- groups you're connected to.
local function getMinimalConversations()
    local conversations = {
        { key = NEARBY, name = "Nearby", unread = nearbyUnread },
    }
    for _, conversation in ipairs(Groups:GetConversations()) do
        if conversation.state == "online" then
            conversations[#conversations + 1] = {
                key = conversation.id, name = conversation.name, unread = conversation.unread,
            }
        end
    end
    for _, conversation in ipairs(Whispers:GetConversations()) do
        conversations[#conversations + 1] = {
            key = conversation.id, name = conversation.name, unread = conversation.unread,
        }
    end
    return conversations
end

local function showConversationMenu(owner, element)
    if isNearby(element.key) then return end
    if isWhisper(element.key) then
        MenuUtil.CreateContextMenu(owner, function(_, root)
            root:CreateTitle(element.name)
            root:CreateButton("Clear history", function()
                Whispers:ClearHistory(element.key)
            end)
            root:CreateButton("Remove conversation", function()
                Whispers:RemoveConversation(element.key)
                selectConversation(NEARBY)
            end)
        end)
        return
    end

    local id = element.key
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(element.name)
        local info = Groups:GetInfo(id)
        if info then
            root:CreateButton("Invite a player...", function()
                Groups:ShowInviteDialog(id)
            end)
            root:CreateButton("Sync history", function()
                Groups:LoadHistory(id)
            end)
            root:CreateButton(info.muted and "Turn sound on" or "Mute sound", function()
                Groups:SetMuted(id, not info.muted)
            end)
            root:CreateDivider()
            root:CreateButton("Disconnect", function()
                Groups:Confirm("disconnect", id)
            end)
        elseif element.state == "offline" then
            root:CreateButton("Connect", function()
                Groups:Connect(id)
            end)
            root:CreateDivider()
        end
        if Groups:IsCreator(id) then
            root:CreateButton("Change icon...", function()
                TrialChatIconPicker.Show(Groups:GetIcon(id), function(icon)
                    Groups:SetIcon(id, icon)
                end)
            end)
            root:CreateButton("Delete group", function()
                Groups:Confirm("delete", id)
            end)
        else
            root:CreateButton("Exit group", function()
                Groups:Confirm("exit", id)
            end)
        end
    end)
end

local function onConversationClick(row, button)
    local element = row.element
    if not element then return end
    if button == "RightButton" then
        showConversationMenu(row, element)
    elseif element.state == "offline" then
        Groups:Connect(element.key)
    elseif element.state == "online" then
        selectConversation(element.key)
    end
end

local function updateConversationRowHover(row)
    local element = row.element
    row.hover:SetShown(row.hovered and element and element.key ~= selected)
end

local function onConversationEnter(row)
    row.hovered = true
    updateConversationRowHover(row)
    local element = row.element
    if element and element.state == "offline" then
        GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
        GameTooltip:SetText("Click to connect to " .. element.name .. ".")
        GameTooltip:AddLine("Right-click for more options.", 1, 1, 1)
        GameTooltip:Show()
    end
end

local function onConversationLeave(row)
    row.hovered = false
    updateConversationRowHover(row)
    GameTooltip_Hide()
end

local function initConversationRow(row, element)
    if not row.tile then
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row.hover = UI.CreateBox(row, { radius = 8 })
        row.hover:SetColor(Color.hover)
        row.selection = UI.CreateBox(row, { radius = 8, subLevel = 1 })
        row.selection:SetColor(Color.selected)
        row.tile = UI.CreateTile(row, 28)
        row.tile:SetPoint("LEFT", row, "LEFT", 8, 0)
        row.avatar = UI.CreateAvatar(row, 28)
        row.avatar:SetPoint("LEFT", row, "LEFT", 8, 0)
        row.avatar:EnableMouse(false)
        row.avatar:Hide()
        row.badge = UI.CreateBadge(row)
        row.badge:SetPoint("RIGHT", row, "RIGHT", -10, 0)
        row.meta = UI.CreateText(row, UI.Font.small, Color.muted)
        row.meta:SetPoint("RIGHT", row, "RIGHT", -10, 0)
        row.name = UI.CreateText(row, UI.Font.item)
        row.name:SetPoint("LEFT", row.tile, "RIGHT", 10, 0)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)
        row:SetScript("OnClick", onConversationClick)
        row:SetScript("OnEnter", onConversationEnter)
        row:SetScript("OnLeave", onConversationLeave)
    end

    -- Rows are reused for other conversations when the list changes.
    row.element = element
    row.hovered = row:IsMouseOver()
    local isSelected = element.key == selected
    local online = element.state == "online"
    row.selection:SetShown(isSelected)
    updateConversationRowHover(row)

    local whisper = isWhisper(element.key)
    row.tile:SetShown(not whisper)
    row.avatar:SetShown(whisper)
    local iconTexture = not whisper and element.icon
        and TrialChatCommon.GetIconTexture(element.icon)
    if whisper then
        local classFile = TrialChatCommon.GetKnownClass(element.name)
        row.avatar:SetPerson(element.name,
            UI.ClassColor(classFile) or Color.textSoft, classFile)
    elseif isNearby(element.key) then
        row.tile:SetLook(Color.tile, Color.textSoft, nil, "pin")
    elseif iconTexture then
        row.tile.box:SetColor(online and Color.tile or Color.tileOffline)
        row.tile:SetTexture(iconTexture)
    elseif online then
        local colors = getTileColors(element.key)
        row.tile:SetLook(colors[1], colors[2], getInitials(element.name))
    else
        row.tile:SetLook(Color.tileOffline, Color.muted, getInitials(element.name))
    end

    row.name:SetText(element.name)
    UI.SetTextColor(row.name, isSelected and Color.white
        or online and Color.textSoft or Color.muted)
    row.name:ClearAllPoints()
    row.name:SetPoint("LEFT", (whisper and row.avatar or row.tile), "RIGHT", 10, 0)
    if element.unread > 0 then
        row.badge:SetCount(element.unread)
        row.badge:Show()
        row.meta:Hide()
        row.name:SetPoint("RIGHT", row.badge, "LEFT", -6, 0)
    else
        row.badge:Hide()
        row.meta:SetText(element.meta)
        row.meta:Show()
        row.name:SetPoint("RIGHT", row.meta, "LEFT", -6, 0)
    end
end

local function showCreateMenu(owner)
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateButton("Create a group", function()
            Groups:ShowDialog("create")
        end)
        root:CreateButton("Join a group", function()
            Groups:ShowDialog("join")
        end)
    end)
end

---------------------------------------------------------------------------
-- Layout and selection
---------------------------------------------------------------------------
local function updateLayout()
    local membersShown = getSettings().membersShown
    membersPanel:SetShown(membersShown)
    main:ClearAllPoints()
    main:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 0, 0)
    main:SetPoint("BOTTOMLEFT", sidebar, "BOTTOMRIGHT", 0, 0)
    if membersShown then
        main:SetPoint("TOPRIGHT", membersPanel, "TOPLEFT", 0, 0)
        main:SetPoint("BOTTOMRIGHT", membersPanel, "BOTTOMLEFT", 0, 0)
    else
        main:SetPoint("TOPRIGHT", window, "TOPRIGHT", -1, -1)
        main:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -1, 1)
    end

    local nearbyChat = isNearby(selected)
    addListenerField:SetShown(nearbyChat)
    memberList:ClearAllPoints()
    memberList:SetPoint("TOPLEFT", membersPanel, "TOPLEFT", 0, -10)
    memberList:SetPoint("BOTTOMRIGHT", membersPanel, "BOTTOMRIGHT", 0, nearbyChat and 52 or 18)
    UI.SetButtonActive(header.membersButton, membersShown)
    updateMembers()
end

local function getWidthBounds()
    local extra = getSettings().membersShown and MEMBERS_WIDTH or 0
    return MIN_WIDTH + extra, MAX_WIDTH + extra
end

-- The member list adds to the window instead of taking its width from the
-- chat: the window grows or shrinks on the right, so the chat keeps its
-- size and place.
local function setMembersShown(shown)
    getSettings().membersShown = shown
    local left, top = window:GetLeft(), window:GetTop()
    local minWidth, maxWidth = getWidthBounds()
    local width = window:GetWidth() + (shown and MEMBERS_WIDTH or -MEMBERS_WIDTH)
    window:SetResizeBounds(minWidth, MIN_HEIGHT, maxWidth, MAX_HEIGHT)
    if left and top then
        window:ClearAllPoints()
        window:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    end
    window:SetWidth(math.max(minWidth, math.min(maxWidth, width)))
    updateLayout()
    saveWindowSettings()
end

selectConversation = function(key)
    if not isNearby(key) and not isWhisper(key) and not Groups:GetInfo(key) then
        key = NEARBY
    end
    -- A reply answers a message in the conversation it came from.
    if pendingReply and key ~= selected then
        clearReply()
    end
    selected = key

    local firstUnread, unreadCount
    if isNearby(key) then
        Groups:SetViewedGroup(nil)
        Whispers:SetViewed(nil)
        if nearbyUnread > 0 then
            firstUnread = math.max(1, #Nearby:GetHistory() - nearbyUnread + 1)
            unreadCount = nearbyUnread
        end
        nearbyUnread = 0
    elseif isWhisper(key) then
        Groups:SetViewedGroup(nil)
        firstUnread, unreadCount = findFirstUnread(Whispers:GetHistory(key))
        Whispers:SetViewed(isViewShown() and key or nil)
    else
        Whispers:SetViewed(nil)
        firstUnread, unreadCount = findFirstUnread(Groups:GetHistory(key))
        Groups:SetViewedGroup(isViewShown() and key or nil)
        -- Tell the creator once about members who left while others were offline.
        if Groups:IsCreator(key) then
            local leftNames = Groups:ConsumeLeftNotices(key)
            if #leftNames > 0 then
                local list = table.concat(leftNames, ", ")
                showNotice(list .. " left " .. (Groups:GetInfo(key) and Groups:GetInfo(key).name or "the group")
                    .. " while nobody else was online.")
            end
        end
    end

    if inMinimalMode() then
        if minimal then
            minimal:Refresh()
        end
        return
    end
    renderMessages({ firstUnread = firstUnread, unreadCount = unreadCount })
    updateHeader()
    updateComposer()
    updateLayout()
    updateConversations()
end

-- Messages that came in while the view was closed are new.
local function onViewShown()
    if isNearby(selected) then
        if nearbyUnread > 0 then
            selectConversation(NEARBY)
        end
    elseif isWhisper(selected) then
        if findFirstUnread(Whispers:GetHistory(selected)) then
            selectConversation(selected)
        else
            Whispers:SetViewed(selected)
        end
    elseif findFirstUnread(Groups:GetHistory(selected)) then
        selectConversation(selected)
    else
        Groups:SetViewedGroup(selected)
    end
    updateConversations()
    updateAlpha()
end

local function getEntries()
    if isNearby(selected) then
        return Nearby:GetHistory(), formatNearbyMessage, colorForEntry
    elseif isWhisper(selected) then
        return Whispers:GetHistory(selected), formatGroupMessage, colorForEntry
    end
    return Groups:GetHistory(selected), formatGroupMessage, colorForEntry
end

local function cycleConversation(step)
    local conversations = getMinimalConversations()
    local current = 1
    for index, conversation in ipairs(conversations) do
        if conversation.key == selected then
            current = index
        end
    end
    selectConversation(conversations[(current - 1 + step) % #conversations + 1].key)
end

local setMode

local function ensureMinimal()
    if minimal then return minimal end
    minimal = TrialChatMinimalView.Create({
        GetSelected = function() return selected end,
        Select = function(key) selectConversation(key) end,
        Cycle = cycleConversation,
        GetConversations = getMinimalConversations,
        GetEntries = getEntries,
        GetName = function() return getConversationName(selected) end,
        GetMessageLimit = getMessageLimit,
        Send = sendWithReply,
        ClearReply = clearReply,
        ShowMessageMenu = showMessageMenu,
        ShowFullView = function() setMode("full", true) end,
        GetSettings = getSettings,
        AnswerInvite = function(join) Groups:AnswerInvite(join) end,
        OnShown = function()
            if inMinimalMode() then onViewShown() end
        end,
        OnHidden = function()
            if inMinimalMode() then
                Groups:SetViewedGroup(nil)
                Whispers:SetViewed(nil)
            end
        end,
    })
    minimal:Refresh()
    minimal:SetInvite(Groups:GetInvite())
    minimal:SetReply(pendingReply)
    return minimal
end

-- "minimal" shows the minimal view instead of the window; anything else is
-- the full window. Either way it opens on the same conversation.
setMode = function(mode, focusInput)
    getSettings().mode = mode == "minimal" and "minimal" or nil
    if mode == "minimal" then
        ensureMinimal()
        window:Hide()
        minimal:Show()
        selectConversation(selected)
        if focusInput then
            minimal:FocusInput()
        end
    else
        if minimal then
            minimal:Hide()
        end
        window:Show()
        selectConversation(selected)
        if focusInput then
            composer.input:SetFocus()
        end
    end
end

-- Other conversations' messages show as a notice in the minimal view.
local function showToast(key, entry)
    if not inMinimalMode() or not minimal or TrialChatCommon.IsSelf(entry.sender) then
        return
    end
    if isNearby(key) then
        minimal:ShowToast(key, "Nearby", nearbyUnread, entry, formatNearbyMessage, colorForEntry)
        return
    end
    if isWhisper(key) then
        local whisper = Whispers:GetInfo(key)
        if not whisper or entry.read then return end
        local _, unread = findFirstUnread(Whispers:GetHistory(key))
        minimal:ShowToast(key, whisper.displayName or whisper.name, unread, entry,
            formatGroupMessage, colorForEntry)
        return
    end
    local info = Groups:GetInfo(key)
    if not info or info.muted or entry.read then return end
    local _, unread = findFirstUnread(Groups:GetHistory(key))
    minimal:ShowToast(key, info.name, unread, entry, formatGroupMessage, colorForEntry)
end

---------------------------------------------------------------------------
-- Building the window
---------------------------------------------------------------------------
local function createSidebar()
    sidebar = CreateFrame("Frame", nil, window)
    sidebar:SetPoint("TOPLEFT", window, "TOPLEFT", 1, -1)
    sidebar:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", 1, 1)
    sidebar:SetWidth(SIDEBAR_WIDTH)
    sidebar.box = UI.CreateBox(sidebar, {
        radius = 9, corners = { TOPLEFT = true, BOTTOMLEFT = true },
    })
    sidebar.box:SetColor(Color.sidebar)
    local edge = UI.CreateLine(sidebar)
    edge:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", 0, 0)
    edge:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", 0, 0)
    edge:SetWidth(1)

    local title = UI.CreateText(sidebar, UI.Font.title, Color.accent)
    title:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 16, -19)
    title:SetText("TrialChat")

    local settingsButton = UI.CreateButton(sidebar, {
        style = "ghost", icon = "gear", iconSize = 17, width = 30, height = 30,
        tooltip = "Settings",
        onClick = function() TrialChatOptions:Toggle() end,
    })
    settingsButton:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", -10, -12)

    searchField = UI.CreateField(sidebar, {
        height = 30, icon = "search", insetLeft = 32, maxLetters = 32,
        placeholder = "Find a conversation",
    })
    searchField:SetFontObject(UI.Font.item)
    searchField.placeholder:SetFontObject(UI.Font.item)
    searchField:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 12, -52)
    searchField:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", -12, -52)
    searchField:HookScript("OnTextChanged", function()
        updateConversations()
    end)
    searchField:HookScript("OnEditFocusGained", updateAlpha)
    searchField:HookScript("OnEditFocusLost", updateAlpha)
    searchField:SetScript("OnEnterPressed", searchField.ClearFocus)

    local label = UI.CreateLabel(sidebar, "Conversations")
    label:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 18, -98)

    conversationList = CreateFrame("Frame", nil, sidebar, "WowScrollBoxList")
    conversationList:SetPoint("TOPLEFT", sidebar, "TOPLEFT", 8, -112)
    conversationList:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", -8, 60)
    local view = CreateScrollBoxListLinearView(0, 0, 0, 0, 2)
    view:SetElementInitializer("Button", initConversationRow)
    view:SetElementExtent(CONVERSATION_ROW_HEIGHT)
    conversationList:Init(view)

    local createButton = UI.CreateButton(sidebar, {
        style = "dashed", icon = "plus", iconSize = 15, text = "Create or join a group",
        height = 38, centered = true,
        onClick = function(self) showCreateMenu(self) end,
    })
    createButton:SetPoint("BOTTOMLEFT", sidebar, "BOTTOMLEFT", 12, 12)
    createButton:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", -12, 12)
end

local function createHeader()
    header.tile = UI.CreateTile(main, 28)
    header.tile:SetPoint("TOPLEFT", main, "TOPLEFT", 20, -16)
    header.tile:EnableMouse(true)
    header.tile:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" or isNearby(selected) then return end
        if not Groups:IsCreator(selected) then return end
        TrialChatIconPicker.Show(Groups:GetIcon(selected), function(icon)
            Groups:SetIcon(selected, icon)
        end)
    end)
    header.tile:SetScript("OnEnter", function(tile)
        if isNearby(selected) or not Groups:IsCreator(selected) then return end
        GameTooltip:SetOwner(tile, "ANCHOR_RIGHT")
        GameTooltip:SetText("Change group icon")
        GameTooltip:Show()
    end)
    header.tile:SetScript("OnLeave", GameTooltip_Hide)
    header.title = UI.CreateText(main, UI.Font.heading, Color.white)
    header.title:SetPoint("TOPLEFT", header.tile, "TOPRIGHT", 10, -1)
    header.title:SetJustifyH("LEFT")
    header.title:SetWordWrap(false)
    header.subtitle = UI.CreateText(main, UI.Font.small, Color.muted)
    header.subtitle:SetPoint("TOPLEFT", header.title, "BOTTOMLEFT", 0, -5)
    header.subtitle:SetJustifyH("LEFT")
    header.subtitle:SetWordWrap(false)

    header.closeButton = UI.CreateButton(main, {
        style = "ghost", icon = "close", iconSize = 14, width = 28, height = 28,
        tooltip = "Close",
        onClick = function() window:Hide() end,
    })
    header.closeButton:SetPoint("TOPRIGHT", main, "TOPRIGHT", -12, -16)

    header.minimizeButton = UI.CreateButton(main, {
        style = "ghost", icon = "collapse", iconSize = 15, width = 28, height = 28,
        tooltip = "Minimal view",
        onClick = function() setMode("minimal") end,
    })
    header.minimizeButton:SetPoint("RIGHT", header.closeButton, "LEFT", -2, 0)

    header.membersButton = UI.CreateButton(main, {
        icon = "members", iconSize = 17, width = 32, height = 32,
        tooltip = function()
            local list = isNearby(selected) and "listeners" or "members"
            return (getSettings().membersShown and "Hide " or "Show ") .. list
        end,
        onClick = function(self)
            setMembersShown(not getSettings().membersShown)
            if GameTooltip:GetOwner() == self then
                self:GetScript("OnEnter")(self)
            end
        end,
    })
    header.membersButton:SetPoint("RIGHT", header.minimizeButton, "LEFT", -6, 0)

    header.muteButton = UI.CreateButton(main, {
        icon = "bell", iconSize = 17, width = 32, height = 32,
        tooltip = function(self)
            return self.muted and "Turn the message sound back on"
                or "Mute the message sound for this group"
        end,
        onClick = function(self)
            Groups:SetMuted(selected, not self.muted)
            updateHeader()
            if GameTooltip:GetOwner() == self then
                self:GetScript("OnEnter")(self)
            end
        end,
    })
    header.muteButton:SetPoint("RIGHT", header.membersButton, "LEFT", -6, 0)

    header.syncButton = UI.CreateButton(main, {
        icon = "sync", iconSize = 17, width = 32, height = 32,
        tooltip = function(self)
            if self.syncing then
                return "Syncing history... " .. plural(self.received, "message")
                    .. " received so far."
            end
            return "Sync history\nAsk an online member for the messages you're missing,"
                .. " up to the last " .. Groups.MAX_HISTORY .. "."
        end,
        onClick = function()
            Groups:LoadHistory(selected)
        end,
    })
    header.syncButton:SetPoint("RIGHT", header.muteButton, "LEFT", -6, 0)
    header.syncSpin = header.syncButton.icon:CreateAnimationGroup()
    header.syncSpin:SetLooping("REPEAT")
    local turn = header.syncSpin:CreateAnimation("Rotation")
    turn:SetDegrees(-360)
    turn:SetDuration(1.2)

    -- The title and subtitle take the width left of the buttons, anchored by
    -- their top corners so their height stays their own. The 32 px buttons,
    -- centered on the close button, have their tops level with the title.
    header.title:SetPoint("TOPRIGHT", header.syncButton, "TOPLEFT", -12, 0)
    header.subtitle:SetPoint("TOPRIGHT", header.title, "BOTTOMRIGHT", 0, -5)

    local line = UI.CreateLine(main)
    line:SetPoint("TOPLEFT", main, "TOPLEFT", 0, -HEADER_HEIGHT)
    line:SetPoint("TOPRIGHT", main, "TOPRIGHT", 0, -HEADER_HEIGHT)
    line:SetHeight(1)
end

local function createComposer()
    local sendButton = UI.CreateButton(main, {
        style = "accent", icon = "send", iconSize = 16, width = 36, height = 36,
        tooltip = "Send",
        onClick = sendComposerMessage,
    })
    sendButton:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", -20, 14)

    composer.counter = UI.CreateText(main, UI.Font.small, Color.muted)
    composer.counter:SetPoint("RIGHT", sendButton, "LEFT", -10, 0)

    -- The smiley sits at the right end of the message box rather than the left,
    -- so the emoji window it opens pops out to the right of the chat and leaves
    -- the incoming messages on the left readable while it is up.
    local emoteButton = UI.CreateButton(main, {
        icon = "smile", iconSize = 18, width = 36, height = 36, tooltip = "Emotes",
        onClick = function() showEmoteMenu() end,
    })
    emoteButton:SetPoint("RIGHT", composer.counter, "LEFT", -10, 0)
    composer.emoteButton = emoteButton

    local input = UI.CreateField(main, { height = 36 })
    composer.input = input
    input:SetPoint("BOTTOMLEFT", main, "BOTTOMLEFT", 20, 14)
    input:SetPoint("BOTTOMRIGHT", emoteButton, "BOTTOMLEFT", -8, 0)
    TrialChatCommon.RegisterLinkInput(input)
    input:SetScript("OnEnterPressed", sendComposerMessage)
    -- Escape with the emoji picker up closes just the picker and keeps the
    -- message box focused, so writing carries on; otherwise it leaves the box
    -- like a normal field.
    input:SetScript("OnEscapePressed", function(self)
        if TrialChatEmojiPicker.IsShown() then
            TrialChatEmojiPicker.Hide()
            self:SetFocus()
            return
        end
        self:ClearFocus()
    end)
    input:HookScript("OnTextChanged", updateCounter)
    input:HookScript("OnEditFocusGained", updateAlpha)
    input:HookScript("OnEditFocusLost", function()
        -- Remember where the caret was, so handing the keyboard back below
        -- puts it back instead of dropping it at the end of the message.
        local caret = input:GetCursorPosition()
        updateAlpha()
        -- Clicking the emoji picker's own empty space shouldn't stop writing:
        -- while the picker is up, hand the keyboard straight back to the
        -- message box -- unless another box (the window's search, say) has
        -- deliberately taken it.
        C_Timer.After(0, function()
            if TrialChatEmojiPicker.IsShown()
                and not TrialChatEmojiPicker.IsSearchFocused()
                and not input:HasFocus()
                and not (GetCurrentKeyBoardFocus
                    and GetCurrentKeyBoardFocus()) then
                input:SetFocus()
                if caret then input:SetCursorPosition(caret) end
            end
        end)
    end)

    -- The reply strip sits between the messages and the message box.
    replyBar = CreateFrame("Frame", nil, main)
    replyBar:SetHeight(REPLY_BAR_HEIGHT)
    replyBar.box = UI.CreateBox(replyBar, { radius = 10, border = true })
    replyBar.box:SetColor(Color.sidebar, 0.92)
    replyBar.box:SetBorderColor(Color.outline, 1)
    replyBar.accent = UI.CreateLine(replyBar)
    replyBar.accent:SetWidth(2)
    replyBar.accent:SetPoint("TOP", replyBar, "TOP", 0, -7)
    replyBar.accent:SetPoint("BOTTOM", replyBar, "BOTTOM", 0, 7)
    replyBar.accent:SetPoint("LEFT", replyBar, "LEFT", 12, 0)
    replyBar.text = UI.CreateText(replyBar, UI.Font.small, Color.muted)
    replyBar.text:SetPoint("LEFT", replyBar, "LEFT", 22, 0)
    replyBar.text:SetPoint("RIGHT", replyBar, "RIGHT", -40, 0)
    replyBar.text:SetJustifyH("LEFT")
    replyBar.text:SetWordWrap(false)
    replyBar.cancel = UI.CreateButton(replyBar, {
        style = "ghost", icon = "close", iconSize = 11,
        width = 24, height = 24,
        onClick = clearReply,
    })
    replyBar.cancel:SetPoint("RIGHT", replyBar, "RIGHT", -6, 0)
    replyBar:Hide()
end

local function createMembersPanel()
    membersPanel = CreateFrame("Frame", nil, window)
    membersPanel:SetPoint("TOPRIGHT", window, "TOPRIGHT", -1, -1)
    membersPanel:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -1, 1)
    membersPanel:SetWidth(MEMBERS_WIDTH)
    membersPanel.box = UI.CreateBox(membersPanel, {
        radius = 9, corners = { TOPRIGHT = true, BOTTOMRIGHT = true },
    })
    membersPanel.box:SetColor(Color.panel)
    local edge = UI.CreateLine(membersPanel)
    edge:SetPoint("TOPLEFT", membersPanel, "TOPLEFT", 0, 0)
    edge:SetPoint("BOTTOMLEFT", membersPanel, "BOTTOMLEFT", 0, 0)
    edge:SetWidth(1)

    memberList = CreateFrame("Frame", nil, membersPanel, "WowScrollBoxList")
    local view = CreateScrollBoxListLinearView(0, 8, 0, 0, 0)
    view:SetElementFactory(function(factory, element)
        if element.kind == "label" then
            factory("Frame", initMemberLabel)
        else
            factory("Button", initMemberRow)
        end
    end)
    view:SetElementExtentCalculator(function(_, element)
        return element.kind == "label" and MEMBER_LABEL_HEIGHT or MEMBER_ROW_HEIGHT
    end)
    memberList:Init(view)

    addListenerField = UI.CreateField(membersPanel, {
        height = 30, maxLetters = 64, placeholder = "Add a listener",
    })
    addListenerField:SetFontObject(UI.Font.item)
    addListenerField.placeholder:SetFontObject(UI.Font.item)
    addListenerField:SetPoint("BOTTOMLEFT", membersPanel, "BOTTOMLEFT", 12, 12)
    addListenerField:SetPoint("BOTTOMRIGHT", membersPanel, "BOTTOMRIGHT", -12, 12)
    addListenerField:SetScript("OnEnterPressed", addListener)
    addListenerField:HookScript("OnEditFocusGained", updateAlpha)
    addListenerField:HookScript("OnEditFocusLost", updateAlpha)
    addListenerField:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Type a character name (and -Realm if it's another realm)"
            .. " and press Enter. Saved listeners hear your nearby chat wherever they are.",
            nil, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    addListenerField:SetScript("OnLeave", GameTooltip_Hide)
end

-- An invite to a group shows above the message box in both views, and
-- the messages make room for it. A pending reply does the same, right
-- above the message box.
updateComposerArea = function()
    local invite = Groups:GetInvite()
    if minimal then
        minimal:SetInvite(invite)
    end
    if not window then return end

    local atBottom = messageList:IsAtBottom()
    local bottom = COMPOSER_HEIGHT
    if replyBar then
        local hasReply = pendingReply ~= nil
        replyBar:SetShown(hasReply)
        if hasReply then
            if not replyBar.anchored then
                replyBar:SetPoint("BOTTOMLEFT", main, "BOTTOMLEFT",
                    INVITE_MARGIN, COMPOSER_HEIGHT)
                replyBar:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT",
                    -INVITE_MARGIN, COMPOSER_HEIGHT)
                replyBar.anchored = true
            end
            local color = colorForName(pendingReply.sender)
            replyBar.text:SetText("Replying to "
                .. UI.ColorText(color,
                    TrialChatCommon.ShortName(pendingReply.sender or "?"))
                .. UI.ColorText(Color.muted, ": "
                    .. TrialChatCommon.RemovePlayerLinks(pendingReply.text or "")))
            UI.Tint(replyBar.accent, color, 0.9)
            bottom = bottom + REPLY_BAR_HEIGHT + REPLY_BAR_GAP
        end
    end
    if invite then
        inviteCard:SetPoint("BOTTOMLEFT", main, "BOTTOMLEFT", INVITE_MARGIN, bottom)
        bottom = bottom
            + inviteCard:SetInvite(invite, main:GetWidth() - 2 * INVITE_MARGIN)
            + REPLY_BAR_GAP
    end
    inviteCard:SetShown(invite ~= nil)
    updateAlpha()
    messageList.scrollBox:ClearAllPoints()
    messageList.scrollBox:SetPoint("TOPLEFT", main, "TOPLEFT", 0, -HEADER_HEIGHT - 1)
    messageList.scrollBox:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", -14, bottom)
    if atBottom then
        C_Timer.After(0, function() messageList:ScrollToBottom() end)
    end
end

local function createWindow()
    if window then return end

    local settings = getSettings()
    TrialChatDB.chatWindow = nil
    window = CreateFrame("Frame", "TrialChatWindow", UIParent)
    local minWidth, maxWidth = getWidthBounds()
    local width = math.max(minWidth, math.min(maxWidth,
        tonumber(settings.width) or DEFAULT_WIDTH))
    local height = math.max(MIN_HEIGHT, math.min(MAX_HEIGHT,
        tonumber(settings.height) or DEFAULT_HEIGHT))
    window:SetSize(width, height)
    window:SetFrameStrata("DIALOG")
    window:SetFrameLevel(100)
    window:SetMovable(true)
    window:SetResizable(true)
    window:SetResizeBounds(minWidth, MIN_HEIGHT, maxWidth, MAX_HEIGHT)
    window:SetClampedToScreen(true)
    local centerX, centerY = tonumber(settings.centerX), tonumber(settings.centerY)
    if centerX and centerY then
        local parentWidth, parentHeight = UIParent:GetSize()
        window:SetPoint("CENTER", UIParent, "BOTTOMLEFT",
            centerX * parentWidth, centerY * parentHeight)
    else
        window:SetPoint("CENTER")
    end
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    window:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        saveWindowSettings()
    end)
    window.box = UI.CreateBox(window, { radius = 10, border = true })
    window.box:SetColor(Color.window)
    window.box:SetBorderColor(Color.outline)
    window:SetAlpha(IDLE_ALPHA)

    createSidebar()
    createMembersPanel()
    main = CreateFrame("Frame", nil, window)
    createHeader()
    createComposer()

    messageList = TrialChatMessageList.Create(main)
    messageList.scrollBox:SetPoint("TOPLEFT", main, "TOPLEFT", 0, -HEADER_HEIGHT - 1)
    messageList.scrollBox:SetPoint("BOTTOMRIGHT", main, "BOTTOMRIGHT", -14, COMPOSER_HEIGHT)
    inviteCard = UI.CreateInviteCard(main, function(join) Groups:AnswerInvite(join) end)
    inviteCard:SetPoint("BOTTOMLEFT", main, "BOTTOMLEFT", INVITE_MARGIN, COMPOSER_HEIGHT)
    inviteCard:SetFrameLevel(messageList.scrollBox:GetFrameLevel() + 110)
    main:SetScript("OnSizeChanged", function()
        if inviteCard:IsShown() or (replyBar and replyBar:IsShown()) then
            updateComposerArea()
        end
    end)

    local resizeGrip = CreateFrame("Button", nil, window)
    resizeGrip:SetSize(14, 14)
    resizeGrip:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -3, 3)
    resizeGrip:SetFrameLevel(window:GetFrameLevel() + 20)
    resizeGrip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizeGrip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizeGrip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    resizeGrip:SetScript("OnMouseDown", function(_, button)
        if button == "LeftButton" then
            window:StartSizing("BOTTOMRIGHT")
        end
    end)
    resizeGrip:SetScript("OnMouseUp", function(_, button)
        if button == "LeftButton" then
            window:StopMovingOrSizing()
            saveWindowSettings()
        end
    end)

    -- Resizing the window while the emoji picker is up keeps the picker's
    -- proportions in step with it instead of leaving the panel at its old size.
    window:HookScript("OnSizeChanged", function()
        if TrialChatEmojiPicker.IsShown() then
            TrialChatEmojiPicker.RefreshScale()
        end
    end)

    window:HookScript("OnEnter", updateAlpha)
    window:HookScript("OnLeave", updateAlpha)
    TrialChatCommon.WatchHover(window, updateAlpha)
    window:SetScript("OnShow", onViewShown)
    window:SetScript("OnHide", function()
        -- The picker is anchored to a button in the window, so it can't outlive
        -- it: closing or minimizing the chat puts the picker away too.
        if TrialChatEmojiPicker.IsShown() then TrialChatEmojiPicker.Hide() end
        Groups:SetViewedGroup(nil)
        composer.input:ClearFocus()
        searchField:ClearFocus()
        addListenerField:ClearFocus()
    end)

    window:Hide()
    selectConversation(NEARBY)
    updateComposerArea()
    if inMinimalMode() then
        ensureMinimal()
    end
end

---------------------------------------------------------------------------
-- Changes from nearby chat and groups
---------------------------------------------------------------------------
local function onNearbyChange(kind, ...)
    if kind == "listeners" then
        if not window then return end
        scheduleRefresh("conversations", updateConversations)
        scheduleRefresh("header", updateHeader)
        scheduleRefresh("members", updateMembers)
        return
    end

    createWindow()
    if kind == "message" then
        local entry = ...
        local isOwn = TrialChatCommon.IsSelf(entry.sender)
        -- A closed window opens on nearby chat; an open one stays where it
        -- is and counts the message as unread.
        local switched = false
        if not isNearby(selected) and (isOwn or not isViewShown()) then
            selectConversation(NEARBY)
            switched = true
        end
        Messenger:Open(false)
        noteMessage()
        if not isNearby(selected) then
            nearbyUnread = nearbyUnread + 1
            scheduleRefresh("conversations", updateConversations)
            showToast(NEARBY, entry)
        elseif not switched then
            appendMessage(entry, isOwn)
        end
    elseif kind == "notice" then
        local text, isError = ...
        Messenger:Open(false)
        if not isNearby(selected) then
            selectConversation(NEARBY)
        end
        showNotice(text, isError and Color.error or Color.emote)
    end
end

local function onGroupsChange(kind, id, entry, appended)
    if kind == "invite" then
        -- TrialChat opens to show an invite.
        if Groups:GetInvite() then
            Messenger:Open(false)
        end
        updateComposerArea()
        return
    end
    if kind == "open" then
        Messenger:Open(false)
        selectConversation(id)
        if inMinimalMode() then
            minimal:FocusInput()
        else
            composer.input:SetFocus()
        end
        return
    end
    if not window then return end

    if kind == "message" and id == selected then
        if appended then
            appendMessage(entry, TrialChatCommon.IsSelf(entry.sender))
        else
            -- Older messages (from a history load) go in between.
            scheduleRefresh("render", function()
                if selected == id then
                    redrawMessages()
                end
            end, RENDER_DELAY)
        end
        if isViewShown() then
            noteMessage()
        end
    end
    if kind == "message" and appended and (id ~= selected or not isViewShown()) then
        showToast(id, entry)
    end
    if kind == "groups" and not isNearby(selected) and not Groups:GetInfo(selected) then
        selectConversation(NEARBY)
    end
    if id == selected then
        scheduleRefresh("header", updateHeader)
        if kind == "members" then
            scheduleRefresh("members", updateMembers)
        elseif kind == "look" and not inMinimalMode() then
            scheduleRefresh("avatars", function() messageList:RefreshAvatars() end)
        end
    end
    if kind == "memberremoved" then
        local name, reason = entry, appended
        -- If the creator is looking at this group right now, tell them
        -- immediately; selecting the group again won't re-trigger the
        -- on-view notice in selectConversation.
        if name and reason ~= "kicked" and id == selected and isViewShown()
            and Groups:IsCreator(id) then
            local left = Groups:GetLeftMembersInfo(id)
            local key = name and TrialChatCommon.NormalizeName(name)
            if left and key and left[key] then
                Groups:ClearLeftMember(id, name)
                local info = Groups:GetInfo(id)
                showNotice(("%s left %s while nobody else was online.")
                    :format(name, info and info.name or "the group"))
            end
        end
    end
    scheduleRefresh("conversations", updateConversations)
end

local function onWhispersChange(kind, id, entry, appended)
    if kind == "open" then
        -- TrialChat opens on the whisper the player right-clicked.
        Messenger:Open(false)
        selectConversation(id)
        if inMinimalMode() then
            minimal:FocusInput()
        else
            composer.input:SetFocus()
        end
        return
    end
    if not window then return end

    if kind == "message" and id == selected then
        if appended then
            appendMessage(entry, TrialChatCommon.IsSelf(entry.sender))
            if isViewShown() then
                noteMessage()
            end
        end
    end
    if kind == "message" and appended and (id ~= selected or not isViewShown()) then
        showToast(id, entry)
    end
    if id == selected then
        scheduleRefresh("header", updateHeader)
    end
    scheduleRefresh("conversations", updateConversations)
end

Nearby:SetChangeHandler(onNearbyChange)
Groups:SetChangeHandler(onGroupsChange)
Whispers:SetChangeHandler(onWhispersChange)

function Messenger:Open(focusInput)
    createWindow()
    if inMinimalMode() then
        ensureMinimal()
        -- Opening to type with a notice showing answers that conversation.
        local replyTo = focusInput and minimal:GetToastKey()
        minimal:Show()
        if replyTo then
            minimal:Reply()
        elseif focusInput then
            minimal:FocusInput()
        end
        return
    end
    window:Show()
    if focusInput then
        composer.input:SetFocus()
    end
    updateComposerArea()
    updateAlpha()
end

function Messenger:Toggle()
    if not isViewShown() then
        Messenger:Open(true)
    elseif inMinimalMode() then
        minimal:Hide()
    else
        window:Hide()
    end
end

function Messenger:IsShown()
    return isViewShown()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
eventFrame:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGOUT" then
        saveWindowSettings()
        return
    end
    createWindow()
end)
