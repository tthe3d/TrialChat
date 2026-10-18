-- The minimal view of TrialChat: the newest messages of the open
-- conversation over the game world, fading with age like the chat frames,
-- a row of conversations and a message box. When another conversation gets
-- a message, a notice shows in the corner, and an invite to a group shows
-- above the conversations. The little window buttons in the top left corner
-- close the chat or open the full window.
TrialChatMinimalView = {}
local UI = TrialChatUI
local Color = UI.Color

-- The size you can drag it to: the width of the messages, and the height
-- of the space they get above the conversations.
local DEFAULT_WIDTH = 520
local MIN_WIDTH, MAX_WIDTH = 320, 1000
local DEFAULT_AREA_HEIGHT = 200
local MIN_AREA_HEIGHT, MAX_AREA_HEIGHT = 60, 600
-- Messages kept to show; as many as fit are on screen. The conversation's
-- whole stored history is loaded with them, like in the full view (it is
-- capped where it is stored); this is only a backstop for very long
-- sessions.
local MAX_LINES = 2000
-- Lines per mouse wheel notch, and how long it stays scrolled back once
-- you've stopped using it.
local SCROLL_LINES = 2
local SCROLL_RESET_SECONDS = 10
-- Messages are pills like the conversations: as tall as them for one line,
-- with the same rounded ends, and rounded boxes when they wrap.
local LINE_GAP = 4
local LINE_PADDING_X = 12
local LINE_PADDING_Y = 6
local LINE_MIN_HEIGHT = 26
local LINE_RADIUS = 13
local LINE_VISIBLE_SECONDS = 30
local LINE_FADE_SECONDS = 4
-- How far down from the top edge of the message area a line that only
-- partly fits fades out, by the middle of what is still shown of it (see
-- UpdateFade).
local TOP_FADE_HEIGHT = 24
-- While you aren't using the view, older lines are dimmer (newest first).
local LINE_ALPHA_BY_AGE = { 1, 1, 0.8, 0.55 }
local OLDEST_LINE_ALPHA = 0.35
local PILL_HEIGHT = 26
local PILL_GAP = 6
local GRIP_WIDTH = 18
-- How far the mouse has to drag the resize grip before it resizes at all.
local RESIZE_DRAG_THRESHOLD = 3
-- Room kept between the view's edges and the screen's when it is at its
-- biggest. A frame exactly as large as the screen has only one position it
-- can be in, so it could never be dragged anywhere; the margin leaves it
-- room to move, and keeps the resize grip clear of the screen's edge.
local SCREEN_MARGIN = 64
local ROW_GAP = 8
local COMPOSER_HEIGHT = 38
-- A reply shown above the message box: who and what is being answered.
local REPLY_BAR_HEIGHT = 28

-- The right-click menu, in this view's colors (dark pills on the world).
local MENU_THEME = {
    bg = Color.sidebar, bgAlpha = 0.96,
    border = Color.white, borderAlpha = 0.16,
    radius = 10,
    hover = Color.white, hoverAlpha = 0.08,
    text = Color.textSoft,
    font = UI.Font.item,
    itemHeight = 24,
    padding = 5,
    minWidth = 120,
}
-- Room between the panel's edge and what's in it.
local PADDING = 10
local PANEL_RADIUS = 13
-- The panel's outline. The window buttons' field is outlined in the same
-- colour and alpha, so its curve is one line with the chat box's.
local PANEL_LINE_ALPHA = 0.08
-- The little window buttons in their own field in the top left corner,
-- above the conversations, like a Mac window's: red closes the chat, green
-- opens the full window. The field is exactly two of the panel's corner
-- curves tall, so its corners are the chat box's own curve, top left and
-- bottom right alike. The frame keeps a strip that tall at the top for it
-- (see UpdateHeight), so the buttons and the conversations never overlap.
local WINDOW_BUTTON_SIZE = 12
local WINDOW_BUTTON_GAP = 6
local CONTROLS_HEIGHT = 2 * PANEL_RADIUS
local WINDOW_BUTTON_PADDING = (CONTROLS_HEIGHT - WINDOW_BUTTON_SIZE) / 2
local CONTROLS_WIDTH = WINDOW_BUTTON_SIZE * 2 + WINDOW_BUTTON_GAP
    + WINDOW_BUTTON_PADDING * 2
local CLOSE_COLOR = { 1, 0.37, 0.34 }
local MAXIMIZE_COLOR = { 0.16, 0.78, 0.25 }
local IDLE_ALPHA = 0.45
local RECENT_SECONDS = 7
local UPDATE_SECONDS = 0.1
local TOAST_WIDTH = 300
local TOAST_SECONDS = 8
local DEFAULT_X, DEFAULT_Y = 40, 300

local View = {}
View.__index = View

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function colorForName(name)
    return UI.ClassColor(TrialChatNearby:GetClass(name)) or Color.textSoft
end

-- The quoted part of a reply, muted, on a line of its own above the message.
-- It is drawn as a link, so clicking it jumps back to the message it quotes.
local function replyLine(reply, colorFor)
    local sender = TrialChatCommon.ShortName(reply.sender or "?")
    local text = TrialChatCommon.RemovePlayerLinks(reply.text or "")
    return TrialChatCommon.ReplyLink(
        UI.ColorText(Color.muted, "> ")
            .. UI.ColorText(colorFor({ sender = reply.sender }), sender)
            .. UI.ColorText(Color.muted, ": " .. text))
end

-- The keybinding to reply with, when there is one.
local function getReplyHint()
    local key = GetBindingKey and GetBindingKey("TRIALCHAT_OPEN")
    if key then
        return "Press " .. (GetBindingText and GetBindingText(key) or key) .. " to reply"
    end
    return "Click to reply"
end

---------------------------------------------------------------------------
-- Window buttons
---------------------------------------------------------------------------
-- The little window buttons, like a Mac window's traffic lights: red closes
-- the chat, green opens the full window. They take the mouse where they are
-- so they can be clicked, but they don't count as using the view (see
-- IsInUse): reaching for them never lights the chat up and moves it, the
-- buttons included, out from under the cursor.
function View:CreateWindowButton(color, icon, tooltip, onClick)
    local button = CreateFrame("Button", nil, self.controls)
    button:SetSize(WINDOW_BUTTON_SIZE, WINDOW_BUTTON_SIZE)
    button.box = UI.CreateBox(button, { radius = WINDOW_BUTTON_SIZE / 2, border = true })
    button.box:SetColor(color)
    -- A slightly darker ring around the dot, the way the real ones have.
    button.box:SetBorderColor({ color[1] * 0.55, color[2] * 0.55, color[3] * 0.55 })
    -- Full opacity when hovered so the button/field reads as "in focus".
    button:SetAlpha(1)
    -- The little symbol only shows while the cursor is on the button.
    button.glyph = UI.CreateIcon(button, icon, 7, Color.black, "OVERLAY")
    button.glyph:SetPoint("CENTER")
    button.glyph:Hide()
    button:RegisterForClicks("LeftButtonUp")
    button:SetScript("OnClick", onClick)
    button:SetScript("OnEnter", function(self)
        self.glyph:Show()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(tooltip, nil, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function(self)
        self.glyph:Hide()
        GameTooltip_Hide()
    end)
    return button
end

function View:CreateWindowButtons()
    local controls = CreateFrame("Frame", nil, self.frame)
    self.controls = controls
    controls:SetSize(CONTROLS_WIDTH, CONTROLS_HEIGHT)
    -- Top left corner curves like the chat box; bottom right curves the same,
    -- while top right and bottom left stay square, as requested.
    local fieldCorners = {
        TOPLEFT = true,
        TOPRIGHT = false,
        BOTTOMRIGHT = true,
        BOTTOMLEFT = false,
    }
    controls.box = UI.CreateBox(controls, { radius = PANEL_RADIUS, corners = fieldCorners, border = true })
    controls.box:SetColor(Color.sidebar, 0.85)
    controls.box:SetBorderColor(Color.white, PANEL_LINE_ALPHA)
    controls:SetAlpha(1)
    controls:EnableMouse(true)
    local close = self:CreateWindowButton(CLOSE_COLOR, "close", "Close chat", function()
        self:Hide()
    end)
    close:SetPoint("TOPLEFT", controls, "TOPLEFT",
        WINDOW_BUTTON_PADDING, -WINDOW_BUTTON_PADDING)
    local maximize = self:CreateWindowButton(MAXIMIZE_COLOR, "expand",
        "Open the full TrialChat window", function()
            self.controller.ShowFullView()
        end)
    maximize:SetPoint("LEFT", close, "RIGHT", WINDOW_BUTTON_GAP, 0)
    return controls
end

-- controller gives the view its data and does what it asks:
-- GetSelected(), Select(key), Cycle(step), GetConversations() (Nearby and
-- connected groups as { key, name, unread }), GetEntries() (the open
-- conversation's history, how to format a message and color a name),
-- GetName(), GetMessageLimit(), Send(text), ShowFullView(), GetSettings(),
-- AnswerInvite(join), OnShown() and OnHidden().
function TrialChatMinimalView.Create(controller)
    local view = setmetatable({
        controller = controller, lines = {}, chips = {}, pills = {},
        scroll = 0, newCount = 0, hoveredBody = false,
    }, View)

    local settings = controller.GetSettings()
    view.width = clamp(tonumber(settings.minimalWidth) or DEFAULT_WIDTH, MIN_WIDTH, MAX_WIDTH)
    view.areaHeight = clamp(tonumber(settings.minimalHeight) or DEFAULT_AREA_HEIGHT,
        MIN_AREA_HEIGHT, MAX_AREA_HEIGHT)

    local frame = CreateFrame("Frame", "TrialChatMinimalFrame", UIParent)
    view.frame = frame
    frame:SetWidth(view.width + 2 * PADDING)
    frame:SetResizable(true)
    view.chromeHeight = 2 * PADDING + COMPOSER_HEIGHT + ROW_GAP + PILL_HEIGHT
    -- At rest, until it is first shown and sized for real (see UpdateHeight).
    view:UpdateHeight()
    frame:SetFrameStrata("MEDIUM")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    view:DragBy(frame)
    view:RestorePosition()

    -- Everything but the messages fades back while you aren't using it.
    view.chrome = CreateFrame("Frame", nil, frame)
    view.chrome:SetAllPoints()
    -- One rounded panel behind it all, fading with the rest.
    view.panel = UI.CreateBox(view.chrome, { radius = PANEL_RADIUS, border = true })
    view.panel:SetColor(Color.sidebar, 0.8)
    view.panel:SetBorderColor(Color.white, PANEL_LINE_ALPHA)
    view:CreateComposer()
    view:CreateWindowButtons()
    view:CreateMessageArea()
    -- In the frame's own top left corner, so they ride the corner of the
    -- chat box whether it is shrunk or grown; the frame keeps a strip above
    -- the conversations for them (see UpdateHeight). The field stays at full
    -- opacity when hovered (or always at full while in use via UpdateFade).
    view.controls:SetPoint("TOPLEFT", frame, "TOPLEFT")
    view.controls:SetFrameLevel(view.frame:GetFrameLevel() + 20)
    view.grip = UI.CreateButton(view.chrome, {
        style = "ghost", icon = "grip", iconSize = 14, width = GRIP_WIDTH, height = PILL_HEIGHT,
        tooltip = "Drag to move",
    })
    view.grip:SetPoint("BOTTOMLEFT", view.composer, "TOPLEFT", 0, ROW_GAP)
    view:DragBy(view.grip)
    view:CreateResizer()
    view.newestButton = UI.CreateButton(frame, {
        style = "hud", icon = "arrowDown", iconSize = 12, text = "Newest",
        height = PILL_HEIGHT, radius = 13, font = UI.Font.small,
        onClick = function() view:ScrollToNewest() end,
    })
    view.newestButton:SetFrameLevel(view.chrome:GetFrameLevel() + 10)
    view.newestButton:Hide()
    -- Not part of the chrome, so it doesn't fade while it waits for you.
    view.inviteCard = UI.CreateInviteCard(frame, function(join) controller.AnswerInvite(join) end)
    view.inviteCard:SetFrameLevel(view.chrome:GetFrameLevel() + 10)
    view:CreateToast()

    local sinceUpdate = 0
    frame:SetScript("OnUpdate", function(_, elapsed)
        sinceUpdate = sinceUpdate + elapsed
        if sinceUpdate >= UPDATE_SECONDS then
            sinceUpdate = 0
            view:UpdateFade()
        end
    end)
    frame:EnableMouseWheel(true)
    frame:SetScript("OnMouseWheel", function(_, delta)
        view:Scroll(delta * SCROLL_LINES)
    end)
    frame:SetScript("OnSizeChanged", function(_, width, height)
        if view.resizing then
            view:ApplySize(width, height)
        end
    end)
    frame:SetScript("OnShow", function()
        controller.OnShown()
        view:UpdateFade()
    end)
    frame:SetScript("OnHide", function()
        view.input:ClearFocus()
        controller.OnHidden()
    end)
    frame:Hide()
    return view
end

-- The view can be dragged by its grip, its messages, the "To ..." end of
-- the message box, and any empty space in it.
function View:DragBy(region)
    region:RegisterForDrag("LeftButton")
    region:SetScript("OnDragStart", function()
        self.moving = true
        self.frame:StartMoving()
    end)
    region:SetScript("OnDragStop", function()
        self.frame:StopMovingOrSizing()
        self.moving = false
        self.movedAt = GetTime()
        self:SavePosition()
        -- Keep it pinned by its bottom, so it grows upward with the messages.
        self:RestorePosition()
    end)
end

-- A grip in the top corner resizes it; the bottom stays where it is, and
-- the chat shows at its full size while you drag (see IsInUse), so you can
-- see the space you're giving it.
function View:CreateResizer()
    local resizer = CreateFrame("Button", nil, self.chrome)
    self.resizer = resizer
    resizer:SetSize(16, 16)
    resizer:SetPoint("TOPRIGHT", self.frame, "TOPRIGHT", -3, -3)
    -- Kept above the messages so it stays grabbable when they fill the area.
    resizer:SetFrameLevel(self.chrome:GetFrameLevel() + 10)
    resizer:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    resizer:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    resizer:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    -- The game's grabber points down and right; this one points up and right.
    for _, texture in ipairs({
        resizer:GetNormalTexture(), resizer:GetHighlightTexture(), resizer:GetPushedTexture(),
    }) do
        texture:SetTexCoord(0, 1, 1, 0)
    end
    resizer:SetScript("OnMouseDown", function(_, button)
        if button ~= "LeftButton" then return end
        -- The grip resizes only once the mouse actually drags it past a
        -- small threshold, so a plain click on it never changes the chat's
        -- size by accident (see View:StartResizing).
        self.resizePressed = true
        self.resizeStartX, self.resizeStartY = GetCursorPosition()
    end)
    local function release()
        self.resizePressed = false
        self:StopResizing()
    end
    resizer:SetScript("OnUpdate", function()
        if not self.resizePressed then return end
        -- The mouse-up can be missed: the grip hides when the chat goes
        -- idle, even while it's held. A grip still marked as held would
        -- otherwise start resizing on the next mouse move, without a click.
        if not IsMouseButtonDown("LeftButton") then
            release()
            return
        end
        if self.resizing then return end
        local x, y = GetCursorPosition()
        if math.abs(x - self.resizeStartX) > RESIZE_DRAG_THRESHOLD
            or math.abs(y - self.resizeStartY) > RESIZE_DRAG_THRESHOLD then
            self:StartResizing()
        end
    end)
    resizer:SetScript("OnMouseUp", function(_, button)
        if button ~= "LeftButton" then return end
        release()
    end)
    resizer:SetScript("OnHide", release)
    resizer:SetScript("OnEnter", function(button)
        GameTooltip:SetOwner(button, "ANCHOR_TOP")
        GameTooltip:SetText("Drag to resize")
        GameTooltip:Show()
    end)
    resizer:SetScript("OnLeave", GameTooltip_Hide)
end

function View:GetLinesBottom()
    return self.chromeHeight - PADDING + ROW_GAP
end

-- How tall the space the messages get actually is: the full area, except
-- while the frame's size is held with the mouse on the view, when it is
-- what the held frame has room for, so the messages stay inside it (see
-- UpdateHeight).
function View:GetVisibleHeight()
    if not self.holdHeight or not self.frameHeight then
        return self.areaHeight
    end
    return math.max(0, math.min(self.areaHeight,
        self.frameHeight - self:GetLinesBottom() - CONTROLS_HEIGHT - ROW_GAP/2))
end

function View:StartResizing()
    self:UpdateHeight()
    self.resizing = true
    local bottom = self:GetLinesBottom() + CONTROLS_HEIGHT + ROW_GAP/2
    -- The grip sits in the top right corner, so the bounds are capped to
    -- the screen minus the margin that keeps the view movable: it can never
    -- be dragged off the edge, where it couldn't be grabbed to drag it back,
    -- and it never fills the screen so exactly that it couldn't be moved.
    local maxWidth = MAX_WIDTH + 2 * PADDING
    local maxHeight = bottom + MAX_AREA_HEIGHT
    local minWidth = MIN_WIDTH + 2 * PADDING
    local minHeight = bottom + MIN_AREA_HEIGHT
    local parentWidth, parentHeight = UIParent:GetSize()
    if parentWidth and parentWidth > 0 then
        maxWidth = math.min(maxWidth, math.max(minWidth, parentWidth - SCREEN_MARGIN))
    end
    if parentHeight and parentHeight > 0 then
        maxHeight = math.min(maxHeight, math.max(minHeight, parentHeight - SCREEN_MARGIN))
    end
    self.frame:SetResizeBounds(minWidth, minHeight, maxWidth, maxHeight)
    self.frame:StartSizing("TOPRIGHT")
end

function View:StopResizing()
    if not self.resizing then return end
    self.frame:StopMovingOrSizing()
    self:ApplySize(self.frame:GetWidth(), self.frame:GetHeight())
    self.resizing = false
    local settings = self.controller.GetSettings()
    settings.minimalWidth = self.width
    settings.minimalHeight = self.areaHeight
    self:SavePosition()
    self:RestorePosition()
    self:UpdateFade()
end

-- Lays everything out for the frame's new size while it's being resized.
function View:ApplySize(frameWidth, frameHeight)
    self.width = clamp(math.floor(frameWidth - 2 * PADDING + 0.5), MIN_WIDTH, MAX_WIDTH)
    self.areaHeight = clamp(math.floor(frameHeight - self:GetLinesBottom() - (CONTROLS_HEIGHT + ROW_GAP/2) + 0.5),
        MIN_AREA_HEIGHT, MAX_AREA_HEIGHT)
    -- Kept with the frame, so the messages lay out in the size it has now
    -- (see GetVisibleHeight).
    self.frameHeight = frameHeight
    self:UpdateConversations()
end

function View:CreateComposer()
    local composer = CreateFrame("Frame", nil, self.chrome)
    self.composer = composer
    composer:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", PADDING, PADDING)
    composer:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -PADDING, PADDING)
    composer:SetHeight(COMPOSER_HEIGHT)
    composer.box = UI.CreateBox(composer, { radius = COMPOSER_HEIGHT / 2, border = true })
    composer.box:SetColor(Color.sidebar, 0.88)
    composer.box:SetBorderColor(Color.white, 0.18)
    composer:EnableMouse(true)
    self:DragBy(composer)
    -- A click there (not the end of a drag) starts typing.
    composer:SetScript("OnMouseUp", function(_, button)
        local justMoved = self.movedAt and GetTime() - self.movedAt < 0.2
        if button == "LeftButton" and not self.moving and not justMoved then
            self.input:SetFocus()
        end
    end)

    self.label = UI.CreateText(composer, UI.Font.item, Color.accent)
    self.label:SetPoint("LEFT", composer, "LEFT", 16, 0)

    local input = CreateFrame("EditBox", nil, composer)
    self.input = input
    input:EnableMouse(true)
    input:SetAutoFocus(false)
    input:SetFontObject(UI.Font.body)
    UI.SetTextColor(input, Color.text)
    input:SetHeight(COMPOSER_HEIGHT - 8)
    input:SetPoint("LEFT", self.label, "RIGHT", 10, 0)
    input:SetPoint("RIGHT", composer, "RIGHT", -16, 0)

    self.placeholder = UI.CreateText(composer, UI.Font.body, Color.muted)
    self.placeholder:SetPoint("LEFT", input, "LEFT", 0, 0)
    self.placeholder:SetText("Say something...")
    self.hint = UI.CreateText(composer, UI.Font.small, Color.muted)
    self.hint:SetPoint("RIGHT", composer, "RIGHT", -16, 0)
    self.hint:SetText("Tab switches")

    TrialChatCommon.RegisterLinkInput(input)
    -- Like the game's chat: Enter sends and stops typing, and so does Esc.
    input:SetScript("OnEnterPressed", function(box)
        local text = box:GetText()
        box:SetText("")
        box:ClearFocus()
        self.controller.Send(text)
    end)
    input:SetScript("OnEscapePressed", function(box)
        box:ClearFocus()
    end)
    input:SetScript("OnTabPressed", function()
        self.controller.Cycle(IsShiftKeyDown() and -1 or 1)
    end)
    local function update()
        local empty = (input:GetText() or "") == ""
        self.placeholder:SetShown(empty)
        self.hint:SetShown(empty)
        self:UpdateFade()
    end
    input:HookScript("OnTextChanged", update)
    input:HookScript("OnEditFocusGained", update)
    input:HookScript("OnEditFocusLost", update)
end

---------------------------------------------------------------------------
-- Conversations
---------------------------------------------------------------------------
function View:CreatePill()
    local pill = UI.CreateButton(self.chrome, {
        style = "hud", text = "", height = PILL_HEIGHT, radius = 13, font = UI.Font.small,
        onClick = function(button) self.controller.Select(button.key) end,
    })
    self.pills[#self.pills + 1] = pill
    return pill
end

-- Pills for each conversation, in rows from the message box up, leaving
-- room for the grip on the left of the first row.
function View:UpdateConversations()
    local selected = self.controller.GetSelected()
    local left = GRIP_WIDTH + 4
    local x, row = left, 0
    local count = 0
    -- A pending reply makes room for its own strip above the message box.
    local replyHeight = self.reply and (REPLY_BAR_HEIGHT + ROW_GAP) or 0
    for index, conversation in ipairs(self.controller.GetConversations()) do
        count = index
        local pill = self.pills[index] or self:CreatePill()
        pill.key = conversation.key
        local text = conversation.name
        if conversation.unread > 0 then
            text = text .. "  " .. UI.ColorText(Color.accent, tostring(conversation.unread))
        end
        pill:SetLabel(text)
        UI.SetButtonStyle(pill, conversation.key == selected and "accent" or "hud")
        local width = pill:GetWidth()
        if x > left and x + width > self.width then
            x, row = left, row + 1
        end
        pill:ClearAllPoints()
        pill:SetPoint("BOTTOMLEFT", self.composer, "TOPLEFT", x,
            ROW_GAP + replyHeight + row * (PILL_HEIGHT + PILL_GAP))
        pill:Show()
        x = x + width + PILL_GAP
    end
    for index = count + 1, #self.pills do
        self.pills[index]:Hide()
    end
    self.chromeHeight = 2 * PADDING + COMPOSER_HEIGHT + replyHeight + ROW_GAP
        + (row + 1) * (PILL_HEIGHT + PILL_GAP) - PILL_GAP
    if self.replyBar then
        self.replyBar:ClearAllPoints()
        self.replyBar:SetPoint("BOTTOMLEFT", self.composer, "TOPLEFT", 0, ROW_GAP)
        self.replyBar:SetPoint("BOTTOMRIGHT", self.composer, "TOPRIGHT", 0, ROW_GAP)
        self.replyBar:SetHeight(REPLY_BAR_HEIGHT)
    end
    -- An invite goes between the conversations and the messages.
    local card = self.inviteCard
    card:SetShown(self.invite ~= nil)
    if self.invite then
        local bottom = self:GetLinesBottom()
        local height = card:SetInvite(self.invite, self.width)
        card:ClearAllPoints()
        card:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", PADDING, bottom)
        self.chromeHeight = self.chromeHeight + height + ROW_GAP
    end
    self:LayoutLines()
end

-- invite is { groupName, inviter }, or nil when there's none.
function View:SetInvite(invite)
    self.invite = invite
    self:UpdateConversations()
end

-- The strip above the message box that shows what a reply will answer.
function View:CreateReplyBar()
    local view = self
    local bar = CreateFrame("Frame", nil, self.chrome)
    bar.box = UI.CreateBox(bar, { radius = 10, border = true })
    bar.box:SetColor(Color.sidebar, 0.9)
    bar.box:SetBorderColor(Color.white, 0.18)
    bar.accent = UI.CreateLine(bar)
    bar.accent:SetWidth(2)
    bar.accent:SetPoint("TOP", bar, "TOP", 0, -6)
    bar.accent:SetPoint("BOTTOM", bar, "BOTTOM", 0, 6)
    bar.accent:SetPoint("LEFT", bar, "LEFT", 11, 0)
    bar.text = UI.CreateText(bar, UI.Font.small, Color.muted)
    bar.text:SetPoint("LEFT", bar, "LEFT", 20, 0)
    bar.text:SetPoint("RIGHT", bar, "RIGHT", -32, 0)
    bar.text:SetJustifyH("LEFT")
    bar.text:SetWordWrap(false)
    bar.cancel = UI.CreateButton(bar, {
        style = "ghost", icon = "close", iconSize = 10,
        width = 22, height = 22,
        onClick = function() view.controller.ClearReply() end,
    })
    bar.cancel:SetPoint("RIGHT", bar, "RIGHT", -5, 0)
    bar:Hide()
    return bar
end

-- reply is { sender, text }, or nil when nothing is being answered.
function View:SetReply(reply)
    self.reply = reply
    if not self.replyBar then
        self.replyBar = self:CreateReplyBar()
    end
    if reply then
        local color = colorForName(reply.sender)
        self.replyBar.text:SetText("Replying to "
            .. UI.ColorText(color, TrialChatCommon.ShortName(reply.sender or "?"))
            .. UI.ColorText(Color.muted, ": "
                .. TrialChatCommon.RemovePlayerLinks(reply.text or "")))
        UI.Tint(self.replyBar.accent, color, 0.9)
    end
    self.replyBar:SetShown(reply ~= nil)
    self:UpdateConversations()
end

-- The frame reaches up to the top message still on screen, but no higher
-- than the space the messages get. While the mouse is on the view the size
-- is held (see UpdateFade): scrolling back, new messages and the cursor
-- moving over it never change it, and the messages that don't fit are cut
-- off at the top of the held frame and fade out along it. Only once you
-- have left it does it follow the messages again, shrinking as they fade
-- away.
function View:UpdateHeight()
    if self.resizing or self.holdHeight then return end
    local ceiling = self:GetLinesBottom() + self.areaHeight + CONTROLS_HEIGHT + ROW_GAP/2
    local top = self.chromeHeight + CONTROLS_HEIGHT + ROW_GAP/2
    for _, chip in ipairs(self.chips) do
        local chipTop = chip.top and math.min(chip.top, ceiling)
        if chip:IsShown() and chipTop and chipTop + CONTROLS_HEIGHT + ROW_GAP/2 > top then
            top = chipTop + CONTROLS_HEIGHT + ROW_GAP/2
        end
    end
    if self.frameHeight ~= top then
        self.frameHeight = top
        self.frame:SetHeight(top)
    end
end

---------------------------------------------------------------------------
-- Messages
---------------------------------------------------------------------------
-- An animated emoticon in a line is redrawn a cell at a time (see
-- TrialChatEmoji.lua); the text around it never changes. Only lines on screen
-- step, and only while their chip is shown, because a hidden frame gets no
-- OnUpdate. The split into text and emoticons is cached on the line, since
-- chips are recycled for whatever is scrolled into view. The message box is a
-- plain edit box, so what you are typing never shows the picture, only the
-- message once it is sent.
local function redrawChipEmoji(chip)
    chip.text:SetText(TrialChatCommon.BuildEmojiText(chip.emojiParts, GetTime()))
end

local function tickChipEmoji(chip, elapsed)
    chip.emojiElapsed = (chip.emojiElapsed or 0) + elapsed
    local step = 1 / (TrialChatCommon.EmojiFPS or 5)
    if chip.emojiElapsed < step then return end
    chip.emojiElapsed = 0
    redrawChipEmoji(chip)
end

-- Sets a chip's text and starts animating it when its line holds an animated
-- emoticon, stopping the tick on lines that don't.
local function setChipText(chip, line)
    chip.text:SetText(line.text)
    if not line.emojiChecked then
        line.emojiParts, line.emojiAnimated =
            TrialChatCommon.SplitEmojiMarkup(line.text)
        line.emojiChecked = true
    end
    if line.emojiAnimated then
        chip.emojiParts = line.emojiParts
        chip.emojiElapsed = 0
        chip:SetScript("OnUpdate", tickChipEmoji)
    elseif chip.emojiParts then
        chip:SetScript("OnUpdate", nil)
        chip.emojiParts = nil
        chip.emojiElapsed = nil
    end
end

function View:MakeLine(entry, format, colorFor)
    if type(entry) == "string" then
        return { entry = entry, text = TrialChatCommon.RemovePlayerLinks(entry), color = Color.text }
    end
    if type(entry) ~= "table" then return nil end

    local name = TrialChatCommon.ShortName(entry.sender or "?")
    local text
    if entry.isEmote then
        text = name .. " " .. format(entry)
    else
        text = UI.ColorText(colorFor(entry), name) .. ": " .. format(entry)
    end
    if entry.reply then
        text = replyLine(entry.reply, colorFor) .. "\n" .. text
    end
    return {
        entry = entry,
        text = text,
        color = entry.isEmote and Color.emote or Color.text,
    }
end

-- The messages live in their own frame over the conversations, cut off at
-- the top of the space they get: a line too tall to fit shows the part that
-- fits and is clipped above the edge (see LayoutLines) instead of being
-- left out, so the space is always filled. Nothing is drawn on top of the
-- edge to hide the cut: a line cut off there fades out along it instead
-- (see UpdateFade), so no band is ever painted over the messages.
function View:CreateMessageArea()
    local area = CreateFrame("Frame", nil, self.frame)
    self.messageArea = area
    area:SetClipsChildren(true)
    -- Just under the chips (chrome + 5), which ride above it.
    area:SetFrameLevel(self.chrome:GetFrameLevel() + 4)
end

function View:CreateChip()
    local view = self
    -- Parented to the message area so a line cut off at its top is clipped
    -- there (see CreateMessageArea).
    local chip = CreateFrame("Frame", nil, self.messageArea)
    chip.box = UI.CreateBox(chip, { radius = LINE_RADIUS, border = true })
    chip.box:SetColor(Color.sidebar, 0.85)
    chip.box:SetBorderColor(Color.white, 0.12)
    chip.text = UI.CreateText(chip, UI.Font.body)
    chip.text:SetPoint("TOPLEFT", chip, "TOPLEFT", LINE_PADDING_X, -LINE_PADDING_Y)
    chip.text:SetJustifyH("LEFT")
    chip.text:SetWordWrap(true)
    chip.text:SetNonSpaceWrap(true)
    TrialChatMessageList.EnableLinks(chip)
    -- Right-click opens the message menu, unless a link was clicked. A plain
    -- frame has no RegisterForClicks (that is a Button method), so this
    -- listens for the button coming up with the mouse over the chip.
    chip:EnableMouse(true)
    chip:SetScript("OnMouseUp", function(self, button)
        if button ~= "RightButton" then return end
        if self.hyperlinkMenu or self.hoveredLink then
            self.hyperlinkMenu = nil
            return
        end
        -- Only real messages get a menu; notices and emotes don't.
        local entry = self.line and self.line.entry
        if type(entry) == "table" and not entry.isEmote then
            view.controller.ShowMessageMenu(entry, MENU_THEME)
        end
    end)
    self:DragBy(chip)
    chip:SetFrameLevel(self.chrome:GetFrameLevel() + 5)
    chip:Hide()
    self.chips[#self.chips + 1] = chip
    return chip
end

-- The lines stack up from the conversations, the newest at the bottom (or
-- the one scrolled back to), as many as fit; each background is as wide as
-- its text. The line at the top is shown even when it only partly fits:
-- it gets cut off at the top of the message area (see CreateMessageArea)
-- rather than left out, so the space is always filled.
function View:LayoutLines()
    local bottom = self:GetLinesBottom()
    -- The messages get the space the frame has for them, which while the
    -- size is held (see UpdateHeight) can be less than the full area: they
    -- are then cut off at the top of the held frame instead of making it
    -- grow.
    local areaHeight = self:GetVisibleHeight()
    local limit = bottom + areaHeight
    local textWidth = self.width - 2 * LINE_PADDING_X
    -- The messages get their own frame that clips them at the top of the
    -- space above the conversations, which moves with them.
    self.messageArea:ClearAllPoints()
    self.messageArea:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", PADDING, bottom)
    self.messageArea:SetSize(self.width, areaHeight)
    local y = bottom
    local count = #self.lines
    self.scroll = clamp(self.scroll, 0, math.max(0, count - 1))
    local shown = 0
    for rank = 1, count - self.scroll do
        local line = self.lines[count - self.scroll - rank + 1]
        local chip = self.chips[rank] or self:CreateChip()
        setChipText(chip, line)
        UI.SetTextColor(chip.text, line.color)
        local width = math.min(math.ceil(chip.text:GetUnboundedStringWidth()) + 1, textWidth)
        chip.text:SetWidth(width)
        local height = math.max(LINE_MIN_HEIGHT,
            math.ceil(chip.text:GetStringHeight()) + 2 * LINE_PADDING_Y)
        -- A line starting at or above the top edge would be cut away
        -- completely, so it is not shown; one cut in part shows what fits
        -- of it and is the last line shown.
        if y >= limit then break end
        chip.line = line
        local entry = line.entry
        chip.onReplyJump = (type(entry) == "table" and entry.reply)
            and function() self:JumpToReply(entry) end or nil
        chip:SetSize(math.max(height, width + 2 * LINE_PADDING_X), height)
        chip:ClearAllPoints()
        chip:SetPoint("BOTTOMLEFT", self.messageArea, "BOTTOMLEFT", 0, y - bottom)
        -- Where the line reaches to, for its fade along the top edge of the
        -- area (see UpdateFade).
        chip.top = y + height
        chip.height = height
        shown = rank
        if chip.top > limit then break end
        y = chip.top + LINE_GAP
    end
    for rank = shown + 1, #self.chips do
        self.chips[rank].line = nil
        self.chips[rank].onReplyJump = nil
        self.chips[rank]:Hide()
    end
    self:UpdateNewestButton()
    self:UpdateFade()
end

-- While scrolled back, a button at the bottom goes back to the newest
-- message, counting the ones that came in meanwhile.
function View:UpdateNewestButton()
    local button = self.newestButton
    button:SetShown(self.scroll > 0)
    if self.scroll == 0 then return end
    button:SetLabel(self.newCount > 0 and (self.newCount .. " new") or "Newest")
    UI.SetButtonStyle(button, self.newCount > 0 and "accent" or "hud")
    button:ClearAllPoints()
    button:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMRIGHT", -PADDING, self:GetLinesBottom())
end

-- Scrolls back into older messages (positive) or forward. The whole stored
-- history is loaded (see Render), so this is a plain scroll.
function View:Scroll(lines)
    self.lastInteractionAt = GetTime()
    if lines > 0 then
        self.scroll = self.scroll + lines
        self:LayoutLines()
        return
    end
    self.scroll = math.max(0, self.scroll + lines)
    if self.scroll == 0 then
        self.newCount = 0
    end
    self:LayoutLines()
end

function View:ScrollToNewest()
    self.scroll = 0
    self.newCount = 0
    self:LayoutLines()
end

-- Scrolls back to the message a reply quotes; the whole history is loaded
-- (see Render), like in the full view. entry is the reply-carrying line's
-- message; the nearest quote before it wins.
function View:JumpToReply(entry)
    local reply = type(entry) == "table" and entry.reply
    if not reply then return end
    local lines = self.lines
    local start = #lines + 1
    for index = #lines, 1, -1 do
        if lines[index].entry == entry then
            start = index
            break
        end
    end
    for index = start - 1, 1, -1 do
        if TrialChatCommon.ReplyQuotesEntry(reply, lines[index].entry) then
            self.scroll = #lines - index
            self.newCount = 0
            self.lastInteractionAt = GetTime()
            self:LayoutLines()
            return
        end
    end
end

-- New lines don't move what you're reading while scrolled back, unless
-- jumpToNewest (your own message, a notice).
function View:AddLine(line, jumpToNewest)
    line.shownAt = GetTime()
    self.lines[#self.lines + 1] = line
    if jumpToNewest then
        self.scroll = 0
        self.newCount = 0
    elseif self.scroll > 0 then
        self.scroll = self.scroll + 1
        self.newCount = self.newCount + 1
    end
    if self.scroll == 0 then
        while #self.lines > MAX_LINES do
            table.remove(self.lines, 1)
        end
    end
    self.lastLineAt = line.shownAt
    self:LayoutLines()
end

-- Shows the whole stored history of the open conversation, like the full
-- view; as many lines as fit are on screen (see LayoutLines).
function View:Render()
    local entries, format, colorFor = self.controller.GetEntries()
    local now = GetTime()
    self.lines = {}
    self.scroll = 0
    self.newCount = 0
    for index = 1, #entries do
        local line = self:MakeLine(entries[index], format, colorFor)
        if line then
            line.shownAt = now
            self.lines[#self.lines + 1] = line
        end
    end
    self:LayoutLines()
end

function View:AddEntry(entry, isOwn)
    local _, format, colorFor = self.controller.GetEntries()
    local line = self:MakeLine(entry, format, colorFor)
    if line then
        self:AddLine(line, isOwn)
    end
end

-- A line from TrialChat itself; it isn't kept in the history.
function View:AddNotice(text, color)
    self:AddLine({ text = text, color = color or Color.muted }, true)
end

function View:Refresh()
    self.label:SetText("To " .. self.controller.GetName())
    self.input:SetMaxLetters(self.controller.GetMessageLimit())
    self:UpdateConversations()
    self:Render()
end

---------------------------------------------------------------------------
-- Fading
---------------------------------------------------------------------------
function View:IsInUse()
    if self.resizing or self.moving or self.input:HasFocus() then return true end
    -- The window buttons only keep the chat in use when the cursor reached
    -- them from the chat itself: hoveredBody remembers whether the last
    -- update saw the cursor over the chat, and stays as it was while the
    -- cursor sits on the buttons. Reaching for them from the chat keeps the
    -- window expanded (so they don't shrink away from the cursor), while
    -- arriving from outside never grows the chat under the cursor.
    local overControls = self.controls:IsMouseOver()
    local overBody = not overControls and self.frame:IsMouseOver()
    if not overBody then
        for _, chip in ipairs(self.chips) do
            if chip:IsShown() and chip:IsMouseOver() then
                overBody = true
                break
            end
        end
    end
    self.hoveredBody = overBody or (overControls and self.hoveredBody)
    if overControls then
        return self.hoveredBody or false
    end
    return overBody
end

-- While you hover, type or read back, everything shows and the size is
-- held as it is (see the end of this function). Otherwise the rest fades
-- back, each message fades out a while after it came in, older ones
-- dimmer, and the frame shrinks back to the messages still on screen (see
-- UpdateHeight).
function View:UpdateFade()
    local now = GetTime()
    local inUse = self:IsInUse()
    if inUse then
        self.lastInteractionAt = now
    end
    local active = inUse or self.scroll > 0
    local recent = self.lastLineAt and now - self.lastLineAt < RECENT_SECONDS
    -- Fade the window buttons the same way as the rest when not in use and
    -- not hovered.
    if active or recent or self.controls:IsMouseOver() or self.frame:IsMouseOver() then
        self.controls:SetAlpha(1)
    else
        TrialChatCommon.FadeTo(self.controls, IDLE_ALPHA)
    end
    TrialChatCommon.FadeTo(self.chrome, (active or recent) and 1 or IDLE_ALPHA)
    self.resizer:SetShown(active)
    -- The first tick of a hover gives the messages the full area back and
    -- lays them out in it, so the size the frame is then held at covers
    -- what has just lit up. LayoutLines ends in this function again, and
    -- that re-entry sees layingOut set and skips this block.
    if inUse and self.inUseLast ~= true and not self.resizing and not self.layingOut then
        self.layingOut = true
        local ceiling = self:GetLinesBottom() + self.areaHeight + CONTROLS_HEIGHT + ROW_GAP/2
        if self.frameHeight ~= ceiling then
            self.frameHeight = ceiling
            self.frame:SetHeight(ceiling)
        end
        self:LayoutLines()
        self.layingOut = false
    end
    local limit = self:GetLinesBottom() + self:GetVisibleHeight()
    for rank, chip in ipairs(self.chips) do
        local line = chip.line
        local alpha = 0
        if line and active then
            alpha = 1
        elseif line then
            local left = 1 - math.max(0, now - line.shownAt - LINE_VISIBLE_SECONDS) / LINE_FADE_SECONDS
            alpha = math.max(0, left) * (LINE_ALPHA_BY_AGE[rank] or OLDEST_LINE_ALPHA)
        end
        -- A line cut off at the top of the area fades out along the edge
        -- itself: it still shows where it enters the fade strip, and is
        -- completely gone by the top of the area (see CreateMessageArea).
        -- What is left of it stands for the whole of it, so the middle of
        -- the rest is where it is half faded.
        if line and chip.top and chip.height then
            local low = math.max(chip.top - chip.height, limit - TOP_FADE_HEIGHT)
            local high = math.min(chip.top, limit)
            if high > low then
                local center = (low + high) / 2
                alpha = alpha * clamp((limit - center) / TOP_FADE_HEIGHT, 0, 1)
            end
        end
        chip:SetAlpha(alpha)
        chip:SetShown(alpha > 0)
    end
    -- The size is held the whole time the mouse is on the view, so nothing
    -- on it ever moves under the cursor: the first tick of a hover is the
    -- one that still sizes the frame, for the messages that light up then;
    -- every tick after holds that size (see UpdateHeight). Leaving it lets
    -- it follow the messages again as they fade away.
    self.holdHeight = inUse and self.inUseLast == true
    self.inUseLast = inUse
    self:UpdateHeight()
end

---------------------------------------------------------------------------
-- Showing, typing and position
---------------------------------------------------------------------------
function View:Show() self.frame:Show() end
function View:Hide() self.frame:Hide() end
function View:IsShown() return self.frame:IsShown() end
function View:FocusInput() self.input:SetFocus() end

function View:RestorePosition()
    local settings = self.controller.GetSettings()
    local x = tonumber(settings.minimalX) or DEFAULT_X
    local y = tonumber(settings.minimalY) or DEFAULT_Y
    -- A saved position can hang off the edge of the screen (or the screen
    -- can have shrunk since it was saved). The frame is pulled back inside
    -- it, so the resize grip in the top right corner always stays reachable.
    local parentWidth, parentHeight = UIParent:GetSize()
    if parentWidth and parentHeight and parentWidth > 0 and parentHeight > 0 then
        x = clamp(x, 0, math.max(0, parentWidth - self.frame:GetWidth()))
        y = clamp(y, 0, math.max(0, parentHeight - self.frame:GetHeight()))
    end
    self.frame:ClearAllPoints()
    self.frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, y)
end

function View:SavePosition()
    local settings = self.controller.GetSettings()
    settings.minimalX = self.frame:GetLeft()
    settings.minimalY = self.frame:GetBottom()
end

---------------------------------------------------------------------------
-- Notices of messages elsewhere
---------------------------------------------------------------------------
function View:CreateToast()
    local toast = CreateFrame("Button", "TrialChatToast", UIParent)
    self.toast = toast
    toast:SetWidth(TOAST_WIDTH)
    toast:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -24, -230)
    toast:SetFrameStrata("HIGH")
    toast:RegisterForClicks("LeftButtonUp")
    toast.box = UI.CreateBox(toast, { radius = 10, border = true })
    toast.box:SetColor(Color.window, 0.92)
    toast.box:SetBorderColor(Color.white, 0.12)

    toast.title = UI.CreateText(toast, UI.Font.item, Color.accent)
    toast.title:SetPoint("TOPLEFT", toast, "TOPLEFT", 16, -14)
    toast.count = UI.CreateText(toast, UI.Font.small, Color.muted)
    toast.count:SetPoint("LEFT", toast.title, "RIGHT", 8, 0)
    toast.close = UI.CreateButton(toast, {
        style = "ghost", icon = "close", iconSize = 12, width = 24, height = 24,
        onClick = function() toast:Hide() end,
    })
    toast.close:SetPoint("TOPRIGHT", toast, "TOPRIGHT", -8, -8)
    toast.text = UI.CreateText(toast, UI.Font.body)
    toast.text:SetPoint("TOPLEFT", toast.title, "BOTTOMLEFT", 0, -8)
    toast.text:SetWidth(TOAST_WIDTH - 32)
    toast.text:SetJustifyH("LEFT")
    toast.text:SetWordWrap(true)
    toast.text:SetMaxLines(2)
    toast.hint = UI.CreateText(toast, UI.Font.small, Color.muted)
    toast.hint:SetPoint("TOPLEFT", toast.text, "BOTTOMLEFT", 0, -6)

    toast:SetScript("OnClick", function() self:Reply() end)
    toast:SetScript("OnUpdate", function()
        if GetTime() > (toast.hideAt or 0) and not toast:IsMouseOver() then
            toast:Hide()
        end
    end)
    toast:Hide()
end

-- entry is the message that came in for conversation key, which has unread
-- messages; format and colorFor are as for the conversation's history.
function View:ShowToast(key, name, unread, entry, format, colorFor)
    local line = self:MakeLine(entry, format, colorFor)
    if not line then return end
    local toast = self.toast
    toast.key = key
    toast.title:SetText(name)
    toast.count:SetText(unread > 1 and (unread .. " new") or "")
    toast.text:SetText(line.text)
    UI.SetTextColor(toast.text, line.color)
    toast.hint:SetText(getReplyHint())
    toast:SetHeight(math.ceil(14 + toast.title:GetStringHeight() + 8
        + toast.text:GetStringHeight() + 6 + toast.hint:GetStringHeight() + 14))
    toast.hideAt = GetTime() + TOAST_SECONDS
    toast:Show()
end

function View:GetToastKey()
    return self.toast:IsShown() and self.toast.key or nil
end

-- Opens the conversation from the notice, ready to type.
function View:Reply()
    local key = self.toast.key
    self.toast:Hide()
    self:Show()
    self.controller.Select(key)
    self:FocusInput()
end
