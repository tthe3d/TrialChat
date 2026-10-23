-- The message list of the TrialChat window: each message under its
-- sender's avatar and name, several in a row from the same person grouped
-- under one, day and "new" dividers, and emotes in the middle. It's a
-- scroll box, so only the rows on screen exist however long the history is.
TrialChatMessageList = {}
local UI = TrialChatUI
local Color = UI.Color

local SIDE_PADDING = 20
local RIGHT_PADDING = 10
local AVATAR_SIZE = 32
local TEXT_LEFT = SIDE_PADDING + AVATAR_SIZE + 12
local HEADER_TOP = 12
local NAME_HEIGHT = 18
local CONTINUATION_TOP = 2
local TEXT_BOTTOM = 2
local CENTERED_PADDING = 7
local DIVIDER_HEIGHT = 34
local MIN_TEXT_HEIGHT = 14
-- A reply shown above a message: a short bar and the quoted line.
local REPLY_GAP = 3
local REPLY_INDENT = 8
-- Messages from the same person this close together share one header.
local GROUP_SECONDS = 5 * 60
local RELAYOUT_DELAY = 0.15
local SCROLL_STEP = 40
local DEFAULT_WIDTH = 520

local List = {}
List.__index = List

local function dayLabel(timestamp)
    local now = GetServerTime()
    local day = date("%Y-%m-%d", timestamp)
    if day == date("%Y-%m-%d", now) then return "Today" end
    if day == date("%Y-%m-%d", now - 86400) then return "Yesterday" end
    if now - timestamp < 6 * 86400 then return date("%A", timestamp) end
    return date("%B ", timestamp) .. tonumber(date("%d", timestamp))
        .. date(", %Y", timestamp)
end

local function onHyperlinkClick(_, link, text, button)
    TrialChatCommon.HandleHyperlinkClick(link, text, button)
end

-- The quoted part of a reply: who and what, on one muted line. It is drawn
-- as a link, so clicking it jumps back to the message it quotes.
local function formatReply(reply, colorFor)
    local sender = TrialChatCommon.ShortName(reply.sender or "?")
    local text = TrialChatCommon.RemovePlayerLinks(reply.text or "")
    return TrialChatCommon.ReplyLink(
        UI.ColorText(colorFor({ sender = reply.sender }), sender)
            .. UI.ColorText(Color.muted, ": " .. text))
end

local function onHyperlinkEnter(self, link, text)
    GameTooltip:SetOwner(self, "ANCHOR_CURSOR_RIGHT")
    if link == TrialChatCommon.REPLY_LINK_NAME then
        GameTooltip:SetText("Click to jump to the quoted message")
    elseif string.sub(link or "", 1, 6) == "tcurl:" then
        GameTooltip:SetText("Click to copy URL")
    elseif string.sub(link or "", 1, 7) == "player:"
        or string.sub(link or "", 1, 9) == "tcplayer:" then
        GameTooltip:SetText("Click for player options: " .. (text or "player"))
    else
        GameTooltip:SetHyperlink(link)
    end
    GameTooltip:Show()
end

-- Rows without a header show their time in the avatar column on hover.
local function onRowEnter(row)
    if row.showsTimeOnHover then
        row.hoverTime:Show()
    end
end

local function onRowLeave(row)
    row.hoverTime:Hide()
end

local function onAvatarEnter(avatar)
    if not avatar.fullName then return end
    GameTooltip:SetOwner(avatar, "ANCHOR_RIGHT")
    GameTooltip:SetText(avatar.fullName)
    if not TrialChatCommon.IsSelf(avatar.fullName) then
        GameTooltip:AddLine("Right-click for player options.", 1, 1, 1)
    end
    GameTooltip:Show()
end

local function onAvatarClick(avatar)
    if avatar.fullName and not TrialChatCommon.IsSelf(avatar.fullName) then
        TrialChatCommon.ShowPlayerOptions(avatar.fullName, avatar.fullName, "RightButton")
    end
end

-- Makes links in a frame's text clickable, with tooltips. Right-clicking a
-- link opens the player/URL options, not the frame's own menu, so the frame
-- is told a link was under the cursor when it handles its click.
function TrialChatMessageList.EnableLinks(frame)
    frame:EnableMouse(true)
    frame:SetHyperlinksEnabled(true)
    frame:SetScript("OnHyperlinkClick", function(self, link, text, button)
        if button == "RightButton" then self.hyperlinkMenu = true end
        if link == TrialChatCommon.REPLY_LINK_NAME then
            if button ~= "RightButton" and self.onReplyJump then
                self.onReplyJump(self)
            end
            return
        end
        onHyperlinkClick(self, link, text, button)
    end)
    frame:SetScript("OnHyperlinkEnter", function(self, link, text)
        self.hoveredLink = true
        onHyperlinkEnter(self, link, text)
    end)
    frame:SetScript("OnHyperlinkLeave", function(self)
        self.hoveredLink = false
        GameTooltip_Hide()
    end)
end

local function createRowParts(row)
    TrialChatMessageList.EnableLinks(row)
    row:SetScript("OnEnter", onRowEnter)
    row:SetScript("OnLeave", onRowLeave)

    row.avatar = UI.CreateAvatar(row, AVATAR_SIZE)
    row.avatar:SetPoint("TOPLEFT", row, "TOPLEFT", SIDE_PADDING, -HEADER_TOP)
    row.avatar:RegisterForClicks("RightButtonUp")
    row.avatar:SetScript("OnClick", onAvatarClick)
    row.avatar:SetScript("OnEnter", onAvatarEnter)
    row.avatar:SetScript("OnLeave", GameTooltip_Hide)

    row.name = UI.CreateText(row, UI.Font.name)
    row.name:SetPoint("TOPLEFT", row, "TOPLEFT", TEXT_LEFT, -HEADER_TOP - 1)
    row.time = UI.CreateText(row, UI.Font.time, Color.muted)
    row.time:SetPoint("BOTTOMLEFT", row.name, "BOTTOMRIGHT", 8, 0)
    row.hoverTime = UI.CreateText(row, UI.Font.time, Color.muted)
    row.hoverTime:SetPoint("TOPRIGHT", row, "TOPLEFT", TEXT_LEFT - 8, -CONTINUATION_TOP - 2)

    row.text = UI.CreateText(row, UI.Font.body)
    row.text:SetJustifyV("TOP")
    row.text:SetWordWrap(true)
    row.text:SetNonSpaceWrap(true)

    row.label = UI.CreateText(row, UI.Font.small)
    row.label:SetPoint("CENTER", row, "CENTER", 0, 0)
    row.lineLeft = UI.CreateLine(row)
    row.lineLeft:SetHeight(1)
    row.lineLeft:SetPoint("LEFT", row, "LEFT", SIDE_PADDING, 0)
    row.lineLeft:SetPoint("RIGHT", row.label, "LEFT", -10, 0)
    row.lineRight = UI.CreateLine(row)
    row.lineRight:SetHeight(1)
    row.lineRight:SetPoint("LEFT", row.label, "RIGHT", 10, 0)
    row.lineRight:SetPoint("RIGHT", row, "RIGHT", -RIGHT_PADDING, 0)

    row.replyBar = UI.CreateLine(row)
    row.replyBar:SetWidth(2)
    row.replyBar:Hide()
    row.reply = UI.CreateText(row, UI.Font.small, Color.muted)
    row.reply:SetJustifyH("LEFT")
    row.reply:SetJustifyV("TOP")
    row.reply:SetWordWrap(true)
    row.reply:SetNonSpaceWrap(true)
    row.reply:Hide()

    -- Right-click opens the message menu, unless a link was clicked. A plain
    -- frame has no RegisterForClicks (that is a Button method), so this
    -- listens for the button coming up with the mouse over the row.
    row:EnableMouse(true)
    row:SetScript("OnMouseUp", function(self, button)
        if button ~= "RightButton" then return end
        if self.hyperlinkMenu or self.hoveredLink then
            self.hyperlinkMenu = nil
            return
        end
        local handler = self.list and self.list.state
            and self.list.state.onMessageMenu
        if handler and self.entry then handler(self.entry, self) end
    end)
end

-- An animated emoticon is redrawn a cell at a time (see TrialChatEmoji.lua);
-- the text around it never changes. Only rows on screen tick, because a hidden
-- frame gets no OnUpdate, and only rows that hold an animated emoticon get one.
local function redrawEmoji(row)
    row.text:SetText(TrialChatCommon.BuildEmojiText(row.emojiParts, GetTime()))
end

local function tickEmoji(row, elapsed)
    row.emojiElapsed = (row.emojiElapsed or 0) + elapsed
    local step = 1 / (TrialChatCommon.EmojiFPS or 5)
    if row.emojiElapsed < step then return end
    row.emojiElapsed = 0
    redrawEmoji(row)
end

-- Sets a row's text and starts animating it when it holds an animated
-- emoticon. The split into text and emoticons is cached on the element, since
-- rows are recycled for whatever is scrolled into view.
local function setRowText(row, element)
    row.text:SetText(element.text)
    if not element.emojiChecked then
        element.emojiParts, element.emojiAnimated =
            TrialChatCommon.SplitEmojiMarkup(element.text)
        element.emojiChecked = true
    end
    if element.emojiAnimated then
        row.emojiParts = element.emojiParts
        row.emojiElapsed = 0
        row:SetScript("OnUpdate", tickEmoji)
    end
end

local function hideRowParts(row)
    row:SetScript("OnUpdate", nil)
    row.emojiParts = nil
    row.emojiElapsed = nil
    row.avatar:Hide()
    row.name:Hide()
    row.time:Hide()
    row.hoverTime:Hide()
    row.text:Hide()
    row.label:Hide()
    row.lineLeft:Hide()
    row.lineRight:Hide()
    row.replyBar:Hide()
    row.reply:Hide()
    row.showsTimeOnHover = false
    row.entry = nil
    row.onReplyJump = nil
end

-- The text gets the width its row's height was measured for and grows down
-- as it wraps. Taking the width from anchors on both sides doesn't work: a
-- new row's text is laid out before they resolve and stays on one line
-- until the next layout, and a RIGHT anchor would also limit its height.
local function placeText(row, element, left, top)
    local width = (element.measuredWidth or row:GetWidth()) - left - RIGHT_PADDING
    row.text:SetPoint("TOPLEFT", row, "TOPLEFT", left, top)
    row.text:SetWidth(math.max(1, width))
end

local function initializeRow(list, row, element)
    row.list = list
    if not row.text then
        createRowParts(row)
    end
    hideRowParts(row)
    local kind = element.kind

    if kind == "day" or kind == "new" then
        local color = kind == "new" and Color.accent or Color.muted
        row.label:SetText(element.text)
        UI.SetTextColor(row.label, color)
        UI.Tint(row.lineLeft, kind == "new" and Color.accent or Color.divider)
        UI.Tint(row.lineRight, kind == "new" and Color.accent or Color.divider)
        row.label:Show()
        row.lineLeft:Show()
        row.lineRight:Show()
        return
    end

    local text = row.text
    text:ClearAllPoints()
    setRowText(row, element)
    text:Show()
    if kind == "message" then
        text:SetJustifyH("LEFT")
        UI.SetTextColor(text, Color.text)
        row.entry = element.entry
        local top
        if element.header then
            row.avatar.fullName = element.sender
            row.avatar:SetPerson(element.sender, element.color)
            row.avatar:Show()
            row.name:SetText(element.name)
            UI.SetTextColor(row.name, element.color)
            row.name:Show()
            row.time:SetText(element.time)
            row.time:Show()
            top = -HEADER_TOP - NAME_HEIGHT
        else
            top = -CONTINUATION_TOP
            row.hoverTime:SetText(element.time)
            row.showsTimeOnHover = true
        end
        if element.replyText then
            local replyHeight = element.replyHeight or 0
            row.replyBar:ClearAllPoints()
            row.replyBar:SetPoint("TOPLEFT", row, "TOPLEFT", TEXT_LEFT, top)
            row.replyBar:SetHeight(math.max(1, replyHeight))
            UI.Tint(row.replyBar, element.replyColor or Color.muted, 0.85)
            row.replyBar:Show()
            row.reply:ClearAllPoints()
            row.reply:SetPoint("TOPLEFT", row, "TOPLEFT",
                TEXT_LEFT + REPLY_INDENT, top)
            row.reply:SetWidth(math.max(1,
                (element.measuredWidth or row:GetWidth())
                - TEXT_LEFT - RIGHT_PADDING - REPLY_INDENT))
            row.reply:SetText(element.replyText)
            row.reply:Show()
            row.onReplyJump = function() list:JumpToReply(element.entry) end
            top = top - replyHeight - REPLY_GAP
        end
        placeText(row, element, TEXT_LEFT, top)
        return
    end

    if kind == "line" then
        text:SetJustifyH("LEFT")
        UI.SetTextColor(text, Color.text)
        placeText(row, element, SIDE_PADDING, -TEXT_BOTTOM)
    else
        -- Centered like a message continuation: starting at TEXT_LEFT keeps the
        -- left gutter clear, so the hover timestamp (at TEXT_LEFT - 8) never
        -- sits under a long emote.
        text:SetJustifyH("CENTER")
        UI.SetTextColor(text, element.color or Color.emote)
        placeText(row, element, TEXT_LEFT, -CENTERED_PADDING)
        if element.time then
            row.hoverTime:SetText(element.time)
            row.showsTimeOnHover = true
        end
    end
end

function TrialChatMessageList.Create(parent)
    local list = setmetatable({
        rowsByEntry = setmetatable({}, { __mode = "k" }),
    }, List)
    local scrollBox = CreateFrame("Frame", nil, parent, "WowScrollBoxList")
    local scrollBar = CreateFrame("EventFrame", nil, parent, "MinimalScrollBar")
    scrollBar:SetPoint("TOPLEFT", scrollBox, "TOPRIGHT", 2, -4)
    scrollBar:SetPoint("BOTTOMLEFT", scrollBox, "BOTTOMRIGHT", 2, 4)
    list.scrollBox = scrollBox
    list.scrollBar = scrollBar

    -- The log takes the mouse even where no row does (an empty conversation,
    -- or the space below the last message), so a drag there no longer falls
    -- through to the window and drags the whole window around; the messages
    -- themselves sit above it and keep their own clicks and links.
    scrollBox:EnableMouse(true)

    list.measure = scrollBox:CreateFontString(nil, "ARTWORK")
    list.measure:SetFontObject(UI.Font.body)
    list.measure:SetPoint("TOPLEFT", scrollBox, "TOPLEFT")
    list.measure:SetWordWrap(true)
    list.measure:SetNonSpaceWrap(true)
    list.measure:Hide()

    local view = CreateScrollBoxListLinearView(4, 14, 0, 0, 0)
    view:SetElementFactory(function(factory)
        factory("Frame", function(row, element)
            initializeRow(list, row, element)
        end)
    end)
    view:SetElementExtentCalculator(function(_, element)
        return list:Measure(element)
    end)
    ScrollUtil.InitScrollBoxListWithScrollBar(scrollBox, scrollBar, view)
    ScrollUtil.AddManagedScrollBarVisibilityBehavior(scrollBox, scrollBar)
    scrollBox:SetPanExtent(SCROLL_STEP)

    list.newMessagesButton = UI.CreateButton(parent, {
        style = "accent", icon = "arrowDown", iconSize = 14, text = "New messages",
        height = 26, radius = 13, font = UI.Font.small,
        onClick = function() list:ScrollToBottom() end,
    })
    list.newMessagesButton:SetPoint("BOTTOM", scrollBox, "BOTTOM", 0, 10)
    list.newMessagesButton:SetFrameLevel(scrollBox:GetFrameLevel() + 100)
    list.newMessagesButton:Hide()

    list.emptyText = UI.CreateText(parent, UI.Font.body, Color.muted)
    list.emptyText:SetPoint("LEFT", scrollBox, "LEFT", SIDE_PADDING * 2, 0)
    list.emptyText:SetPoint("RIGHT", scrollBox, "RIGHT", -SIDE_PADDING * 2, 0)
    list.emptyText:SetJustifyH("CENTER")
    list.emptyText:Hide()

    scrollBox:RegisterCallback(BaseScrollBoxEvents.OnScroll, function()
        if list.newMessagesButton:IsShown() and list:IsAtBottom() then
            list.newMessagesButton:Hide()
        end
    end, list)
    scrollBox:RegisterCallback(BaseScrollBoxEvents.OnSizeChanged, function(_, width)
        list:OnWidthChanged(width)
    end, list)

    list:SetEntries({}, {})
    return list
end

function List:GetWidth()
    local width = self.width or self.scrollBox:GetWidth()
    if not width or width <= 0 then
        return DEFAULT_WIDTH
    end
    return width
end

function List:MeasureText(text, width)
    local measure = self.measure
    measure:SetWidth(math.max(1, width))
    measure:SetText(text)
    return math.max(MIN_TEXT_HEIGHT, measure:GetStringHeight() or 0)
end

-- Row heights depend on how the text wraps, so they're measured for the
-- current width and kept until the width changes.
function List:Measure(element)
    local width = self:GetWidth()
    if element.height and element.measuredWidth == width then
        return element.height
    end

    local height
    local kind = element.kind
    if kind == "day" or kind == "new" then
        height = DIVIDER_HEIGHT
    elseif kind == "message" then
        local textWidth = width - TEXT_LEFT - RIGHT_PADDING
        local textHeight = self:MeasureText(element.text, textWidth)
        local replyBlock = 0
        if element.replyText then
            element.replyHeight =
                self:MeasureText(element.replyText, textWidth - REPLY_INDENT)
            replyBlock = element.replyHeight + REPLY_GAP
        end
        if element.header then
            height = math.max(
                HEADER_TOP + NAME_HEIGHT + replyBlock + textHeight,
                HEADER_TOP + AVATAR_SIZE) + TEXT_BOTTOM
        else
            height = CONTINUATION_TOP + replyBlock + textHeight + TEXT_BOTTOM
        end
    elseif kind == "line" then
        height = self:MeasureText(element.text,
            width - SIDE_PADDING - RIGHT_PADDING) + TEXT_BOTTOM * 2
    else
        -- Emotes are centered in the text column (see initializeRow), so they
        -- wrap at the same width that is measured here.
        height = self:MeasureText(element.text,
            width - TEXT_LEFT - RIGHT_PADDING) + CENTERED_PADDING * 2
    end
    element.height = math.ceil(height)
    element.measuredWidth = width
    return element.height
end

function List:GetDistanceFromBottom()
    local scrollBox = self.scrollBox
    return scrollBox:GetDerivedScrollRange() - scrollBox:GetDerivedScrollOffset()
end

function List:IsAtBottom()
    return self:GetDistanceFromBottom() <= 2
end

function List:ScrollToBottom()
    self.scrollBox:ScrollToEnd(ScrollBoxConstants.NoScrollInterpolation)
    self.newMessagesButton:Hide()
end

-- Scrolls to the message a reply quotes, if it is in the loaded history.
-- entry is the reply-carrying message; the quote is looked for among the
-- messages before it, newest first, so the nearest one wins.
function List:JumpToReply(entry)
    local reply = type(entry) == "table" and entry.reply
    local entries = self.entries
    if not reply or not entries or not self.dataProvider then return end
    local start = #entries + 1
    for index = #entries, 1, -1 do
        if entries[index] == entry then
            start = index
            break
        end
    end
    for index = start - 1, 1, -1 do
        local quoted = entries[index]
        if TrialChatCommon.ReplyQuotesEntry(reply, quoted) then
            local element = self.rowsByEntry[quoted]
            local dataIndex = element and self.dataProvider:FindIndex(element)
            if dataIndex then
                self.scrollBox:ScrollToElementDataIndex(dataIndex,
                    ScrollBoxConstants.AlignBegin, 0,
                    ScrollBoxConstants.NoScrollInterpolation)
            end
            return
        end
    end
end

function List:SetDistanceFromBottom(distance)
    local scrollBox = self.scrollBox
    local range = scrollBox:GetDerivedScrollRange()
    if range > 0 then
        scrollBox:SetScrollPercentage(math.max(0, range - distance) / range,
            ScrollBoxConstants.NoScrollInterpolation)
    end
end

-- Lays the rows out again (after a resize) without moving what's in view.
function List:Relayout()
    if not self.dataProvider then return end
    local atBottom = self:IsAtBottom()
    local fromBottom = self:GetDistanceFromBottom()
    self.scrollBox:Rebuild(ScrollBoxConstants.RetainScrollPosition)
    if atBottom then
        self:ScrollToBottom()
    else
        self:SetDistanceFromBottom(fromBottom)
    end
end

function List:OnWidthChanged(width)
    if not width or width <= 0 or width == self.width then return end
    if not self.width then
        self.width = width
        self:Relayout()
        return
    end

    self.pendingWidth = width
    if self.relayoutPending then return end
    self.relayoutPending = true
    C_Timer.After(RELAYOUT_DELAY, function()
        self.relayoutPending = false
        if self.pendingWidth and self.pendingWidth ~= self.width then
            self.width = self.pendingWidth
            self:Relayout()
        end
    end)
end

-- Turns history entries into rows. entries are tables of { sender, message,
-- isEmote, timestamp } or, from older versions, ready-made chat lines.
function List:AddEntry(elements, entry)
    local state = self.state
    local function addNewDivider()
        if state.newDivider then
            elements[#elements + 1] = state.newDivider
            state.newDivider = nil
            state.last = nil
        end
    end

    if type(entry) ~= "table" then
        if type(entry) == "string" then
            addNewDivider()
            elements[#elements + 1] = {
                kind = "line", text = TrialChatCommon.RemovePlayerLinks(entry),
            }
        end
        state.last = nil
        return
    end

    local timestamp = tonumber(entry.timestamp) or 0
    local day = date("%Y-%m-%d", timestamp)
    if day ~= state.day then
        state.day = day
        state.last = nil
        elements[#elements + 1] = { kind = "day", text = dayLabel(timestamp) }
    end
    addNewDivider()

    -- Rows are kept per entry, so drawing the list again (while history
    -- loads) doesn't format and measure every message again.
    local cached = self.rowsByEntry[entry]
    local sender = entry.sender or "?"
    local name = TrialChatCommon.ShortName(sender)
    if entry.isEmote then
        if not cached then
            cached = {
                kind = "emote",
                text = name .. " " .. state.format(entry),
                time = date("%H:%M", timestamp),
            }
            self.rowsByEntry[entry] = cached
        end
        elements[#elements + 1] = cached
        state.last = nil
        return
    end

    local last = state.last
    local header = not (last and TrialChatCommon.NamesMatch(last.sender, sender)
        and timestamp - (tonumber(last.timestamp) or 0) <= GROUP_SECONDS)
    local color = state.colorFor(entry)
    if not cached or cached.header ~= header or cached.color ~= color then
        cached = {
            kind = "message",
            header = header,
            sender = sender,
            name = name,
            color = color,
            time = date("%H:%M", timestamp),
            text = cached and cached.text or state.format(entry),
        }
        self.rowsByEntry[entry] = cached
    end
    cached.entry = entry
    if entry.reply then
        cached.replyText = formatReply(entry.reply, state.colorFor)
        cached.replyColor = state.colorFor({ sender = entry.reply.sender })
    end
    elements[#elements + 1] = cached
    state.last = entry
end

-- options: format(entry) gives the message text, colorFor(entry) the name
-- color, onMessageMenu(entry, row) opens the message menu on right-click,
-- firstUnread is the entry to put the "new" divider before, with
-- unreadCount, keepPosition stays where the reader is, and emptyText is
-- shown while there are no messages.
function List:SetEntries(entries, options)
    self.entries = entries
    self.state = {
        format = options.format or function(entry) return entry.message end,
        colorFor = options.colorFor or function() return Color.textSoft end,
        onMessageMenu = options.onMessageMenu,
    }
    self.emptyText:SetText(options.emptyText or "")

    local elements = {}
    local newDivider
    for index, entry in ipairs(entries) do
        if index == options.firstUnread then
            -- Goes in after that day's divider.
            newDivider = { kind = "new", text = (options.unreadCount or 0) .. " new" }
            self.state.newDivider = newDivider
        end
        self:AddEntry(elements, entry)
    end
    self.state.newDivider = nil

    local fromBottom = options.keepPosition and self:GetDistanceFromBottom()
    local atBottom = not options.keepPosition or self:IsAtBottom()
    self.dataProvider = CreateDataProvider(elements)
    self.scrollBox:SetDataProvider(self.dataProvider, ScrollBoxConstants.RetainScrollPosition)
    self:UpdateEmptyText()

    if not atBottom then
        self:SetDistanceFromBottom(fromBottom)
        return
    end
    self:ScrollToBottom()
    -- Start at the first unread message when they don't all fit.
    if newDivider then
        local index = self.dataProvider:FindIndex(newDivider)
        if index and self.scrollBox:GetExtentUntil(index)
            < self.scrollBox:GetDerivedScrollOffset() then
            self.scrollBox:ScrollToElementDataIndex(index, ScrollBoxConstants.AlignBegin,
                0, ScrollBoxConstants.NoScrollInterpolation)
        end
    end
end

function List:StartNoticeFade(notice)
    if not notice or not notice.expiresAt then return end
    local dataProvider = self.dataProvider
    if not dataProvider then return end
    local index = dataProvider:FindIndex(notice)
    if not index then return end
    local row = self.scrollBox:FindFrame(index)
    if row and row.noticeText then
        local duration = 1.5
        local f = CreateFrame("Frame")
        f:SetScript("OnUpdate", function()
            local now = GetTime()
            if now >= notice.expiresAt then
                if row.noticeText and row.noticeText.SetAlpha then row.noticeText:SetAlpha(0) end
                f:SetScript("OnUpdate", nil)
                C_Timer.After(0.1, function()
                    if not self.dataProvider then return end
                    local idx = self.dataProvider:FindIndex(notice)
                    if idx then
                        self.dataProvider:RemoveIndex(idx)
                        self:UpdateEmptyText()
                        if self:IsAtBottom() then self:ScrollToBottom() end
                    end
                end)
                return
            end
            if now >= notice.expiresAt - duration and row.noticeText and row.noticeText.SetAlpha then
                local t = (notice.expiresAt - now) / duration
                row.noticeText:SetAlpha(math.max(0, t))
            elseif row.noticeText and row.noticeText.SetAlpha then
                row.noticeText:SetAlpha(1)
            end
        end)
    else
        C_Timer.After(0.5, function()
            if not self.dataProvider then return end
            if GetTime() >= notice.expiresAt then
                local idx = self.dataProvider:FindIndex(notice)
                if idx then
                    self.dataProvider:RemoveIndex(idx)
                    self:UpdateEmptyText()
                    if self:IsAtBottom() then self:ScrollToBottom() end
                end
            else
                self:StartNoticeFade(notice)
            end
        end)
    end
end

function List:UpdateEmptyText()
    self.emptyText:SetShown(self.dataProvider:GetSize() == 0)
end

function List:InsertElements(elements, scrollToBottom)
    if #elements == 0 then return end
    local atBottom = self:IsAtBottom()
    self.dataProvider:Insert(unpack(elements))
    self:UpdateEmptyText()
    if scrollToBottom or atBottom then
        self:ScrollToBottom()
    else
        self.newMessagesButton:Show()
    end
end

-- Adds a new message at the end. While the reader is scrolled up the view
-- stays put and a button offers to jump down, unless scrollToBottom.
function List:AppendEntry(entry, scrollToBottom)
    local elements = {}
    self:AddEntry(elements, entry)
    self:InsertElements(elements, scrollToBottom)
end

-- A line from TrialChat itself; it isn't kept in the history.
function List:AddNotice(text, color)
    self.state.last = nil
    local notice = { kind = "notice", text = text, color = color or Color.muted }
    if text and (string.find(text, "skipped: message too long") or string.find(text, "Chat message limits exceeded") or string.find(text, "limits exceeded")) then
        notice.expiresAt = GetTime() + 5
        notice.addedAt = GetTime()
    end
    self:InsertElements({ notice }, true)
    if notice.expiresAt then
        C_Timer.After(0.1, function() self:StartNoticeFade(notice) end)
    end
end

-- Sets up the rows on screen again, so their avatars show what's known now.
function List:RefreshAvatars()
    self.scrollBox:ReinitializeFrames()
end
